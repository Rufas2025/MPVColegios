# Backups de 20/11/2026 (antes da correção do WF-05)

Instância: `rufino-linkedin-dev-n8n.snfrzv.easypanel.host`

| Workflow | ID | Versão salva | Estado | Arquivo |
|---|---|---|---|---|
| WF-05 - Follow-up | `W36Y8pew9wwaCb6d` | `475aafa8-8a06-4d56-8052-f5f557de2b6a` | inativo | `WF-05-followup-W36Y8pew9wwaCb6d-v475aafa8.json` |
| WF-ROUTER - Telegram Callback Router | `Gjc9slZAO5lcS5RM` | `87f4d477-0d9d-462c-9bd1-135d1569a2b5` (publicada) | ativo | não alterado nesta correção; restaurar pelo histórico de versões do n8n se preciso |

Banco DEV: `rufino_linkedin.claim_due_followups` com md5 de `pg_get_functiondef` = `e151e6fa7a5b30907d478b54d33608eb`
(corpo original de `006_functions.sql`). O rollback `db/migrations/dev/rollback/007_followup_claim_ttl_rollback.sql`
restaura exatamente esse md5 (testado em banco local).
