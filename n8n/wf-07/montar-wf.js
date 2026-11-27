// Gera wf-07-balanco.n8n.ts a partir de balanco.sql e formatar.js.
const fs = require('fs');
const q = fs.readFileSync(__dirname + '/balanco.sql', 'utf8').trim();
const fmt = fs.readFileSync(__dirname + '/formatar.js', 'utf8');
const ts = `import { workflow, node, trigger, newCredential, expr } from '@n8n/workflow-sdk';

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
    parameters: { operation: 'executeQuery', query: ${JSON.stringify(q)}, options: {} },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

const formatar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Montar Mensagem', parameters: { mode: 'runOnceForAllItems', jsCode: ${JSON.stringify(fmt)} } }
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
`;
fs.writeFileSync(__dirname + '/wf-07-balanco.n8n.ts', ts);
console.log('ok', ts.length);
