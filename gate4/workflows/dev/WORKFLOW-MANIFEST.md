# WORKFLOW-MANIFEST.md — GATE 4 - Rufino LinkedIn Intelligence (DEV)

Instância: `rufino-linkedin-dev-n8n.snfrzv.easypanel.host` (n8n 2.29.7, EasyPanel).
Todos os workflows abaixo foram criados/gerados **inativos** e nenhum foi ativado.

---

## WF-01 - Intake

- **Propósito:** recebe o payload já validado do GPT via webhook e registra uma nova conexão de forma idempotente.
- **Trigger:** Webhook `POST /wf01-intake-rufino-linkedin-dev` (autenticação Header Auth).
- **Funções PostgreSQL usadas:** `register_connection`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" (pendente de bind manual — ver abaixo); Header Auth "Header Auth - Rufino LinkedIn DEV" (**não existe ainda** — pendente).
- **Dependências:** nenhuma a montante; alimenta o WF-02 (conexões `AGUARDANDO_D1`).
- **Validação (`validate_workflow`):** `valid:true`, `nodeCount:8`.
- **ID na instância real:** **N/A — NO-GO para importação ao vivo.** Já existe um workflow placeholder `WF-01 - Intake - Rufino LinkedIn DEV` (id `7qclFIAJGlRPODH8`) na instância, mas o MCP não tem acesso habilitado nele (`"Workflow is not available in MCP. Enable MCP access from the workflow card in the workflows list, or from the workflow settings."`). Para não duplicar o workflow nem contornar a trava, o JSON foi gerado e validado, mas a importação precisa ser feita manualmente pelo usuário (colar o JSON no editor do workflow existente, ou habilitar o acesso MCP e repetir o passo de import).
- **Inativo:** sim (o workflow existente na instância já está inativo e não foi tocado; o JSON entregue também tem `active:false`).

## WF-02 - Scheduler D+1

- **Propósito:** reivindica diariamente as conexões que atingiram D+1 e alimenta o outbox de notificação.
- **Trigger:** Schedule Trigger diário às 09:00.
- **Funções PostgreSQL usadas:** `claim_due_connections`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" (`DgnSAHo0I8CRFwci`) — vinculada automaticamente na criação.
- **Dependências:** consome conexões criadas pelo WF-01; alimenta `notification_jobs` para o WF-NOTIFY.
- **Validação:** `valid:true`, `nodeCount:2`.
- **ID na instância real:** `CxLUUmLpj3mA0nfz`.
- **Inativo:** confirmado (`active:false` via `get_workflow_details`).

## WF-NOTIFY - Telegram Outbox

- **Propósito:** drena `notification_jobs` (tipos `APPROVAL`/`DELIVERY`) a cada 1 minuto e envia as mensagens Telegram correspondentes.
- **Trigger:** Schedule Trigger a cada 1 minuto.
- **Funções PostgreSQL usadas:** `claim_notification_jobs`, `confirm_notification_delivery`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" (auto-bind em 3 nós); Telegram Bot "Telegram Bot - Rufino LinkedIn DEV" (**não existe ainda** — pendente, 2 nós de envio ficaram sem credencial vinculada).
- **Dependências:** consome o outbox alimentado por WF-02/WF-03/WF-04/WF-05.
- **Validação:** `valid:true`, `nodeCount:9`.
- **ID na instância real:** `xmshrOsfUkWSBfnG`.
- **Inativo:** confirmado.

## WF-03 - Approval Callback

- **Propósito:** recebe o callback de aprovação do Telegram (`a:A/E/R/D`), responde a callback query imediatamente, chama `approve_message` e roteia por decisão.
- **Trigger:** Telegram Trigger (`callback_query`).
- **Funções PostgreSQL usadas:** `approve_message`, `present_message_for_delivery`; 1 `SELECT` de leitura direta em `message_versions` (leitura, não escrita — justificado para resolver a versão atual antes de `present_message_for_delivery`).
- **Credenciais:** Postgres "Rufino LinkedIn DEV" (auto-bind em 3 nós); Telegram Bot (pendente, 5 nós Telegram sem credencial).
- **Dependências:** consome `action_token` gerado pelo WF-NOTIFY (job `APPROVAL`).
- **Validação:** `valid:true`, `nodeCount:12`.
- **ID na instância real:** `eomHxG6ODD8pMvMp`.
- **Inativo:** confirmado.

## WF-03-EDIT - Edit Message

- **Propósito:** formulário n8n para editar manualmente o texto proposto antes de reenviar para aprovação.
- **Trigger:** Form Trigger.
- **Funções PostgreSQL usadas:** `save_message_edit`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" — vinculada automaticamente.
- **Dependências:** consome `edit_token` gerado pelo WF-03 (decisão `EDITAR`).
- **Validação:** `valid:true`, `nodeCount:4`.
- **ID na instância real:** `V0neji0AlG5INqKz`.
- **Inativo:** confirmado.

## WF-03-REGEN - Regenerate Message

- **Propósito:** webhook para receber a mensagem regenerada pelo GPT e salvar como nova versão.
- **Trigger:** Webhook `POST /wf03-regen-rufino-linkedin-dev` (Header Auth).
- **Funções PostgreSQL usadas:** `save_regenerated_message`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" — vinculada automaticamente; Header Auth (pendente, não existe).
- **Dependências:** consome `regeneration_token` gerado pelo WF-03 (decisão `REFAZER`).
- **Validação:** `valid:true`, `nodeCount:7`.
- **ID na instância real:** `poBq03kSHdpPJN34`.
- **Inativo:** confirmado.

## WF-04 - Delivery Callback

- **Propósito:** recebe o callback de entrega do Telegram (`a:S/B`), calcula `first_followup_at` e chama `mark_message_sent`.
- **Trigger:** Telegram Trigger (`callback_query`).
- **Funções PostgreSQL usadas:** `mark_message_sent`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" (auto-bind em 2 nós); Telegram Bot (pendente, 3 nós sem credencial).
- **Dependências:** consome `action_token` gerado pelo WF-NOTIFY (job `DELIVERY`).
- **Validação:** `valid:true`, `nodeCount:9`.
- **ID na instância real:** `J1CFdbxNhICh9MEP`.
- **Inativo:** confirmado.

## WF-05 - Follow-up

- **Propósito:** reivindica follow-ups vencidos a cada hora, envia lembrete no Telegram e conclui via callback `f:R`/`f:N`.
- **Trigger:** Schedule Trigger horário (ramo A) + Telegram Trigger `callback_query` (ramo B), no mesmo workflow.
- **Funções PostgreSQL usadas:** `claim_due_followups`, `complete_followup`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" (auto-bind em 3 nós); Telegram Bot (pendente, 3 nós sem credencial).
- **Dependências:** consome follow-ups agendados por `mark_message_sent` (WF-04).
- **Validação:** `valid:true`, `nodeCount:13`.
- **ID na instância real:** `W36Y8pew9wwaCb6d`.
- **Inativo:** confirmado.

## WF-90 - Error Handler

- **Propósito:** Error Trigger central da malha; sanitiza o contexto do erro e registra via `record_workflow_error`.
- **Trigger:** Error Trigger.
- **Funções PostgreSQL usadas:** `record_workflow_error`.
- **Credenciais:** Postgres "Rufino LinkedIn DEV" — vinculada automaticamente.
- **Dependências:** nenhuma direta; para entrar em operação precisa ser referenciado como "Error Workflow" nas configurações dos demais workflows (ação manual pendente, não executada nesta entrega para não alterar workflows fora do escopo do GATE 4).
- **Validação:** `valid:true`, `nodeCount:3`.
- **ID na instância real:** `ASUyxPvFJUmRoWO9`.
- **Inativo:** confirmado.

---

## Resumo de IDs reais criados

| Workflow | ID real | Status de importação |
|---|---|---|
| WF-01 - Intake | `7qclFIAJGlRPODH8` (placeholder existente, não tocado) | NO-GO ao vivo — import manual necessário |
| WF-02 - Scheduler D+1 | `CxLUUmLpj3mA0nfz` | Importado (inativo) |
| WF-NOTIFY - Telegram Outbox | `xmshrOsfUkWSBfnG` | Importado (inativo) |
| WF-03 - Approval Callback | `eomHxG6ODD8pMvMp` | Importado (inativo) |
| WF-03-EDIT - Edit Message | `V0neji0AlG5INqKz` | Importado (inativo) |
| WF-03-REGEN - Regenerate Message | `poBq03kSHdpPJN34` | Importado (inativo) |
| WF-04 - Delivery Callback | `J1CFdbxNhICh9MEP` | Importado (inativo) |
| WF-05 - Follow-up | `W36Y8pew9wwaCb6d` | Importado (inativo) |
| WF-90 - Error Handler | `ASUyxPvFJUmRoWO9` | Importado (inativo) |
