// GERADO por n8n/vigia/montar.js a partir de vigia-fatos.sql e vigia-avaliar.js. Não editar à mão.
// WF-90 Vigia - Rufino LinkedIn DEV
//  - 8h40 dias úteis: relatório sempre (se não chegar, o próprio silêncio é o alarme).
//  - 15h dias úteis: só envia se houver falha.
//  - Error Trigger: alerta na hora quando WF-01E/02/05/NOTIFY/ROUTER falham (settings.errorWorkflow deles = este).
// Somente leitura no banco. Nenhum Telegram Trigger (o único continua sendo o WF-ROUTER).
// Fuso do workflow: America/Sao_Paulo.
import { workflow, node, trigger, newCredential, expr } from '@n8n/workflow-sdk';

const manha = trigger({
  type: 'n8n-nodes-base.scheduleTrigger', version: 1.3,
  config: { name: 'Manhã 8h40', parameters: { rule: { interval: [{ field: 'weeks', weeksInterval: 1, triggerAtDay: [1, 2, 3, 4, 5], triggerAtHour: 8, triggerAtMinute: 40 }] } } }
});
const tarde = trigger({
  type: 'n8n-nodes-base.scheduleTrigger', version: 1.3,
  config: { name: 'Tarde 15h', parameters: { rule: { interval: [{ field: 'weeks', weeksInterval: 1, triggerAtDay: [1, 2, 3, 4, 5], triggerAtHour: 15, triggerAtMinute: 0 }] } } }
});
const modoManha = node({
  type: 'n8n-nodes-base.noOp', version: 1, config: { name: 'Modo Manhã' }
});
const modoTarde = node({
  type: 'n8n-nodes-base.noOp', version: 1, config: { name: 'Modo Tarde' }
});
const feriados = node({
  type: 'n8n-nodes-base.dataTable', version: 1.1,
  config: {
    name: 'Ler Feriados',
    parameters: { resource: 'row', operation: 'get', dataTableId: { __rl: true, mode: 'id', value: '68dMfcuKOk9OqDXb', cachedResultName: 'Feriados - Rufino LinkedIn' }, returnAll: true },
    // Tabela vazia não pode calar o relatório das 8h40: segue com um item vazio (o Avaliar ignora).
    alwaysOutputData: true, executeOnce: true
  }
});
const fatos = node({
  type: 'n8n-nodes-base.postgres', version: 2.6,
  config: {
    name: 'Fatos do Banco',
    parameters: { operation: 'executeQuery', query: `-- WF-90 Vigia: fatos do banco para o relatório diário e os alertas.
-- Somente leitura (SELECT). Roda com a credencial do app "Rufino LinkedIn DEV".
-- Devolve uma linha com um JSON; quem decide o que é alerta é o nó "Avaliar" (vigia-avaliar.js),
-- porque só ele conhece os feriados da tabela de dados do n8n.
WITH
fila AS (                      -- mesma ordem de claim_due_connections (WF-02)
    SELECT c.primeiro_nome, c.nome, c.data_conexao, c.scheduled_at, c.created_at,
           row_number() OVER (ORDER BY c.scheduled_at, c.connection_id) AS pos
      FROM rufino_linkedin.connections c
     WHERE c.status = 'AGUARDANDO_D1'
),
botoes AS (                    -- último botão de cada contato que está esperando um toque
    SELECT DISTINCT ON (c.connection_id)
           c.primeiro_nome, c.nome, c.status, t.scope, t.expires_at
      FROM rufino_linkedin.connections c
      JOIN rufino_linkedin.action_tokens t ON t.connection_id = c.connection_id
     WHERE c.status IN ('AGUARDANDO_APROVACAO', 'PRONTO_PARA_ENVIO')
       AND t.consumed_at IS NULL
     ORDER BY c.connection_id, t.created_at DESC
),
followups_abertos AS (
    SELECT f.scheduled_for, f.created_at, f.claimed_at, f.claim_expires_at, c.primeiro_nome, c.nome
      FROM rufino_linkedin.followups f
      JOIN rufino_linkedin.connections c ON c.connection_id = f.connection_id
     WHERE f.executed_at IS NULL
)
SELECT json_build_object(
    'agora', now(),
    'fila', COALESCE((SELECT json_agg(json_build_object(
                'nome', f.nome, 'primeiro', f.primeiro_nome, 'data_conexao', f.data_conexao,
                'scheduled_at', f.scheduled_at, 'created_at', f.created_at) ORDER BY f.pos) FROM fila f), '[]'::json),
    'ultima_reivindicacao_d1', (SELECT max(h.created_at)
                                  FROM rufino_linkedin.connection_status_history h
                                 WHERE h.new_status = 'AGUARDANDO_APROVACAO'
                                   AND h.previous_status = 'AGUARDANDO_D1'),
    -- Aprovações liberadas pelo WF-02 por dia (Brasília) nos últimos 20 dias; "recentes" = aceites de até 4 dias,
    -- que é o volume que a referência de 20/dia mede (as ondas do export ficam de fora).
    'aprovacoes_por_dia', COALESCE((SELECT json_agg(json_build_object('dia', x.dia, 'total', x.total, 'recentes', x.recentes) ORDER BY x.dia)
                              FROM (SELECT (h.created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
                                           count(*) AS total,
                                           count(*) FILTER (WHERE c.data_conexao >= (h.created_at AT TIME ZONE 'America/Sao_Paulo')::date - 4) AS recentes
                                      FROM rufino_linkedin.connection_status_history h
                                      JOIN rufino_linkedin.connections c ON c.connection_id = h.connection_id
                                     WHERE h.new_status = 'AGUARDANDO_APROVACAO' AND h.previous_status = 'AGUARDANDO_D1'
                                       AND h.created_at >= now() - interval '20 days'
                                     GROUP BY 1) x), '[]'::json),
    'ultimo_claim_followup', (SELECT max(f.claimed_at) FROM rufino_linkedin.followups f),
    'botoes', COALESCE((SELECT json_agg(json_build_object(
                'nome', b.nome, 'primeiro', b.primeiro_nome, 'status', b.status,
                'scope', b.scope, 'expires_at', b.expires_at) ORDER BY b.expires_at) FROM botoes b), '[]'::json),
    'sem_botao', (SELECT count(*) FROM rufino_linkedin.connections c
                   WHERE c.status IN ('AGUARDANDO_APROVACAO', 'PRONTO_PARA_ENVIO')
                     AND NOT EXISTS (SELECT 1 FROM rufino_linkedin.action_tokens t
                                      WHERE t.connection_id = c.connection_id AND t.consumed_at IS NULL)),
    'notificacoes_presas', (SELECT count(*) FROM rufino_linkedin.notification_jobs n
                             WHERE n.status IN ('PENDING', 'CLAIMED')
                               AND n.created_at < now() - interval '15 minutes'),
    'followups', COALESCE((SELECT json_agg(json_build_object(
                'nome', fa.nome, 'primeiro', fa.primeiro_nome, 'scheduled_for', fa.scheduled_for, 'created_at', fa.created_at,
                'claimed_at', fa.claimed_at, 'claim_expires_at', fa.claim_expires_at)
                ORDER BY fa.scheduled_for) FROM followups_abertos fa), '[]'::json),
    'erros_abertos', (SELECT count(*) FROM rufino_linkedin.workflow_errors e WHERE NOT e.resolved),
    'status_erro', (SELECT count(*) FROM rufino_linkedin.connections c WHERE c.status = 'ERRO'),
    'ultimo_aceite_email', (SELECT max(c.created_at)
                              FROM rufino_linkedin.connections c
                             WHERE c.data_conexao_origem = 'linkedin_email_notificacao_aceite')
) AS fatos;
`, options: {} },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') },
    executeOnce: true
  }
});
const avaliar = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Avaliar', parameters: { mode: 'runOnceForAllItems', jsCode: `// WF-90 Vigia, nó "Avaliar" (Code, runOnceForAllItems).
// Entrada: "Fatos do Banco" (vigia-fatos.sql) e "Ler Feriados" (tabela de dados Feriados - Rufino LinkedIn).
// Saída: { enviar, texto }. Manhã (8h40): sempre envia (se não chegar, isso já é o alarme).
// Tarde (15h): só envia se houver alerta.
// Horário de Brasília fixo em -03:00 (sem horário de verão desde 2019). Se voltar, ajustar OFFSET.

const OFFSET = '-03:00';
// Regra (Anderson, 21/11/2026): o que manda é o D+1. 20/dia é só referência; se passar de 20 com frequência,
// sobe a referência para 30. Acima da referência a fila sai inteira no D+1, sem segurar ninguém.
const REFERENCIA = 20;               // referência de volume diário
const REFERENCIA_ALTA = 30;          // próxima régua, se a de 20 estourar com frequência
const LIMITE_SEGURANCA = 100;        // p_limit do WF-02: trava contra enxurrada por erro, não é meta
const DIAS_FREQUENTE = 3;            // estouros em 10 dias úteis para sugerir rever a régua
const DIAS_UTEIS_SEM_ACEITE = 5;     // depois disso, suspeitar do acionador do Apps Script

const manha = (() => { try { return $('Modo Manhã').isExecuted; } catch (e) { return false; } })();
const fatos = $('Fatos do Banco').first().json.fatos || {};
const agora = new Date(fatos.agora || Date.now());

// Feriados: só a coluna "data" da tabela (createdAt/updatedAt também são datas e não podem entrar).
const feriados = new Set();
for (const it of $('Ler Feriados').all()) {
  const m = String((it.json || {}).data == null ? '' : it.json.data).match(/^(\\d{4}-\\d{2}-\\d{2})/);
  if (m) feriados.add(m[1]);
}

function dataSP(d) { return new Date(d.getTime() - 3 * 3600e3).toISOString().slice(0, 10); }
function as9h(ymd) { return new Date(ymd + 'T09:00:00' + OFFSET); }
function somaDias(ymd, n) { const d = new Date(ymd + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
function diaUtil(ymd) { const w = new Date(ymd + 'T12:00:00Z').getUTCDay(); return w !== 0 && w !== 6 && !feriados.has(ymd); }
function fmt(d) {
  const s = new Date(new Date(d).getTime() - 3 * 3600e3).toISOString();
  return s.slice(8, 10) + '/' + s.slice(5, 7) + ' ' + s.slice(11, 16);
}
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function nomes(lista, max) {
  const n = lista.slice(0, max || 8).map(x => esc(x.nome || x.primeiro));
  return n.join(', ') + (lista.length > (max || 8) ? ' e mais ' + (lista.length - (max || 8)) : '');
}

const hoje = dataSP(agora);
// Próxima execução do WF-02/WF-05 (9h de dia útil, depois de agora).
let prox = hoje;
while (!diaUtil(prox) || as9h(prox) <= agora) prox = somaDias(prox, 1);
const proxExec = as9h(prox);
// Última execução que já deveria ter acontecido (9h de dia útil, até agora).
let ult = hoje;
while (!diaUtil(ult) || as9h(ult) > agora) ult = somaDias(ult, -1);
const ultExec = as9h(ult);

const alertas = [];   // algo quebrou ou vai se perder
const atencao = [];   // exige ação sua, mas o sistema está funcionando
const info = [];

// 1. Fila de aprovação D+1.
const fila = fatos.fila || [];
const devidos = fila.filter(f => new Date(f.scheduled_at) <= proxExec);
const ficam = devidos.slice(LIMITE_SEGURANCA);
info.push('Aprovações ' + fmt(proxExec) + ': <b>' + Math.min(devidos.length, LIMITE_SEGURANCA) + '</b>' +
  (devidos.length > REFERENCIA ? ' (acima da referência de ' + REFERENCIA + '; sai tudo no D+1)' : ''));
if (ficam.length) {
  alertas.push(devidos.length + ' aprovações para ' + fmt(proxExec) + ', acima da trava de segurança de ' + LIMITE_SEGURANCA +
    ' do WF-02: ' + ficam.length + ' ficariam fora do D+1. Conferir se não é cadastro duplicado antes de subir a trava.');
}
// Frequência: quantos dos últimos 10 dias úteis passaram da referência (só aceites recentes, sem as ondas do export).
const ultimos = (fatos.aprovacoes_por_dia || []).filter(d => diaUtil(String(d.dia).slice(0, 10))).slice(-10);
const acima20 = ultimos.filter(d => d.recentes > REFERENCIA).length;
const acima30 = ultimos.filter(d => d.recentes > REFERENCIA_ALTA).length;
if (acima30 >= DIAS_FREQUENTE) {
  atencao.push('Aceites novos passaram de ' + REFERENCIA_ALTA + '/dia em ' + acima30 + ' dos últimos ' + ultimos.length +
    ' dias úteis. Hora de rever a régua de novo.');
} else if (acima20 >= DIAS_FREQUENTE) {
  atencao.push('Aceites novos passaram de ' + REFERENCIA + '/dia em ' + acima20 + ' dos últimos ' + ultimos.length +
    ' dias úteis. Sugestão: subir a referência para ' + REFERENCIA_ALTA + '.');
}

// 2. WF-02 rodou na última janela?
// Só conta quem já existia na hora da execução (as ondas do export entram com data antiga).
const devidosNaUltima = fila.filter(f => new Date(f.scheduled_at) <= ultExec && new Date(f.created_at) <= ultExec);
const ultimaRev = fatos.ultima_reivindicacao_d1 ? new Date(fatos.ultima_reivindicacao_d1) : null;
if (agora - ultExec > 15 * 60e3 && devidosNaUltima.length &&
    (!ultimaRev || ultimaRev < new Date(ultExec.getTime() - 2 * 60e3))) {
  alertas.push('WF-02 não reivindicou ninguém em ' + fmt(ultExec) + ', com ' + devidosNaUltima.length +
    ' contato(s) já vencido(s). Conferir se o WF-02 está ativo e se ' + ult.slice(8, 10) + '/' + ult.slice(5, 7) + ' não é feriado esquecido na tabela.');
}

// 3. Botões de aprovação/entrega.
const botoes = fatos.botoes || [];
const vencidos = botoes.filter(b => new Date(b.expires_at) <= agora);
const vencendo = botoes.filter(b => new Date(b.expires_at) > agora && new Date(b.expires_at) - agora < 48 * 3600e3);
if (vencidos.length) {
  alertas.push(vencidos.length + ' botão(ões) já vencido(s), sem reenvio automático: ' + nomes(vencidos) +
    '. Precisa reemitir pelo Claude.');
}
if (vencendo.length) {
  atencao.push(vencendo.length + ' botão(ões) vencem em menos de 48h: ' +
    vencendo.slice(0, 8).map(b => esc(b.nome) + ' (' + (b.scope === 'APPROVAL' ? 'aprovar' : 'marcar enviada') + ', até ' + fmt(b.expires_at) + ')').join(', ') + '.');
}
const aguardandoToque = botoes.length - vencidos.length;
if (aguardandoToque) info.push('Esperando seu toque: ' + aguardandoToque);
if (fatos.sem_botao > 0) alertas.push(fatos.sem_botao + ' contato(s) esperando aprovação/entrega sem nenhum botão válido.');

// 4. WF-NOTIFY.
if (fatos.notificacoes_presas > 0) {
  alertas.push(fatos.notificacoes_presas + ' notificação(ões) do Telegram presa(s) há mais de 15 min. Conferir o WF-NOTIFY.');
}

// 5. Follow-ups (WF-05).
const fups = fatos.followups || [];
const livre = f => !f.claim_expires_at || new Date(f.claim_expires_at) <= agora;
const fupProx = fups.filter(f => livre(f) && new Date(f.scheduled_for) <= proxExec);
const ultimoClaimFup = fatos.ultimo_claim_followup ? new Date(fatos.ultimo_claim_followup) : null;
const fupPerdidos = fups.filter(f => livre(f) && new Date(f.scheduled_for) <= ultExec && new Date(f.created_at) <= ultExec &&
  agora - ultExec > 15 * 60e3 && (!ultimoClaimFup || ultimoClaimFup < new Date(ultExec.getTime() - 2 * 60e3)));
const fupEsperando = fups.filter(f => !livre(f));
const fupVencendo = fupEsperando.filter(f => new Date(f.claim_expires_at) - agora < 48 * 3600e3);
info.push('Lembretes de follow-up ' + fmt(proxExec) + ': <b>' + fupProx.length + '</b>' +
  (fupEsperando.length ? ' (+' + fupEsperando.length + ' esperando "Respondeu/Sem resposta")' : ''));
if (fupPerdidos.length) {
  alertas.push('WF-05 não enviou ' + fupPerdidos.length + ' lembrete(s) que venceram até ' + fmt(ultExec) + ': ' + nomes(fupPerdidos) + '.');
}
if (fupVencendo.length) {
  atencao.push(fupVencendo.length + ' lembrete(s) de follow-up perdem o botão em menos de 48h: ' + nomes(fupVencendo) + '.');
}

// 6. Erros registrados.
if (fatos.erros_abertos > 0) alertas.push(fatos.erros_abertos + ' erro(s) abertos em workflow_errors.');
if (fatos.status_erro > 0) alertas.push(fatos.status_erro + ' contato(s) com status ERRO.');

// 7. Entrada de aceites (Apps Script).
if (fatos.ultimo_aceite_email) {
  let d = dataSP(new Date(fatos.ultimo_aceite_email)), uteis = 0;
  while (d < hoje) { d = somaDias(d, 1); if (diaUtil(d)) uteis++; }
  if (uteis >= DIAS_UTEIS_SEM_ACEITE) {
    atencao.push('Nenhum aceite novo registrado há ' + uteis + ' dias úteis (último em ' + fmt(fatos.ultimo_aceite_email) +
      '). Se você mandou convites, confira o acionador do Apps Script.');
  }
}

// 8. Tabela de feriados.
const futuros = [...feriados].filter(f => f >= hoje).sort();
if (!futuros.length || futuros[futuros.length - 1] < somaDias(hoje, 60)) {
  atencao.push('A tabela de feriados acaba em ' + (futuros.length ? futuros[futuros.length - 1] : '(vazia)') +
    '. Cadastrar os feriados seguintes.');
}

const temAlerta = alertas.length > 0;
const enviar = manha || temAlerta;
let texto = (temAlerta ? '🚨' : atencao.length ? '⚠️' : '✅') + ' <b>Vigia ' + (manha ? 'manhã' : 'tarde') + '</b> · ' + fmt(agora) + '\\n';
if (alertas.length) texto += '\\n<b>Falhas</b>\\n' + alertas.map(a => '• ' + a).join('\\n') + '\\n';
if (atencao.length) texto += '\\n<b>Atenção</b>\\n' + atencao.map(a => '• ' + a).join('\\n') + '\\n';
texto += '\\n' + info.join('\\n');
if (!alertas.length && !atencao.length) texto += '\\n\\nTudo funcionando.';

return [{ json: { enviar, tem_alerta: temAlerta, alertas: alertas.length, atencao: atencao.length, telegram_text: texto.slice(0, 4000) } }];
` } }
});
const deveEnviar = node({
  type: 'n8n-nodes-base.filter', version: 2.3,
  config: {
    name: 'Deve Enviar',
    parameters: { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose' }, combinator: 'and',
      conditions: [{ leftValue: expr('{{ $json.enviar }}'), rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }] } }
  }
});
const erro = trigger({
  type: 'n8n-nodes-base.errorTrigger', version: 1, config: { name: 'Falha em Workflow' }
});
const montarErro = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Montar Alerta de Falha', parameters: { mode: 'runOnceForAllItems', jsCode: `// Alerta imediato quando um workflow da cadência falha em produção (Error Trigger).
const e = $input.first().json || {};
const ex = e.execution || {};
const wf = e.workflow || {};
const err = ex.error || (e.trigger && e.trigger.error) || {};
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
const msg = String(err.message || 'erro sem mensagem').slice(0, 600);
const texto = '🚨 <b>Falha em ' + esc(wf.name || 'workflow') + '</b>\\n' +
  'Nó: ' + esc(ex.lastNodeExecuted || (err.node && err.node.name) || '?') + '\\n' +
  'Erro: ' + esc(msg) + '\\n' +
  (ex.id ? 'Execução: ' + esc(ex.id) + '\\n' : '') +
  (ex.url ? '<a href="' + esc(ex.url) + '">Abrir execução</a>' : '');
return [{ json: { enviar: true, telegram_text: texto } }];` } }
});
const telegram = node({
  type: 'n8n-nodes-base.telegram', version: 1.2,
  config: {
    name: 'Enviar Telegram',
    parameters: {
      resource: 'message', operation: 'sendMessage', chatId: '5550833898',
      text: expr('{{ $json.telegram_text }}'),
      additionalFields: { appendAttribution: false, parse_mode: 'HTML', disable_web_page_preview: true }
    },
    credentials: { telegramApi: newCredential('Rufino LinkedIn DEV - Telegram') },
    retryOnFail: true, maxTries: 3, waitBetweenTries: 5000
  }
});

export default workflow('wf-90', 'WF-90 - Vigia (relatório e alertas) - Rufino LinkedIn DEV')
  .add(manha).to(modoManha).to(feriados).to(fatos).to(avaliar).to(deveEnviar).to(telegram)
  .add(tarde).to(modoTarde).to(feriados)
  .add(erro).to(montarErro).to(telegram);
