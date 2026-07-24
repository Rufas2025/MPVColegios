# VALIDATION-REPORT.md — GATE 4

## Instância inspecionada

- n8n **2.29.7**, EasyPanel, projeto pessoal `Anderson Rufino <bado14@gmail.com>` (`Ml3QRAVaQdfd1Bj6`).
- Credenciais reais confirmadas via `list_credentials`: apenas `Rufino LinkedIn DEV` (postgres, `DgnSAHo0I8CRFwci`). Nenhuma credencial Telegram ou Header Auth existe.
- Workflows pré-existentes confirmados via `search_workflows`/`get_workflow_details`: `00 - DB Healthcheck - Rufino LinkedIn DEV` (nunca tocado) e `WF-01 - Intake - Rufino LinkedIn DEV` (id `7qclFIAJGlRPODH8`, placeholder vazio, bloqueado para MCP — `availableInMCP:false`).
- Tipos/versões reais de nó confirmados via `get_node_types` (nunca assumidos de memória):

| Node type | typeVersion |
|---|---|
| n8n-nodes-base.postgres | 2.6 |
| n8n-nodes-base.webhook | 2.1 |
| n8n-nodes-base.respondToWebhook | 1.5 |
| n8n-nodes-base.telegram | 1.2 |
| n8n-nodes-base.telegramTrigger | 1.3 |
| n8n-nodes-base.scheduleTrigger | 1.3 |
| n8n-nodes-base.formTrigger | 2.6 |
| n8n-nodes-base.form | 2.5 |
| n8n-nodes-base.errorTrigger | 1 |
| n8n-nodes-base.switch | 3.4 |
| n8n-nodes-base.if | 2.3 |
| n8n-nodes-base.set | 3.4 |

## Validação por workflow (`validate_workflow`, código SDK)

| Workflow | Resultado | Nós | Observações |
|---|---|---|---|
| WF-01 - Intake | `valid:true` | 8 | — |
| WF-02 - Scheduler D+1 | `valid:true` | 2 | — |
| WF-NOTIFY - Telegram Outbox | `valid:true` | 9 | Um aviso inicial (`INVALID_EXPRESSION_PATH` em `profile_url`) foi corrigido adicionando o campo à amostra de saída do nó `Build Delivery Message`; revalidado sem avisos. |
| WF-03 - Approval Callback | `valid:true` | 12 | — |
| WF-03-EDIT - Edit Message | `valid:true` | 4 | — |
| WF-03-REGEN - Regenerate Message | `valid:true` | 7 | — |
| WF-04 - Delivery Callback | `valid:true` | 9 | — |
| WF-05 - Follow-up | `valid:true` | 13 | — |
| WF-90 - Error Handler | `valid:true` | 3 | — |

Todos os 9 workflows passaram em `validate_workflow` sem erros. Nenhum node, `typeVersion`, operação ou parâmetro foi assumido — todos vieram de `search_nodes`/`get_node_types` reais.

## Checklist de validação aplicado a cada workflow

- [x] JSON válido.
- [x] Importável (8 dos 9 foram efetivamente importados ao vivo via `create_workflow_from_code`; WF-01 gerou JSON válido mas a importação ao vivo está bloqueada — ver abaixo).
- [x] Nós existem na instância real (confirmados via `search_nodes`/`get_node_types`).
- [x] `typeVersion` correto (tabela acima).
- [x] Parâmetros obrigatórios preenchidos.
- [x] Conexões válidas, sem nós órfãos.
- [x] Nenhuma interpolação direta de SQL — todas as chamadas usam `$1,$2,...` via `options.queryReplacement`.
- [x] Nenhuma função interna (`transition_connection_status`, `issue_action_token`, `create_notification_job`) chamada por nó nenhum.
- [x] Nenhuma escrita direta em tabela — a única exceção é 1 `SELECT` de leitura em `message_versions` no WF-03 (`Get Current Message Version`), justificada e documentada no `WORKFLOW-MANIFEST.md`.
- [x] Nenhum segredo em nenhum JSON.
- [x] Nenhum ID fictício — o único ID de credencial usado é o real (`DgnSAHo0I8CRFwci`), confirmado por `list_credentials`.
- [x] Nenhuma execução externa real ocorreu (nenhuma mensagem Telegram enviada, nenhuma chamada ao LinkedIn ou ao GPT).
- [x] Todos os workflows permanecem inativos (`active:false` confirmado via `get_workflow_details` nos 8 importados; o JSON do WF-01 também tem `active:false`, e o placeholder existente na instância nunca foi ativado).

## Importação ao vivo (`create_workflow_from_code` + `get_workflow_details`)

8 de 9 workflows foram criados como rascunhos inativos na instância real e re-exportados via `get_workflow_details` para produzir o JSON final entregue (dados reais da instância, IDs reais). 1 chamada (`WF-04`) recebeu um erro transitório `502 Bad Gateway` do proxy da Anthropic (não relacionado ao n8n) e foi repetida com sucesso na tentativa seguinte.

O n8n vinculou automaticamente a única credencial Postgres existente (`Rufino LinkedIn DEV`) a todo nó Postgres dos 8 workflows criados — confirmado tanto pelo campo `autoAssignedCredentials` da resposta de criação quanto por inspeção nó a nó via `get_workflow_details`.

## Bloqueio confirmado: WF-01 (NO-GO parcial)

`get_workflow_details` no workflow existente `WF-01 - Intake - Rufino LinkedIn DEV` (id `7qclFIAJGlRPODH8`) retornou, em duas tentativas (uma antes e uma depois de gerar os outros 8 workflows):

```
Workflow is not available in MCP. Enable MCP access from the workflow card in the workflows list, or from the workflow settings.
```

Isso bloqueia tanto a leitura quanto a atualização ao vivo desse workflow específico via MCP. Para não violar a instrução de nunca duplicar o WF-01, a decisão tomada foi: gerar e validar o JSON do WF-01 normalmente (passou em `validate_workflow`), mas **não** criá-lo como um novo workflow paralelo nem tentar sobrescrever o placeholder sem acesso MCP. O JSON está entregue em `WF-01-intake.json` para importação manual pelo usuário (colar no editor do workflow existente, ou habilitar "Enable MCP access" no card do workflow e repedir a criação/atualização assistida).

**Isto é o único item classificado como NO-GO nesta entrega** — todos os outros 8 workflows estão GO (gerados, validados e importados ao vivo como rascunhos inativos).
