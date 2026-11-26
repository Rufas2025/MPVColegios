// Gera wf-06-personalizar.n8n.ts a partir de consulta.sql, prompt-sistema.txt, montar.js e validar.js.
const fs = require('fs');
const q = fs.readFileSync(__dirname + '/consulta.sql', 'utf8').trim();
const montar = fs.readFileSync(__dirname + '/montar.gerado.js', 'utf8');
const validar = fs.readFileSync(__dirname + '/validar.js', 'utf8');
const ts = `import { workflow, node, trigger, newCredential, expr } from '@n8n/workflow-sdk';

// WF-06: mensagem D+1 personalizada com a pesquisa pública (fase 2, autorizada por Anderson em 26/11/2026).
// Dias úteis 8h30 (antes do WF-02 das 9h). Gerado por n8n/wf-06/montar-wf.js: editar os arquivos-fonte, não este.

const agenda = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: { name: 'Dias úteis 8h30', parameters: { rule: { interval: [{ field: 'cronExpression', expression: '0 30 8 * * 1-5' }] } } }
});

const contatos = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Contatos do Dia',
    parameters: { operation: 'executeQuery', query: ${JSON.stringify(q)}, options: {} },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

const montar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Montar Pedido', parameters: { mode: 'runOnceForAllItems', jsCode: ${JSON.stringify(montar)} } }
});

const claude = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Claude Escrever',
    parameters: {
      method: 'POST',
      url: 'https://api.anthropic.com/v1/messages',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'anthropicApi',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [
        { name: 'anthropic-version', value: '2023-06-01' },
        { name: 'anthropic-beta', value: 'server-side-fallback-2026-07-01' }
      ] },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.llm_body) }}'),
      options: { timeout: 120000, batching: { batch: { batchSize: 1, batchInterval: 500 } }, response: { response: { neverError: true } } }
    },
    credentials: { anthropicApi: newCredential('Anthropic API - Pesquisa') }
  }
});

const validar = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: { name: 'Validar', parameters: { mode: 'runOnceForAllItems', jsCode: ${JSON.stringify(validar)} } }
});

const somenteOk = node({
  type: 'n8n-nodes-base.filter',
  version: 2.3,
  config: {
    name: 'Somente Aprovadas na Validação',
    parameters: { conditions: { combinator: 'and', options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
      conditions: [{ leftValue: expr('{{ $json.ok }}'), rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }] } }
  }
});

const gravar = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Gravar Versão',
    parameters: {
      operation: 'executeQuery',
      query: "SELECT * FROM rufino_linkedin.save_auto_message($1::uuid, $2, $3, 'WF-06', $4);",
      options: { queryReplacement: expr("{{ [ $json.connection_id, $json.mensagem, 'auto-pesquisa:' + ($json.modelo_usado || 'claude-opus-5-5'), String($execution.id) ] }}") }
    },
    credentials: { postgres: newCredential('Rufino LinkedIn DEV') }
  }
});

export default workflow('wf-06', 'WF-06 - Mensagem Personalizada (Pesquisa) - Rufino LinkedIn DEV')
  .add(agenda)
  .to(contatos)
  .to(montar)
  .to(claude)
  .to(validar)
  .to(somenteOk)
  .to(gravar);
`;
fs.writeFileSync(__dirname + '/wf-06-personalizar.n8n.ts', ts);
console.log('ok', ts.length);
