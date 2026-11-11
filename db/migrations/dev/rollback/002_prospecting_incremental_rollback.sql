-- =============================================================================
-- rollback/002_prospecting_incremental_rollback.sql
-- Rufino LinkedIn Intelligence — rollback do ADENDO PRÉ-CONEXÃO apenas
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f rollback/002_prospecting_incremental_rollback.sql
--
-- Este rollback é o irmão de 011_prospecting_incremental.sql — desfaz
-- SOMENTE os 3 objetos novos (schools, prospects, prospect_events) e as 9
-- funções novas do adendo. NUNCA toca nas 11 tabelas, nas 15 funções, nas 2
-- roles ou no schema pré-existentes (base v1.5.1, confirmada real em
-- rufino-linkedin-dev por preflight em 2026-11-11) — isso é diferente de
-- rollback/001_rollback.sql, que é destrutivo de instalação limpa e NUNCA
-- deve rodar contra um banco com dados reais.
--
-- Ordem: funções (sem risco de dado) → grants/policies → tabelas novas
-- (prospect_events e prospects antes, por FK; schools por último).
-- ATENÇÃO: se já existirem linhas reais em prospects/schools/prospect_events
-- (ex.: o caso piloto Leandro), este rollback as apaga permanentemente —
-- confirme que não há dado que importe, ou tire backup antes.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Funções do adendo (9: 7 de negócio + 2 internas).
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS rufino_linkedin.link_prospect_to_connection(uuid, text, text);
DROP FUNCTION IF EXISTS rufino_linkedin.close_prospect(uuid, text, text, text, text);
DROP FUNCTION IF EXISTS rufino_linkedin.confirm_invite_accepted(uuid, timestamptz, text, text, text);
DROP FUNCTION IF EXISTS rufino_linkedin.mark_invite_sent(uuid, text, text, text);
DROP FUNCTION IF EXISTS rufino_linkedin.get_daily_prospect_queue(integer, text, text);
DROP FUNCTION IF EXISTS rufino_linkedin.qualify_prospect(uuid, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS rufino_linkedin.register_prospect(
    text, text, text, text, text, text, text, text, text, text, text
);
DROP FUNCTION IF EXISTS rufino_linkedin.normalize_school_name(text);
DROP FUNCTION IF EXISTS rufino_linkedin.normalize_linkedin_url(text);

-- -----------------------------------------------------------------------------
-- 2) Grants e policies das 3 tabelas do adendo.
-- -----------------------------------------------------------------------------
REVOKE SELECT ON
    rufino_linkedin.schools,
    rufino_linkedin.prospects,
    rufino_linkedin.prospect_events
FROM n8n_rufino_linkedin_dev;

DROP POLICY IF EXISTS schools_select_app ON rufino_linkedin.schools;
DROP POLICY IF EXISTS prospects_select_app ON rufino_linkedin.prospects;
DROP POLICY IF EXISTS prospect_events_select_app ON rufino_linkedin.prospect_events;

-- -----------------------------------------------------------------------------
-- 3) Tabelas do adendo — prospect_events e prospects saem antes (FK),
--    schools por último.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS rufino_linkedin.prospect_events;
DROP TABLE IF EXISTS rufino_linkedin.prospects;
DROP TABLE IF EXISTS rufino_linkedin.schools;

-- -----------------------------------------------------------------------------
-- NUNCA incluído aqui, de propósito: qualquer DROP relativo às 11 tabelas,
-- 15 funções, 2 roles ou ao schema pré-existentes. Esse é o escopo de
-- rollback/001_rollback.sql, que é destrutivo de instalação limpa e não se
-- aplica a este banco.
-- -----------------------------------------------------------------------------
