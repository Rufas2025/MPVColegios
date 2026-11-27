import { workflow, node, trigger, newCredential, expr } from '@n8n/workflow-sdk';

// WF-07: balanço semanal no Telegram (Anderson, 27/11/2026). Segunda 8h, antes dos cartões das 9h.
// Somente leitura no banco. Gerado por n8n/wf-07/montar-wf.js: editar os arquivos-fonte, não este.

const agenda = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: { name: 'Segunda 8h', parameters: { rule: { interval: [{ field: 'cronExpression', expression: '0 0 8 * * 1' }] } } }
});

const consulta = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Balanço (Postgres)',
    parameters: { operation: 'executeQuery', query: "-- WF-07 Balanço semanal (Anderson, 27/11/2026): toda segunda 8h, números da semana anterior (seg a dom)\n-- e do acumulado. Somente leitura. Uma linha com um JSON.\n--   enviada   = evento MARCADO_COMO_ENVIADO (primeiro);\n--   respondeu = histórico com new_status RESPONDEU (botão do lembrete ou /respondeu);\n--   tipo      = última versão da mensagem: modelo (sem edited_by), automática (auto-pesquisa:*), feita à mão (resto);\n--   contatos de teste (nome começando com \"teste\") ficam de fora;\n--   perfil    = mesmo critério do WF-01E (mantenedor / pedagógico / gestão), sobre título + cargo.\nWITH jan AS (\n    SELECT (date_trunc('week', now() AT TIME ZONE 'America/Sao_Paulo') - interval '7 days') AT TIME ZONE 'America/Sao_Paulo' AS ini,\n           date_trunc('week', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo' AS fim\n), env AS (\n    SELECT d.connection_id, min(d.event_at) AS enviado_em\n      FROM rufino_linkedin.delivery_events d\n     WHERE d.event_type = 'MARCADO_COMO_ENVIADO'\n     GROUP BY d.connection_id\n), resp AS (\n    SELECT h.connection_id, min(h.created_at) AS respondeu_em\n      FROM rufino_linkedin.connection_status_history h\n     WHERE h.new_status = 'RESPONDEU'\n     GROUP BY h.connection_id\n), ult AS (\n    SELECT DISTINCT ON (m.connection_id) m.connection_id, m.edited_by\n      FROM rufino_linkedin.message_versions m\n     ORDER BY m.connection_id, m.version DESC\n), base AS (\n    SELECT c.connection_id, c.nome, c.status, e.enviado_em, r.respondeu_em,\n           CASE WHEN u.edited_by IS NULL THEN 'Modelo padrão'\n                WHEN u.edited_by LIKE 'auto-pesquisa:%' THEN 'Personalizada automática'\n                ELSE 'Personalizada à mão' END AS tipo,\n           CASE WHEN t.h ~ '(mantenedor|fundador|founder|\\msoci[oa]\\M|proprietari|\\mowner\\M|\\mceo\\M|presidente)' THEN 'Mantenedor'\n                WHEN t.h ~ '(pedagogic|coordenador|coordenacao|academic|diretora? de ensino)' THEN 'Pedagógico'\n                ELSE 'Gestão' END AS perfil\n      FROM env e\n      JOIN rufino_linkedin.connections c ON c.connection_id = e.connection_id AND c.nome NOT ILIKE 'teste%'\n      LEFT JOIN resp r ON r.connection_id = e.connection_id\n      LEFT JOIN ult u ON u.connection_id = e.connection_id\n      CROSS JOIN LATERAL (\n          SELECT translate(lower(coalesce((SELECT a.resumo FROM rufino_linkedin.analyses a\n                                            WHERE a.connection_id = c.connection_id\n                                            ORDER BY a.created_at DESC LIMIT 1), '') || ' ' || coalesce(c.cargo, '')),\n                           'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc') AS h\n      ) t\n)\nSELECT json_build_object(\n    'semana', to_char(j.ini AT TIME ZONE 'America/Sao_Paulo', 'DD/MM') || ' a '\n              || to_char((j.fim AT TIME ZONE 'America/Sao_Paulo') - interval '1 day', 'DD/MM'),\n    'aceites_semana', (SELECT count(*) FROM rufino_linkedin.connections c\n                        WHERE c.created_at >= j.ini AND c.created_at < j.fim AND c.nome NOT ILIKE 'teste%'),\n    'enviadas_semana', (SELECT count(*) FROM base b WHERE b.enviado_em >= j.ini AND b.enviado_em < j.fim),\n    'responderam_das_enviadas_semana', (SELECT count(*) FROM base b\n                                         WHERE b.enviado_em >= j.ini AND b.enviado_em < j.fim AND b.respondeu_em IS NOT NULL),\n    'respostas_na_semana', (SELECT coalesce(json_agg(b.nome ORDER BY b.respondeu_em), '[]'::json) FROM base b\n                             WHERE b.respondeu_em >= j.ini AND b.respondeu_em < j.fim),\n    'total_enviadas', (SELECT count(*) FROM base),\n    'total_responderam', (SELECT count(*) FROM base b WHERE b.respondeu_em IS NOT NULL),\n    'por_tipo', (SELECT coalesce(json_agg(x ORDER BY x.enviadas DESC), '[]'::json) FROM (\n                   SELECT b.tipo AS nome, count(*) AS enviadas, count(b.respondeu_em) AS responderam\n                     FROM base b GROUP BY b.tipo) x),\n    'por_perfil', (SELECT coalesce(json_agg(x ORDER BY x.enviadas DESC), '[]'::json) FROM (\n                     SELECT b.perfil AS nome, count(*) AS enviadas, count(b.respondeu_em) AS responderam\n                       FROM base b GROUP BY b.perfil) x),\n    'sem_resposta_7d', (SELECT count(*) FROM base b\n                         WHERE b.status = 'FOLLOWUP_PENDENTE' AND b.enviado_em < now() - interval '7 days'),\n    'sem_resposta_7d_nomes', (SELECT coalesce(json_agg(x.nome ORDER BY x.enviado_em), '[]'::json) FROM (\n                               SELECT b.nome, b.enviado_em FROM base b\n                                WHERE b.status = 'FOLLOWUP_PENDENTE' AND b.enviado_em < now() - interval '7 days'\n                                ORDER BY b.enviado_em LIMIT 12) x),\n    'aguardando_aprovacao', (SELECT count(*) FROM rufino_linkedin.connections c\n                              WHERE c.status IN ('AGUARDANDO_APROVACAO', 'REFAZER') AND c.nome NOT ILIKE 'teste%'),\n    'falta_marcar_enviada', (SELECT count(*) FROM rufino_linkedin.connections c\n                              WHERE c.status IN ('APROVADO', 'PRONTO_PARA_ENVIO') AND c.nome NOT ILIKE 'teste%')\n) AS balanco\n  FROM jan j;", options: {} },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

const formatar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Montar Mensagem', parameters: { mode: 'runOnceForAllItems', jsCode: "// Monta a mensagem do balanço semanal (WF-07) a partir do JSON da consulta. Texto para o Anderson, não para lead.\nfunction esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }\nfunction pct(r, e) { return e ? Math.round((100 * r) / e) + '%' : '0%'; }\nvar b = ($input.first().json || {}).balanco || {};\nif (typeof b === 'string') b = JSON.parse(b);\nvar L = [];\nL.push('📊 <b>Balanço LinkedIn: semana de ' + esc(b.semana) + '</b>');\nL.push('');\nL.push('<b>Na semana</b>');\nL.push('Aceites novos: ' + (b.aceites_semana || 0));\nL.push('Mensagens enviadas: ' + (b.enviadas_semana || 0) + (b.enviadas_semana ? ' (já responderam: ' + (b.responderam_das_enviadas_semana || 0) + ')' : ''));\nvar rs = b.respostas_na_semana || [];\nL.push('Respostas registradas: ' + rs.length + (rs.length ? ' (' + rs.map(esc).join(', ') + ')' : ''));\nL.push('');\nL.push('<b>Desde o começo</b>');\nL.push('Enviadas: ' + (b.total_enviadas || 0) + ' · Responderam: ' + (b.total_responderam || 0) + ' (' + pct(b.total_responderam || 0, b.total_enviadas || 0) + ')');\nL.push('Por tipo de mensagem:');\n(b.por_tipo || []).forEach(function (x) { L.push('• ' + esc(x.nome) + ': ' + x.responderam + ' de ' + x.enviadas + ' (' + pct(x.responderam, x.enviadas) + ')'); });\nL.push('Por perfil:');\n(b.por_perfil || []).forEach(function (x) { L.push('• ' + esc(x.nome) + ': ' + x.responderam + ' de ' + x.enviadas + ' (' + pct(x.responderam, x.enviadas) + ')'); });\nvar pouco = (b.por_tipo || []).some(function (x) { return x.enviadas < 20; });\nif (pouco) L.push('<i>Algum grupo ainda tem menos de 20 enviadas: a comparação ainda é fraca.</i>');\nL.push('');\nL.push('<b>Pendências</b>');\nL.push('Cartões esperando aprovação: ' + (b.aguardando_aprovacao || 0));\nL.push('Aprovadas sem marcar como enviada: ' + (b.falta_marcar_enviada || 0));\nvar sr = b.sem_resposta_7d_nomes || [];\nL.push('Sem resposta há mais de 7 dias: ' + (b.sem_resposta_7d || 0) + (sr.length ? ' (' + sr.map(esc).join(', ') + (b.sem_resposta_7d > sr.length ? '...' : '') + ')' : ''));\nL.push('');\nL.push('Quando alguém responder no LinkedIn, mande aqui: /respondeu Nome. Sem isso, a resposta só entra na conta no lembrete de follow-up.');\nreturn [{ json: { texto: L.join('\\n').slice(0, 4000) } }];\n" } }
});

const enviar = node({
  type: 'n8n-nodes-base.telegram',
  version: 1.2,
  config: {
    name: 'Enviar Balanço',
    parameters: {
      resource: 'message',
      operation: 'sendMessage',
      chatId: '5550833898',
      text: expr('{{ $json.texto }}'),
      additionalFields: { appendAttribution: false, parse_mode: 'HTML', disable_web_page_preview: true }
    },
    credentials: { telegramApi: newCredential('Rufino LinkedIn DEV - Telegram') }
  }
});

export default workflow('wf-07', 'WF-07 - Balanço Semanal - Rufino LinkedIn DEV')
  .add(agenda)
  .to(consulta)
  .to(formatar)
  .to(enviar);
