/**
 * Linkedin | Leads  (Google Apps Script, conta que recebe os e-mails do LinkedIn)
 *
 * Lê os e-mails "Fulano aceitou seu convite" enviados por invitations@linkedin.com,
 * extrai nome, primeiro nome, cargo (headline), slug do perfil e data de chegada,
 * e envia esses campos ao workflow n8n WF-01E.
 *
 * O que este script NUNCA faz:
 *   - não acessa o LinkedIn, não clica em links, não envia mensagens;
 *   - não guarda nem envia o otpToken dos links do e-mail (só o slug do perfil);
 *   - não contém segredos: URL e token ficam em Propriedades do script.
 *
 * Propriedades do script (Configurações do projeto > Propriedades do script):
 *   N8N_WEBHOOK_URL    URL de produção do webhook do WF-01E
 *   N8N_WEBHOOK_TOKEN  criado pela função gerarToken() (não digite na conversa)
 *   MODO               SIMULAR (padrão) | TESTE | PRODUCAO
 *   MEU_SLUG           opcional: slug do seu próprio perfil, para nunca ser
 *                      confundido com o perfil de quem aceitou
 *
 * Modos:
 *   SIMULAR   nada sai da conta Google; só registra no log o que foi lido.
 *   TESTE     enviarTeste() manda os aceites ao n8n como teste. O n8n responde,
 *             manda um resumo no Telegram e NÃO grava nada. Nenhum rótulo é aplicado.
 *   PRODUCAO  o acionador de 10 minutos passa a enviar. O rótulo só é aplicado
 *             quando o n8n confirma que processou de verdade (no n8n a trava
 *             PROCESSAMENTO_REAL continua false até liberarmos).
 */

var CONFIG = {
  BUSCA: 'from:invitations@linkedin.com (subject:"aceitou seu convite" OR subject:"accepted your invitation") newer_than:14d',
  ROTULO_PROCESSADO: 'LinkedIn/Aceite processado',
  MAX_THREADS_POR_EXECUCAO: 20,
  FUSO: 'America/Sao_Paulo',
  HEADER_TOKEN: 'X-Leads-Token',
  FUNCAO_ACIONADOR: 'processarAceites',
  MINUTOS_ACIONADOR: 10
};

/* =====================================================================
 * 1) Rode primeiro: pede as autorizações e confere as propriedades.
 * ===================================================================== */
function configurar() {
  var props = PropertiesService.getScriptProperties();
  if (!props.getProperty('MODO')) props.setProperty('MODO', 'SIMULAR');

  // Toca em cada serviço para o Google pedir todas as permissões de uma vez.
  var total = GmailApp.search(CONFIG.BUSCA, 0, 1).length;
  ScriptApp.getProjectTriggers();

  var url = props.getProperty('N8N_WEBHOOK_URL');
  var temToken = !!props.getProperty('N8N_WEBHOOK_TOKEN');
  Logger.log('Autorização OK. Conta: %s', Session.getEffectiveUser().getEmail());
  Logger.log('MODO = %s', props.getProperty('MODO'));
  Logger.log('N8N_WEBHOOK_URL = %s', url ? url : '(FALTA configurar)');
  Logger.log('N8N_WEBHOOK_TOKEN = %s', temToken ? '(configurado)' : '(FALTA: rode gerarToken)');
  Logger.log('Busca no Gmail encontrou ao menos %s conversa(s) de aceite.', total);
}

/* =====================================================================
 * 2) Gera o token compartilhado com o n8n (uma vez só).
 *    Copie o valor que aparece no log para a credencial Header Auth do n8n.
 * ===================================================================== */
function gerarToken() {
  var props = PropertiesService.getScriptProperties();
  if (props.getProperty('N8N_WEBHOOK_TOKEN')) {
    Logger.log('Já existe um token salvo. Para trocar, apague N8N_WEBHOOK_TOKEN nas propriedades e rode de novo.');
    return;
  }
  var token = (Utilities.getUuid() + Utilities.getUuid()).replace(/-/g, '');
  props.setProperty('N8N_WEBHOOK_TOKEN', token);
  Logger.log('Token criado e salvo nas propriedades do script.');
  Logger.log('No n8n, credencial Header Auth: Name = %s | Value = %s', CONFIG.HEADER_TOKEN, token);
}

/* =====================================================================
 * 3) Teste de leitura: não envia nada, só mostra no log o que foi entendido.
 * ===================================================================== */
function testarLeitura() {
  var lote = coletarAceites_(false);
  Logger.log('%s aceite(s) lido(s) (incluindo já rotulados). Nada foi enviado.', lote.eventos.length);
  lote.eventos.forEach(function (e, i) {
    Logger.log('#%s %s | primeiro nome: %s | cargo: %s | perfil: linkedin.com/in/%s | data: %s',
      i + 1, e.nome, e.primeiro_nome, e.headline || '(não encontrado)', e.profile_slug || '(não encontrado)', e.data_conexao);
  });
}

/* =====================================================================
 * 3b) Teste do token: envia um pacote VAZIO ao n8n (nenhum contato).
 *     HTTP 200 = token aceito. HTTP 403 = token recusado.
 * ===================================================================== */
function testarConexao() {
  var resposta = enviarAoN8n_([], 'teste');
  if (!resposta) return;
  Logger.log('Token aceito pelo n8n. processamento_real = %s | status = %s',
    resposta.processamento_real, (resposta.resultados || []).map(function (r) { return r.status; }).join(','));
}

/* =====================================================================
 * 4) Teste controlado: envia ao n8n em modo teste (nada é gravado,
 *    nada é rotulado). Exige MODO = TESTE. Rode manualmente.
 * ===================================================================== */
function enviarTeste() {
  var modo = modo_();
  if (modo !== 'TESTE') {
    Logger.log('MODO atual é %s. Para o teste controlado, mude MODO para TESTE nas propriedades.', modo);
    return;
  }
  var lote = coletarAceites_(true);
  if (lote.eventos.length === 0) {
    Logger.log('Nenhum aceite novo (sem o rótulo "%s") nos últimos 14 dias.', CONFIG.ROTULO_PROCESSADO);
    return;
  }
  var resposta = enviarAoN8n_(lote.eventos, 'teste');
  if (!resposta) return;
  Logger.log('n8n respondeu. processamento_real = %s', resposta.processamento_real);
  (resposta.resultados || []).forEach(function (r) {
    Logger.log('%s -> %s', r.gmail_message_id, r.status);
  });
  Logger.log('Confira o resumo no Telegram. Nenhum rótulo foi aplicado.');
}

/* =====================================================================
 * 5) Função do acionador de 10 minutos. Só faz algo em MODO = PRODUCAO.
 * ===================================================================== */
function processarAceites() {
  var modo = modo_();
  if (modo !== 'PRODUCAO') {
    Logger.log('MODO = %s: acionador ignorado (só atua em PRODUCAO).', modo);
    return;
  }
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(5000)) {
    Logger.log('Outra execução em andamento. Saindo.');
    return;
  }
  try {
    var lote = coletarAceites_(true);
    if (lote.eventos.length === 0) return;

    var resposta = enviarAoN8n_(lote.eventos, 'producao');
    if (!resposta) return;
    if (resposta.processamento_real !== true) {
      Logger.log('n8n ainda está com a trava PROCESSAMENTO_REAL = false. Nada gravado, nada rotulado.');
      return;
    }

    var processados = {};
    (resposta.resultados || []).forEach(function (r) {
      if (r.processado === true && r.gmail_message_id) processados[r.gmail_message_id] = true;
    });

    var rotulo = GmailApp.getUserLabelByName(CONFIG.ROTULO_PROCESSADO) || GmailApp.createLabel(CONFIG.ROTULO_PROCESSADO);
    var rotulados = 0;
    lote.threads.forEach(function (t) {
      var ids = lote.idsPorThread[t.getId()] || [];
      var todos = ids.length > 0 && ids.every(function (id) { return processados[id]; });
      if (todos) { t.addLabel(rotulo); rotulados++; }
    });
    Logger.log('%s aceite(s) enviado(s), %s conversa(s) rotulada(s).', lote.eventos.length, rotulados);
  } finally {
    lock.releaseLock();
  }
}

/* =====================================================================
 * Acionador de 10 minutos (alternativa ao menu Acionadores).
 * ===================================================================== */
function instalarAcionador() {
  removerAcionador();
  ScriptApp.newTrigger(CONFIG.FUNCAO_ACIONADOR).timeBased().everyMinutes(CONFIG.MINUTOS_ACIONADOR).create();
  Logger.log('Acionador criado: %s a cada %s minutos. Ele só atua quando MODO = PRODUCAO.', CONFIG.FUNCAO_ACIONADOR, CONFIG.MINUTOS_ACIONADOR);
}

function removerAcionador() {
  var removidos = 0;
  ScriptApp.getProjectTriggers().forEach(function (tr) {
    if (tr.getHandlerFunction() === CONFIG.FUNCAO_ACIONADOR) { ScriptApp.deleteTrigger(tr); removidos++; }
  });
  Logger.log('%s acionador(es) removido(s).', removidos);
}

/* =====================================================================
 * Funções internas
 * ===================================================================== */
function modo_() {
  var m = String(PropertiesService.getScriptProperties().getProperty('MODO') || 'SIMULAR').trim().toUpperCase();
  return (m === 'TESTE' || m === 'PRODUCAO') ? m : 'SIMULAR';
}

function coletarAceites_(somenteNaoProcessados) {
  var busca = CONFIG.BUSCA + (somenteNaoProcessados ? ' -label:"' + CONFIG.ROTULO_PROCESSADO + '"' : '');
  var threads = GmailApp.search(busca, 0, CONFIG.MAX_THREADS_POR_EXECUCAO);
  var meuSlug = String(PropertiesService.getScriptProperties().getProperty('MEU_SLUG') || '').trim().toLowerCase();
  var eventos = [];
  var idsPorThread = {};

  threads.forEach(function (t) {
    idsPorThread[t.getId()] = [];
    t.getMessages().forEach(function (msg) {
      if (!/invitations@linkedin\.com/i.test(msg.getFrom())) return;
      var assunto = msg.getSubject() || '';
      if (!/aceitou seu convite|accepted your invitation/i.test(assunto)) return;
      var ev = extrairEvento_(msg, assunto, meuSlug);
      eventos.push(ev);
      idsPorThread[t.getId()].push(ev.gmail_message_id);
    });
  });
  return { threads: threads, eventos: eventos, idsPorThread: idsPorThread };
}

function extrairEvento_(msg, assunto, meuSlug) {
  var nome = nomeDoRemetente_(msg.getFrom());
  var primeiro = '';
  var m = assunto.match(/^\s*(.+?)\s+(aceitou seu convite|accepted your invitation)/i);
  if (m) primeiro = m[1].trim();
  if (!primeiro && nome) primeiro = nome.split(' ')[0];

  var texto = msg.getPlainBody() || '';
  var html = msg.getBody() || '';
  return {
    gmail_message_id: msg.getId(),
    nome: nome,
    primeiro_nome: primeiro,
    headline: headlineDoCorpo_(texto, nome),
    profile_slug: slugDoPerfil_(html + '\n' + texto, meuSlug),
    data_conexao: Utilities.formatDate(msg.getDate(), CONFIG.FUSO, 'yyyy-MM-dd')
  };
}

// "Sylvio Oliveira via LinkedIn" <invitations@linkedin.com>  ->  Sylvio Oliveira
function nomeDoRemetente_(from) {
  var s = String(from || '').replace(/<[^>]*>/g, '').replace(/"/g, '').trim();
  s = s.replace(/\s+via\s+linked\s*in\s*$/i, '');
  s = s.replace(/[^\p{L}\p{M}\s'\-]/gu, ' ').replace(/\s+/g, ' ').trim();
  return s;
}

// No corpo em texto, o cargo vem na linha logo abaixo do nome.
function headlineDoCorpo_(texto, nome) {
  var linhas = String(texto).split(/\r?\n/).map(function (l) { return l.replace(/\s+/g, ' ').trim(); });
  var alvo = normalizar_(nome);
  if (!alvo) return '';
  for (var i = 0; i < linhas.length; i++) {
    if (normalizar_(linhas[i]) !== alvo) continue;
    for (var j = i + 1; j < Math.min(linhas.length, i + 4); j++) {
      var l = linhas[j];
      if (!l) continue;
      if (/https?:\/\/|linkedin\.com|^enviar mensagem|^ver perfil|^send message|^view profile|aceitou seu convite|accepted your invitation/i.test(l)) break;
      return l.slice(0, 300);
    }
  }
  return '';
}

// Pega o slug mais frequente dos links /in/<slug>. Descarta parâmetros (otpToken etc).
function slugDoPerfil_(conteudo, meuSlug) {
  var re = /linkedin\.com\/(?:comm\/)?in\/([A-Za-z0-9\-_%À-ɏ]+)/g;
  var cont = {};
  var ordem = [];
  var m;
  while ((m = re.exec(conteudo)) !== null) {
    var s = m[1];
    try { s = decodeURIComponent(s); } catch (e) {}
    s = s.toLowerCase();
    if (meuSlug && s === meuSlug) continue;
    if (!cont[s]) { cont[s] = 0; ordem.push(s); }
    cont[s]++;
  }
  var melhor = '';
  ordem.forEach(function (s) { if (!melhor || cont[s] > cont[melhor]) melhor = s; });
  return melhor;
}

function normalizar_(s) {
  return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^A-Za-z\s]/g, ' ').replace(/\s+/g, ' ').trim().toLowerCase();
}

function enviarAoN8n_(eventos, modoEnvio) {
  var props = PropertiesService.getScriptProperties();
  var url = props.getProperty('N8N_WEBHOOK_URL');
  var token = props.getProperty('N8N_WEBHOOK_TOKEN');
  if (!url || !token) {
    Logger.log('Faltam N8N_WEBHOOK_URL ou N8N_WEBHOOK_TOKEN nas propriedades do script.');
    return null;
  }
  var headers = {};
  headers[CONFIG.HEADER_TOKEN] = token;
  var resp = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    headers: headers,
    payload: JSON.stringify({ origem: 'apps-script-linkedin-leads', modo: modoEnvio, eventos: eventos }),
    muteHttpExceptions: true,
    followRedirects: false
  });
  var codigo = resp.getResponseCode();
  if (codigo !== 200) {
    Logger.log('n8n respondeu HTTP %s: %s', codigo, String(resp.getContentText()).slice(0, 300));
    return null;
  }
  try {
    return JSON.parse(resp.getContentText());
  } catch (e) {
    Logger.log('Resposta do n8n não é JSON: %s', String(resp.getContentText()).slice(0, 300));
    return null;
  }
}
