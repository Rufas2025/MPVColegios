-- =============================================================================
-- rollback/001_rollback.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — patch v1.4.1
--
-- Rollback irmão de 001–007 (007 é um stub documental desde a v1.4.1 — seu
-- conteúdo de permissões vive dentro de 006, ver 007_function_permissions.sql).
-- Ordem segura, inversa à ordem de criação:
--   1. Funções (as 9)               — sem risco de dado.
--   2. Grants (EXECUTE/SELECT/USAGE) e policies de RLS.
--   3. Tabelas dependentes de connections (nesta ordem entre si é livre,
--      mas todas antes de connections).
--   4. Tabela connections.
--   5. Roles dedicadas — SOMENTE SE não houver sessão ativa nem objeto
--      dependente restante; DROP ROLE falha (corretamente) se houver.
--
-- ATENÇÃO — OPERAÇÃO DESTRUTIVA. Este script apaga permanentemente todas as
-- 8 tabelas operacionais e todo o histórico/auditoria nelas contido
-- (approvals, delivery_events, connection_status_history, workflow_errors
-- inclusive). NÃO EXECUTAR contra um banco com dados que importam sem
-- confirmação explícita e um backup verificado antes. Nenhuma linha deste
-- arquivo foi executada nesta entrega.
--
-- NUNCA remove a extensão pgcrypto — ela pode ser compartilhada por outros
-- usos do banco fora desta jornada; remover é decisão manual, separada,
-- fora do escopo deste rollback.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Funções — DROP FUNCTION, sem risco de dado.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.transition_connection_status(
    uuid, text, text, text, text, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.present_message_for_delivery(
    uuid, uuid, text, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.claim_due_connections(
    integer, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.approve_message(
    uuid, uuid, text, text, text, text, text, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.save_message_edit(
    text, text, text, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.mark_message_sent(
    uuid, uuid, text, text, text, text, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.claim_due_followups(
    integer
);
DROP FUNCTION IF EXISTS rufino_linkedin.record_workflow_error(
    uuid, text, text, text, jsonb, text, text, integer, text
);

-- -----------------------------------------------------------------------------
-- 2) Grants e policies de RLS.
--    (REVOKE de função já não é necessário depois do DROP FUNCTION acima —
--    o privilégio desaparece junto com o objeto. Mantido aqui só o REVOKE
--    de tabela/schema e o DROP das policies.)
-- -----------------------------------------------------------------------------
REVOKE SELECT ON
    rufino_linkedin.connections,
    rufino_linkedin.analyses,
    rufino_linkedin.message_versions,
    rufino_linkedin.approvals,
    rufino_linkedin.delivery_events,
    rufino_linkedin.followups,
    rufino_linkedin.workflow_errors,
    rufino_linkedin.connection_status_history
FROM n8n_rufino_linkedin_dev;

DROP POLICY IF EXISTS connections_select_app ON rufino_linkedin.connections;
DROP POLICY IF EXISTS analyses_select_app ON rufino_linkedin.analyses;
DROP POLICY IF EXISTS message_versions_select_app ON rufino_linkedin.message_versions;
DROP POLICY IF EXISTS approvals_select_app ON rufino_linkedin.approvals;
DROP POLICY IF EXISTS delivery_events_select_app ON rufino_linkedin.delivery_events;
DROP POLICY IF EXISTS followups_select_app ON rufino_linkedin.followups;
DROP POLICY IF EXISTS workflow_errors_select_app ON rufino_linkedin.workflow_errors;
DROP POLICY IF EXISTS connection_status_history_select_app ON rufino_linkedin.connection_status_history;

REVOKE USAGE ON SCHEMA rufino_linkedin FROM n8n_rufino_linkedin_dev;
REVOKE USAGE ON SCHEMA rufino_linkedin FROM n8n_rufino_linkedin_owner_dev;

-- Acesso a pgcrypto concedido em 002_roles_and_schema.sql (fix v1.4.1, item
-- 2) — revogado aqui na mesma role. Nunca revoga de PUBLIC nem de nenhuma
-- outra role: o schema extensions e a extensão pgcrypto em si podem ser
-- usados por outras coisas no banco, fora desta jornada.
REVOKE EXECUTE ON FUNCTION extensions.gen_random_bytes(integer) FROM n8n_rufino_linkedin_owner_dev;
REVOKE EXECUTE ON FUNCTION extensions.digest(text, text) FROM n8n_rufino_linkedin_owner_dev;
REVOKE USAGE ON SCHEMA extensions FROM n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 3) Tabelas dependentes de connections — CASCADE cobre FKs; ordem entre si
--    é livre, mas todas antes de connections.
--    ALERTA: apaga permanentemente todo o histórico e auditoria.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS rufino_linkedin.connection_status_history;
DROP TABLE IF EXISTS rufino_linkedin.workflow_errors;
DROP TABLE IF EXISTS rufino_linkedin.followups;
DROP TABLE IF EXISTS rufino_linkedin.delivery_events;
DROP TABLE IF EXISTS rufino_linkedin.approvals;
DROP TABLE IF EXISTS rufino_linkedin.message_versions;
DROP TABLE IF EXISTS rufino_linkedin.analyses;

-- -----------------------------------------------------------------------------
-- 4) Tabela connections — por último entre as tabelas (as demais referenciam
--    ela via FK; sem CASCADE necessário se a ordem acima foi respeitada).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS rufino_linkedin.connections;

-- -----------------------------------------------------------------------------
-- 5) Schema privado — só depois que todas as tabelas/funções já saíram.
-- -----------------------------------------------------------------------------
DROP SCHEMA IF EXISTS rufino_linkedin;

-- -----------------------------------------------------------------------------
-- 6) Roles dedicadas — SOMENTE SE não houver sessão ativa nem objeto
--    dependente restante em qualquer schema do banco. DROP ROLE falha
--    (corretamente) se houver — isso não é um bug deste script, é a
--    proteção esperada. Não force com CASCADE em nenhum objeto de role.
-- -----------------------------------------------------------------------------
DROP ROLE IF EXISTS n8n_rufino_linkedin_dev;
DROP ROLE IF EXISTS n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- NUNCA incluído neste rollback, de propósito:
--   DROP EXTENSION pgcrypto;
-- A extensão pode ser compartilhada por outros usos do banco
-- rufino-linkedin-dev fora desta jornada — removê-la é decisão manual,
-- separada, fora do escopo desta skill e deste script.
-- -----------------------------------------------------------------------------
