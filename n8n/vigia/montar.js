// Gera wf-90-vigia.n8n.ts a partir de vigia-fatos.sql e vigia-avaliar.js (fontes de verdade).
// Uso: node n8n/vigia/montar.js
const fs = require('fs'), path = require('path');
const dir = __dirname;
const sql = fs.readFileSync(path.join(dir, 'vigia-fatos.sql'), 'utf8');
const avaliar = fs.readFileSync(path.join(dir, 'vigia-avaliar.js'), 'utf8');
const lit = s => '`' + s.replace(/\\/g, '\\\\').replace(/`/g, '\\`').replace(/\$\{/g, '\\${') + '`';

const alertaErro = `// Alerta imediato quando um workflow da cadência falha em produção (Error Trigger).
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
return [{ json: { enviar: true, telegram_text: texto } }];`;

const ts = `// GERADO por n8n/vigia/montar.js a partir de vigia-fatos.sql e vigia-avaliar.js. Não editar à mão.
// WF-90 Vigia - Rufino LinkedIn DEV
//  - 8h40 dias úteis: relatório sempre (se não chegar, o próprio silêncio é o alarme).
//  - 15h dias úteis: só envia se houver falha.
//  - 18h dias úteis: fechamento do dia (enviados, descartados, respostas, pendências, amanhã).
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
const noite = trigger({
  type: 'n8n-nodes-base.scheduleTrigger', version: 1.3,
  config: { name: 'Noite 18h', parameters: { rule: { interval: [{ field: 'weeks', weeksInterval: 1, triggerAtDay: [1, 2, 3, 4, 5], triggerAtHour: 18, triggerAtMinute: 0 }] } } }
});
const modoNoite = node({
  type: 'n8n-nodes-base.noOp', version: 1, config: { name: 'Modo Noite' }
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
    parameters: { operation: 'executeQuery', query: ${lit(sql)}, options: {} },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') },
    executeOnce: true
  }
});
const avaliar = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Avaliar', parameters: { mode: 'runOnceForAllItems', jsCode: ${lit(avaliar)} } }
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
  config: { name: 'Montar Alerta de Falha', parameters: { mode: 'runOnceForAllItems', jsCode: ${lit(alertaErro)} } }
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
  .add(noite).to(modoNoite).to(feriados)
  .add(erro).to(montarErro).to(telegram);
`;
fs.writeFileSync(path.join(dir, 'wf-90-vigia.n8n.ts'), ts);
console.log('ok', ts.length);
