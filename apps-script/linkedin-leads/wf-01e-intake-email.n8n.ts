import { workflow, node, trigger, newCredential, expr } from '@n8n/workflow-sdk';

const webhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'Webhook Aceites (Apps Script)',
    parameters: {
      httpMethod: 'POST',
      path: 'rufino-linkedin-aceites',
      authentication: 'headerAuth',
      responseMode: 'responseNode',
      options: {}
    },
    credentials: { httpHeaderAuth: newCredential('Apps Script - Token Aceites LinkedIn') }
  }
});

const preparar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Preparar Eventos',
    parameters: {
      mode: 'runOnceForAllItems',
      jsCode: `// Trava do servidor: liberada em 20/11/2026 por Anderson ("pode liberar").
// Para travar de novo, volte para false e publique.
const PROCESSAMENTO_REAL = true;

const req = $input.first().json || {};
const body = req.body || {};
const modo = String(body.modo || '').toLowerCase() === 'producao' ? 'producao' : 'teste';
const eventos = Array.isArray(body.eventos) ? body.eventos.slice(0, 50) : [];

function limpar(s) { return String(s == null ? '' : s).replace(/\\s+/g, ' ').trim(); }
function semAcento(s) { return limpar(s).normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase(); }
function limparNome(n) {
  var s = limpar(n).replace(/\\s+via\\s+linked\\s*in.*$/i, '');
  s = s.replace(/[^\\p{L}\\p{M}\\s'\\-]/gu, ' ').replace(/\\s+/g, ' ').trim();
  return s;
}

var FEM = new Set(['raquel','isabel','mabel','ingrid','ruth','ester','esther','carmen','karen','ellen','suellen','evelyn','jocelyn','miriam','myriam','beatriz','thais','tais','ines','iris','liz','lis','abigail','rachel','lourdes','mercedes','doris']);
var MASC = new Set(['felipe','filipe','henrique','jorge','alexandre','jose','andre','guilherme','vicente','clemente','dante','duarte','jaime','rene','onofre','davi','levi','ravi','luca','wesley','sidney','rodney','rudney']);
function genero(primeiro) {
  var p = semAcento(primeiro).replace(/[^a-z]/g, '');
  if (!p) return 'N';
  if (FEM.has(p)) return 'F';
  if (MASC.has(p)) return 'M';
  var u = p.slice(-1);
  if (u === 'a') return 'F';
  if (u === 'o') return 'M';
  if ('bcdfghjklmnpqrstvwxz'.indexOf(u) >= 0) return 'M';
  return 'N';
}

var FORTE_FORA = /(ajudamos|consultori|fornecedor|edtech|plataforma|software|startup|vendas|comercial|marketing|representante|recrutador|recursos humanos|secretaria|prefeitura|municipal|estadual|governo|rede publica|seduc|semed|ministerio)/;
var FRACO_FORA = /(universidade|faculdade|centro universitario|ensino superior|anhanguera|estacio|kroton|cogna|curso livre|idiomas|curso de ingles)/;
var DECISOR = /(diretor|diretora|director|principal|head of school|mantenedor|mantenedora|proprietari|socio|socia|fundador|fundadora|\\bceo\\b|presidente)/;
var ESCOLA_CTX = /(colegio|\\bescola\\b|escolar|school|educacional|educacao|ensino|pedagogic|maple bear|bilingue|infantil|instituto|educandario|liceu)/;
var NAO_DECISOR = /(coordenador|coordenadora|coordenacao|orientador|orientadora|orientacao|professor|professora|analista|assistente|supervisor|supervisora)/;

function classificar(headline) {
  var h = semAcento(headline);
  if (!h) return { c: 'REVISAR', motivo: 'e-mail sem cargo' };
  var decisor = DECISOR.test(h);
  var escola = ESCOLA_CTX.test(h);
  if (FORTE_FORA.test(h)) return { c: 'FORA_ICP', motivo: 'fornecedor, governo/rede publica ou area comercial' };
  if (decisor && escola) {
    if (FRACO_FORA.test(h)) return { c: 'REVISAR', motivo: 'decisor, mas cita ensino superior ou idiomas' };
    return { c: 'ICP', motivo: 'decisor de escola' };
  }
  if (FRACO_FORA.test(h)) return { c: 'FORA_ICP', motivo: 'ensino superior ou idiomas' };
  if (decisor) return { c: 'REVISAR', motivo: 'decisor sem escola clara no cargo' };
  if (NAO_DECISOR.test(h)) return { c: 'FORA_ICP', motivo: 'cargo sem decisao (coordenacao, orientacao ou docencia)' };
  return { c: 'REVISAR', motivo: 'cargo nao reconhecido' };
}

var ESCOLA_NOME = /(col[eé]gio|\\bescola\\b|school|instituto|educand[aá]rio|liceu|maple bear|grupo educacional|rede de ensino|sistema de ensino|centro educacional|centro de ensino)/i;
var CARGO_INICIO = /^(diretor|diretora|director|head|principal|ceo|fundador|fundadora|mantenedor|mantenedora|presidente|s[oó]cio|s[oó]cia|propriet[aá]rio|propriet[aá]ria|gestor|gestora|coordenador|coordenadora|orientador|orientadora|professor|professora|supervisor|supervisora|analista|assistente)\\b/i;
var CARGO_DENTRO = /(principal|diretor|diretora|director|\\bceo\\b|consultant|consultor|speaker|gestor|gestora|\\bhead\\b)/i;
function extrairEscola(headline) {
  var partes = limpar(headline).split(/\\s*[|•·]\\s*|\\s+[-–—]\\s+/);
  for (var i = 0; i < partes.length; i++) {
    var p = limpar(partes[i]);
    if (!ESCOLA_NOME.test(p)) continue;
    var nome = p;
    if (CARGO_INICIO.test(p)) {
      var m = p.match(/\\b(?:da empresa|na empresa|no|na|em|do|da|at)\\s+(.+)$/i);
      if (!m) continue;
      nome = limpar(m[1]);
    }
    if (!ESCOLA_NOME.test(nome)) continue;
    if (CARGO_DENTRO.test(nome)) continue;
    if (nome.length < 3 || nome.length > 80) continue;
    return nome;
  }
  return null;
}

function mensagem(primeiro, g, escola) {
  var saud = g === 'M' ? 'Fala' : 'Olá';
  var agr = g === 'M' ? 'Valeu' : 'Obrigado';
  var abertura = '';
  if (escola) {
    var art = /^(col[eé]gio|grupo|instituto|centro|sistema|educand[aá]rio|liceu|externato|complexo|ensino)/i.test(escola) ? 'do' : 'da';
    abertura = 'Vi que você está à frente ' + art + ' ' + escola + '. ';
  }
  return [
    saud + ', ' + primeiro + '! Tudo bem?',
    '',
    agr + ' por ter aceito o meu convite aqui no LinkedIn!',
    '',
    abertura + 'Estou no segmento educacional há cerca de 15 anos e, depois de tantas conversas com diretores e mantenedores pelo Brasil, aprendi uma coisa: tempo talvez seja um dos recursos mais escassos na gestão escolar. Rsrs',
    '',
    'Imagino que sua cabeça já esteja em 2027. São 200 dias letivos para organizar, feriados para encaixar, calendário, equipe, orçamento, metas de rematrícula e retenção... tudo isso enquanto 2026 ainda está acontecendo!',
    '',
    primeiro + ', sei que ainda não nos conhecemos, mas gostaria genuinamente de te ouvir: qual é hoje o seu maior desafio para 2027?',
    '',
    'Não quero tomar seu tempo com uma apresentação comercial. Prefiro começar entendendo o que realmente está na sua mesa.',
    '',
    'Grande abraço,',
    'Rufino'
  ].join('\\n');
}

var hoje = $now.setZone('America/Sao_Paulo').toFormat('yyyy-MM-dd');
var saida = [];
for (var i = 0; i < eventos.length; i++) {
  var e = eventos[i] || {};
  var nome = limparNome(e.nome);
  var primeiro = (limparNome(e.primeiro_nome) || nome).split(' ')[0] || '';
  var slug = String(e.profile_slug || '').trim();
  // Slug como vem no link: letras, digitos, - e _, ou bytes %XX (ex.: %e2%80%98).
  // Nunca decodifica e recusa %XX que viraria / ? # (nada de URL arbitraria).
  slug = slug.toLowerCase();
  var slugOk = slug.length <= 150
    && /^(?:[a-z0-9\\-_\\u00c0-\\u024f]|%[0-9a-f]{2}){3,100}$/.test(slug)
    && !/%(?:2f|3f|23|5c|25|3a|40|26|3d|2b|20|00)/.test(slug);
  var headline = limpar(e.headline).slice(0, 300);
  var data = /^\\d{4}-\\d{2}-\\d{2}$/.test(String(e.data_conexao || '')) ? String(e.data_conexao) : hoje;
  var base = {
    gmail_message_id: limpar(e.gmail_message_id).slice(0, 100),
    modo: modo,
    processamento_real: PROCESSAMENTO_REAL,
    nome: nome,
    primeiro_nome: primeiro,
    headline: headline,
    data_conexao: data
  };
  if (!nome || !primeiro || !slugOk) {
    saida.push({ json: Object.assign(base, { classificacao: 'INVALIDO', motivo: 'nome ou perfil nao identificado no e-mail' }) });
    continue;
  }
  var cl = classificar(headline);
  var escola = extrairEscola(headline);
  var g = genero(primeiro);
  saida.push({ json: Object.assign(base, {
    classificacao: cl.c,
    motivo: cl.motivo,
    escola: escola,
    genero: g,
    cargo: limpar(headline.split(/\\s*[|•·]\\s*/)[0]).slice(0, 120) || null,
    profile_url: 'https://www.linkedin.com/in/' + slug + '/',
    profile_url_norm: 'https://www.linkedin.com/in/' + slug,
    idempotency_key: 'li-' + slug,
    mensagem: cl.c === 'ICP' ? mensagem(primeiro, g, escola) : null,
    ganchos: JSON.stringify([{ gancho: escola || headline || 'aceite do convite', motivo: 'titulo do perfil no e-mail de aceite do LinkedIn' }])
  }) });
}
if (saida.length === 0) {
  saida.push({ json: { classificacao: 'SEM_EVENTOS', modo: modo, processamento_real: PROCESSAMENTO_REAL } });
}
return saida;`
    }
  }
});

const buscarExistentes = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Buscar Existentes',
    executeOnce: true,
    alwaysOutputData: true,
    parameters: {
      operation: 'executeQuery',
      query: `SELECT lower(rtrim(c.profile_url, '/')) AS url
  FROM rufino_linkedin.connections c
 WHERE lower(rtrim(c.profile_url, '/')) = ANY(string_to_array(NULLIF($1, ''), '|'));`,
      options: {
        queryReplacement: expr("{{ [ $('Preparar Eventos').all().map(i => i.json.profile_url_norm || '').filter(Boolean).join('|') ] }}")
      }
    },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

const decidir = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Decidir',
    parameters: {
      mode: 'runOnceForAllItems',
      jsCode: `var existentes = new Set($('Buscar Existentes').all().map(function (i) { return i.json.url; }).filter(Boolean));
return $('Preparar Eventos').all().map(function (it) {
  var j = Object.assign({}, it.json);
  j.ja_existe = !!(j.profile_url_norm && existentes.has(j.profile_url_norm));
  var real = j.processamento_real === true && j.modo === 'producao';
  var status;
  if (j.classificacao === 'SEM_EVENTOS') status = 'SEM_EVENTOS';
  else if (j.classificacao === 'INVALIDO') status = 'INVALIDO';
  else if (j.ja_existe) status = 'JA_CADASTRADO';
  else if (j.classificacao === 'ICP') status = real ? 'REGISTRAR' : 'SIMULADO_ICP';
  else status = j.classificacao;
  j.status = status;
  j.deve_registrar = status === 'REGISTRAR';
  j.processado = real && status !== 'SEM_EVENTOS';
  return { json: j };
});`
    }
  }
});

const responder = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Responder ao Script',
    executeOnce: true,
    parameters: {
      respondWith: 'json',
      responseBody: expr('{{ JSON.stringify({ ok: true, modo: $json.modo, processamento_real: $json.processamento_real === true, resultados: $("Decidir").all().map(i => ({ gmail_message_id: i.json.gmail_message_id || null, status: i.json.status, processado: i.json.processado === true })) }) }}'),
      options: {}
    }
  }
});

const resumo = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Montar Resumo Telegram',
    parameters: {
      mode: 'runOnceForAllItems',
      jsCode: `function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
var itens = $('Decidir').all().map(function (i) { return i.json; });
var real = itens.length > 0 && itens[0].processamento_real === true && itens[0].modo === 'producao';
var lista = [];
var amostra = null;
if (!real) {
  lista.push('<b>TESTE do recebimento por e-mail: nada foi gravado</b>');
  if (itens.length === 1 && itens[0].status === 'SEM_EVENTOS') lista.push('Nenhum aceite no pacote recebido.');
  var rotulo = { SIMULADO_ICP: 'ICP', JA_CADASTRADO: 'JA CADASTRADO', FORA_ICP: 'FORA DO ICP', REVISAR: 'REVISAR', INVALIDO: 'NAO LIDO' };
  itens.forEach(function (j) {
    if (j.status === 'SEM_EVENTOS') return;
    lista.push('');
    lista.push('<b>' + esc(j.nome || '?') + '</b>: ' + (rotulo[j.status] || j.status));
    if (j.headline) lista.push(esc(j.headline));
    if (j.escola) lista.push('Escola: ' + esc(j.escola));
    if (j.motivo && j.status !== 'SIMULADO_ICP') lista.push('Motivo: ' + esc(j.motivo));
    if (j.status === 'SIMULADO_ICP') lista.push('Saudação: ' + (j.genero === 'M' ? 'Fala/Valeu' : 'Olá/Obrigado') + ' | conexão em ' + esc(j.data_conexao));
    if (!amostra && j.mensagem) amostra = j;
  });
} else {
  var atencao = itens.filter(function (j) { return j.status === 'REVISAR' || j.status === 'INVALIDO'; });
  if (atencao.length === 0) return [];
  lista.push('<b>Aceite para você revisar</b> (não entrou na cadência)');
  atencao.forEach(function (j) {
    lista.push('');
    lista.push('<b>' + esc(j.nome || '?') + '</b>');
    if (j.headline) lista.push(esc(j.headline));
    lista.push('Motivo: ' + esc(j.motivo || ''));
  });
}
var texto = lista.join('\\n');
if (amostra) {
  var comAmostra = texto + '\\n\\n<b>Exemplo de mensagem (' + esc(amostra.nome) + '):</b>\\n' + esc(amostra.mensagem);
  if (comAmostra.length <= 4000) texto = comAmostra;
}
if (texto.length > 4000) texto = texto.slice(0, 3990).replace(/<[^>]*$/, '') + '\\n...';
return [{ json: { telegram_text: texto } }];`
    }
  }
});

const telegramResumo = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Enviar Resumo Telegram',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: '5550833898',
      text: expr('{{ $json.telegram_text }}'),
      additionalFields: { appendAttribution: false, parse_mode: 'HTML', disable_web_page_preview: true }
    },
    credentials: { telegramApi: newCredential('Rufino LinkedIn DEV - Telegram') }
  }
});

const filtro = node({
  type: 'n8n-nodes-base.filter',
  version: 2.3,
  config: {
    name: 'Somente Registrar',
    parameters: {
      conditions: {
        combinator: 'and',
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{ leftValue: expr('{{ $json.deve_registrar }}'), rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }]
      }
    }
  }
});

const registrar = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Registrar Conexao',
    parameters: {
      operation: 'executeQuery',
      query: `SELECT * FROM rufino_linkedin.register_connection(
    p_idempotency_key              => $1,
    p_nome                         => $2,
    p_primeiro_nome                => $3,
    p_cargo                        => $4,
    p_instituicao                  => $5,
    p_cidade                       => NULL,
    p_profile_url                  => $6,
    p_conversation_url             => NULL,
    p_data_conexao                 => $7::date,
    p_resumo                       => $8,
    p_ganchos                      => $9::jsonb,
    p_melhor_gancho                => $10,
    p_justificativa                => $11,
    p_confianca                    => 0.6,
    p_sensivel                     => false,
    p_alertas                      => $12::jsonb,
    p_brain_version                => 'intake-email-template-v1',
    p_mensagem                     => $13,
    p_workflow_name                => 'WF-01E',
    p_execution_id                 => $14,
    p_data_conexao_origem          => 'linkedin_email_notificacao_aceite',
    p_data_conexao_confirmado_por  => 'sistema:email-linkedin'
);`,
      options: {
        queryReplacement: expr("{{ [ $json.idempotency_key, $json.nome, $json.primeiro_nome, $json.cargo, $json.escola, $json.profile_url, $json.data_conexao, $json.headline, $json.ganchos, 'Tempo escasso na gestão e planejamento de 2027', 'Entrada automática pelo e-mail de aceite do LinkedIn; modelo aprovado por Anderson em 20/11/2026', '[]', $json.mensagem, String($execution.id) ] }}")
      }
    },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

// ORDEM DOS RAMOS (importante): o n8n (executionOrder v1) executa os ramos
// que saem de "Decidir" de cima para baixo no canvas. "Responder ao Script"
// precisa ficar POR ÚLTIMO (mais abaixo), depois de "Registrar Conexao":
// se o registro falhar, o Apps Script não recebe 200, não rotula o e-mail
// e tenta de novo em 10 minutos. Publicado (versão 1556abae) com:
//   Montar Resumo Telegram y=96 | Somente Registrar y=352 | Responder ao Script y=608.
// Ao reimportar este código, confira as posições antes de publicar.
export default workflow('wf-01e', 'WF-01E - Intake por E-mail (Apps Script) - Rufino LinkedIn DEV')
  .add(webhook)
  .to(preparar)
  .to(buscarExistentes)
  .to(decidir)
  .to(resumo)
  .to(telegramResumo)
  .add(decidir)
  .to(filtro)
  .to(registrar)
  .add(decidir)
  .to(responder);
