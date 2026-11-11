-- =============================================================================
-- rollback/005_anticipate_schedule_exceptional_rollback.sql
-- Rufino LinkedIn Intelligence — rollback de 013_anticipate_schedule_exceptional.sql
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f rollback/005_anticipate_schedule_exceptional_rollback.sql
--
-- Desfaz SOMENTE a função anticipate_connection_schedule. Nunca reverte o
-- scheduled_at de nenhuma conexão já antecipada por ela — o novo horário
-- gravado permanece (é um dado operacional real, não uma alteração de
-- schema); só a ferramenta de exceção some. Nenhum outro objeto é tocado.
-- =============================================================================

DROP FUNCTION IF EXISTS rufino_linkedin.anticipate_connection_schedule(
    uuid, timestamptz, text, text, text, text
);
