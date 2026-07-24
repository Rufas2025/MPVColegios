# CREDENTIAL-BINDING.md — GATE 4

## Inventário real de credenciais na instância (confirmado via `list_credentials`)

| Nome | Tipo | ID | Status |
|---|---|---|---|
| Rufino LinkedIn DEV | postgres | `DgnSAHo0I8CRFwci` | Existe — vinculada automaticamente pelo n8n em todos os nós Postgres dos 8 workflows criados ao vivo. |
| — | telegramApi | — | **Não existe.** Nenhuma credencial Telegram foi criada nesta instância. |
| — | httpHeaderAuth | — | **Não existe.** Nenhuma credencial Header Auth foi criada nesta instância. |

Nenhuma credencial foi criada, editada ou removida por esta entrega. Nenhum ID de credencial foi inventado — o único ID usado (`DgnSAHo0I8CRFwci`) é o real, confirmado por `list_credentials` e pelo campo `autoAssignedCredentials` retornado por `create_workflow_from_code` em cada um dos 8 workflows.

## O que foi vinculado automaticamente

Como só existe uma credencial Postgres na instância, o n8n vinculou-a automaticamente a **todo** nó Postgres dos 8 workflows criados ao vivo (WF-02, WF-NOTIFY, WF-03, WF-03-EDIT, WF-03-REGEN, WF-04, WF-05, WF-90). Isso foi confirmado nó a nó via `get_workflow_details` após a criação. Não foi necessária nenhuma chamada manual de `update_workflow`/`setNodeCredential`.

Os JSONs entregues em `gate4/workflows/dev/*.json` já refletem essa vinculação real (`"credentials": {"postgres": {"id": "DgnSAHo0I8CRFwci", "name": "Rufino LinkedIn DEV"}}` em cada nó Postgres, incluindo o WF-01, que recebeu o mesmo ID real por ser a mesma credencial já testada em GATE 3 — ainda que a importação ao vivo do WF-01 esteja pendente, ver `WORKFLOW-MANIFEST.md`).

## Pendências manuais (ação humana necessária, fora do escopo desta entrega)

1. **Credencial Telegram Bot ("Telegram Bot - Rufino LinkedIn DEV")** — precisa ser criada manualmente no n8n (Credentials → New → Telegram API, com o token do bot do Anderson). Depois de criada, os seguintes nós ficam sem vínculo e precisam ser apontados manualmente para ela:
   - WF-NOTIFY: `Send Approval Telegram Message`, `Send Delivery Telegram Message`.
   - WF-03: `Approval Callback Trigger`, `Answer Callback Query`, `Remove Original Inline Buttons`, `Send Edit Form Link`, `Send Regenerate Context To GPT`.
   - WF-04: `Delivery Callback Trigger`, `Answer Callback Query`, `Remove Original Inline Buttons`.
   - WF-05: `Followup Callback Trigger`, `Answer Followup Callback Query`, `Send Followup Reminder`, `Remove Followup Inline Buttons`.
2. **Credencial Header Auth ("Header Auth - Rufino LinkedIn DEV")** — precisa ser criada manualmente (Credentials → New → Header Auth, com o header/segredo que o GPT vai enviar). Nós pendentes:
   - WF-01: `Intake Webhook` (import manual, ver `WORKFLOW-MANIFEST.md`).
   - WF-03-REGEN: `Regenerate Webhook`.
3. **Placeholders de texto pendentes de preenchimento** (chat IDs e URL base de formulário), presentes como `<__PLACEHOLDER_VALUE__...>` nos JSONs e visíveis no editor do n8n como campos vazios a preencher manualmente:
   - `Chat ID do Telegram de Anderson` — em `Build Approval Message` (WF-NOTIFY), `Build Delivery Message` (WF-NOTIFY), `Build Followup Reminder` (WF-05).
   - `Chat ID restrito de Anderson (Restrict to Chat IDs / User IDs)` — nos 3 Telegram Trigger (WF-03, WF-04, WF-05, ramo B).
   - `URL base do n8n Form de edicao (WF-03-EDIT)` — em `Build Edit Form Link` (WF-03).
4. **WF-90 como Error Workflow dos demais** — nenhum dos outros 8 workflows foi configurado para apontar `settings.errorWorkflow` para o WF-90. Essa é uma decisão de configuração explícita que fica para o usuário confirmar (pode preferir Error Trigger local por workflow, que já existe centralizado no WF-90, ou apontar cada workflow para ele via `setWorkflowSettings`).

Nenhuma dessas pendências foi resolvida com valores inventados — todas ficam explicitamente marcadas para preenchimento humano, conforme a regra "nunca sintetizar ID de credencial ou segredo".
