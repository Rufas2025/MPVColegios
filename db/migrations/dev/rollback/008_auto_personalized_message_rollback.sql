-- =============================================================================
-- rollback/008_auto_personalized_message_rollback.sql
-- Desfaz 016_auto_personalized_message.sql: remove a função save_auto_message.
-- Versões já gravadas por ela (version 2, source 'gpt', edited_by 'auto-pesquisa:...') continuam no histórico;
-- nada é apagado. Desligar o WF-06 antes de rodar este rollback.
-- =============================================================================

BEGIN;

-- Credencial DDL do n8n nao tem privilegio proprio: assume a owner so nesta transacao.
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;

DROP FUNCTION IF EXISTS rufino_linkedin.save_auto_message(uuid, text, text, text, text);

COMMIT;
