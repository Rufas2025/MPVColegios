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
    Logger.log('#%s %s | primeiro nome: %s | cargo: %s (fonte: %s) | perfil: linkedin.com/in/%s | data_conexao: %s | recebido: %s',
      i + 1, e.nome, e.primeiro_nome, e.headline || '(ausente no e-mail)', e._fonte_cargo || '-',
      e.profile_slug || '(não encontrado)', e.data_conexao, e._recebido);
  });
  // Diagnóstico: se algum cargo ficou ausente, mostra o corpo do 1º desses e-mails
  // sem nenhum link (os links do LinkedIn carregam tokens de login).
  var semCargo = lote.eventos.filter(function (e) { return !e.headline; })[0];
  if (semCargo) {
    Logger.log('--- DIAGNÓSTICO (%s): corpo em texto, links removidos ---', semCargo.nome);
    linhasSemLinks_(semCargo._texto).slice(0, 30).forEach(function (l, i) { Logger.log('T%s: %s', i + 1, l); });
    Logger.log('--- DIAGNÓSTICO (%s): corpo HTML convertido em texto, links removidos ---', semCargo.nome);
    linhasSemLinks_(semCargo._htmlTexto).slice(0, 30).forEach(function (l, i) { Logger.log('H%s: %s', i + 1, l); });
  }
}

function linhasSemLinks_(texto) {
  return String(texto || '').split(/\r?\n/)
    .map(function (l) { return l.replace(/(https?:\/\/|www\.)\S+/gi, '[link]').replace(/\S*token\S*/gi, '[removido]').replace(/\s+/g, ' ').trim(); })
    .filter(function (l) { return l && l !== '[link]'; });
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
  var htmlTexto = htmlParaTexto_(html);
  var cargo = headlineDoCorpo_(texto, nome, primeiro);
  var fonte = cargo ? 'texto' : '';
  if (!cargo) { cargo = headlineDoCorpo_(htmlTexto, nome, primeiro); fonte = cargo ? 'html' : ''; }
  return {
    gmail_message_id: msg.getId(),
    nome: nome,
    primeiro_nome: primeiro,
    headline: cargo,               // vazio quando o e-mail não traz cargo: nunca inventado
    profile_slug: slugDoPerfil_(html + '\n' + texto, meuSlug),
    // data_conexao = dia (Brasília) em que a notificação chegou na caixa
    data_conexao: Utilities.formatDate(msg.getDate(), CONFIG.FUSO, 'yyyy-MM-dd'),
    // campos com _ são só para o log local; enviarAoN8n_ remove antes de enviar
    _recebido: Utilities.formatDate(msg.getDate(), CONFIG.FUSO, 'dd/MM/yyyy HH:mm'),
    _fonte_cargo: fonte,
    _texto: texto,
    _htmlTexto: htmlTexto
  };
}

var ENTIDADES_ = {
  aacute: 'á', Aacute: 'Á', agrave: 'à', Agrave: 'À', acirc: 'â', Acirc: 'Â', atilde: 'ã', Atilde: 'Ã',
  eacute: 'é', Eacute: 'É', ecirc: 'ê', Ecirc: 'Ê', iacute: 'í', Iacute: 'Í',
  oacute: 'ó', Oacute: 'Ó', ocirc: 'ô', Ocirc: 'Ô', otilde: 'õ', Otilde: 'Õ',
  uacute: 'ú', Uacute: 'Ú', uuml: 'ü', Uuml: 'Ü', ccedil: 'ç', Ccedil: 'Ç',
  ntilde: 'ñ', Ntilde: 'Ñ', middot: '·', bull: '•', ndash: '-', mdash: '-',
  lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”', hellip: '...'
};

// Converte o HTML do e-mail em linhas de texto (uma por bloco visual).
function htmlParaTexto_(html) {
  var s = String(html || '');
  s = s.replace(/<(style|script|head)[\s\S]*?<\/\1>/gi, ' ');
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<\/(p|div|td|tr|li|h[1-6]|table|a|span)>/gi, '\n');
  s = s.replace(/<[^>]+>/g, ' ');
  s = s.replace(/&nbsp;/gi, ' ').replace(/&amp;/gi, '&').replace(/&quot;/gi, '"')
       .replace(/&#39;|&apos;/gi, "'").replace(/&lt;/gi, '<').replace(/&gt;/gi, '>')
       .replace(/&#(\d+);/g, function (m, n) { return String.fromCharCode(parseInt(n, 10)); })
       .replace(/&#x([0-9a-f]+);/gi, function (m, n) { return String.fromCharCode(parseInt(n, 16)); })
       .replace(/&([a-z]+);/gi, function (m, n) { return ENTIDADES_[n] || m; });
  return s.split(/\n/).map(function (l) { return l.replace(/\s+/g, ' ').trim(); })
    .filter(function (l) { return l; }).join('\n');
}

// "Sylvio Oliveira via LinkedIn" <invitations@linkedin.com>  ->  Sylvio Oliveira
function nomeDoRemetente_(from) {
  var s = String(from || '').replace(/<[^>]*>/g, '').replace(/"/g, '').trim();
  s = s.replace(/\s+via\s+linked\s*in\s*$/i, '');
  s = s.replace(/[^\p{L}\p{M}\s'\-]/gu, ' ').replace(/\s+/g, ' ').trim();
  return s;
}

// O cargo (headline) é a primeira linha útil logo abaixo da linha com o nome.
// Se o e-mail não tiver essa linha, devolve '' (cargo ausente).
var LINHA_NAO_CARGO = /https?:\/\/|www\.|linkedin\.com|\[link\]|^enviar mensagem|^ver perfil|^send message|^view profile|^mensagem$|^message$|aceitou seu convite|accepted your invitation|conhe[cç]a a rede|^ver todos|^ver conex|cancelar inscri|unsubscribe|^\W*$/i;
function headlineDoCorpo_(texto, nome, primeiro) {
  var linhas = String(texto || '').split(/\r?\n/).map(function (l) { return l.replace(/\s+/g, ' ').trim(); });
  var alvos = [normalizar_(nome)];
  var alvoPrimeiro = normalizar_(primeiro);
  if (alvoPrimeiro && alvoPrimeiro.indexOf(' ') > 0) alvos.push(alvoPrimeiro);
  alvos = alvos.filter(function (a) { return a && a.length >= 3; });
  if (alvos.length === 0) return '';
  for (var i = 0; i < linhas.length; i++) {
    var n = normalizar_(linhas[i]);
    if (alvos.indexOf(n) < 0) continue;
    for (var j = i + 1; j < Math.min(linhas.length, i + 4); j++) {
      var l = linhas[j];
      if (!l) continue;
      var nl = normalizar_(l);
      if (alvos.indexOf(nl) >= 0) continue;          // nome repetido
      if (LINHA_NAO_CARGO.test(l)) break;            // botão, link ou rodapé: sem cargo
      if (l.length < 3) break;
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
    // Mantém o slug como está no link (ex.: %e2%80%98 continua codificado),
    // para a URL do perfil continuar válida.
    var s = m[1].toLowerCase();
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
  // Envia só os campos públicos (remove _texto, _htmlTexto etc. do log local).
  eventos = eventos.map(function (e) {
    var limpo = {};
    Object.keys(e).forEach(function (k) { if (k.charAt(0) !== '_') limpo[k] = e[k]; });
    return limpo;
  });
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
