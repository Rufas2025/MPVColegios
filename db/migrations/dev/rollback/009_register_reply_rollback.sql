-- =============================================================================
-- rollback/009_register_reply_rollback.sql
-- Desfaz 017_register_reply.sql: remove a função register_reply.
-- Respostas já registradas por ela continuam no histórico (followups e connection_status_history);
-- nada é apagado. Tirar o ramo /respondeu do WF-ROUTER antes de rodar este rollback.
-- =============================================================================

BEGIN;

-- Credencial DDL do n8n nao tem privilegio proprio: assume a owner so nesta transacao.
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;

DROP FUNCTION IF EXISTS rufino_linkedin.register_reply(text, text, text, text);

COMMIT;
