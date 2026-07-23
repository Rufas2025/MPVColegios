-- =============================================================================
-- 005_rls_and_grants.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV)
--
-- Isolamento primário desta arquitetura: (1) schema rufino_linkedin privado,
-- sem USAGE para PUBLIC; (2) grants mínimos — a role de aplicação só recebe
-- EXECUTE (nas funções, ver 007) e SELECT (nas tabelas, aqui) — nunca
-- INSERT/UPDATE/DELETE direto. RLS é uma terceira camada de defesa (útil
-- contra erro de configuração futuro), não o mecanismo primário.
--
-- Não existe aqui nenhum conceito de "service_role"/Data API/Supavisor —
-- este é PostgreSQL self-hosted no EasyPanel. O equivalente de risco a
-- vigiar é o mesmo de qualquer Postgres: nunca usar a role "postgres"
-- (superuser do serviço linkedin-db) como credencial do n8n — isso é regra
-- operacional (ver MANUAL-STEPS.md), não algo que esta migration resolve.
-- =============================================================================

-- Revoga tudo de PUBLIC no schema e nas tabelas — ponto de partida explícito,
-- nunca herdar o default do Postgres de conceder USAGE a PUBLIC no schema.
REVOKE ALL ON SCHEMA rufino_linkedin FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA rufino_linkedin FROM PUBLIC;

-- USAGE no schema apenas para as duas roles dedicadas desta jornada.
GRANT USAGE ON SCHEMA rufino_linkedin TO n8n_rufino_linkedin_owner_dev;
GRANT USAGE ON SCHEMA rufino_linkedin TO n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- RLS habilitado + forçado nas 8 tabelas (defesa adicional, não primária).
-- FORCE ROW LEVEL SECURITY garante que a política vale mesmo para o dono da
-- tabela quando ele conectar diretamente (a role owner é NOLOGIN, então isso
-- é relevante principalmente como registro explícito de intenção).
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.connections               ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.analyses                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.message_versions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.approvals                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.delivery_events            ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.followups                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.workflow_errors            ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.connection_status_history  ENABLE ROW LEVEL SECURITY;

ALTER TABLE rufino_linkedin.connections               FORCE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.analyses                   FORCE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.message_versions           FORCE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.approvals                  FORCE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.delivery_events            FORCE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.followups                  FORCE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.workflow_errors            FORCE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.connection_status_history  FORCE ROW LEVEL SECURITY;

-- Policies USING (true) restritas por role — não é segmentação multi-tenant
-- (não há multi-tenant dentro deste ambiente); existe para o caso de o
-- schema um dia ganhar mais de uma role de leitura.
CREATE POLICY connections_select_app ON rufino_linkedin.connections
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY analyses_select_app ON rufino_linkedin.analyses
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY message_versions_select_app ON rufino_linkedin.message_versions
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY approvals_select_app ON rufino_linkedin.approvals
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY delivery_events_select_app ON rufino_linkedin.delivery_events
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY followups_select_app ON rufino_linkedin.followups
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY workflow_errors_select_app ON rufino_linkedin.workflow_errors
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY connection_status_history_select_app ON rufino_linkedin.connection_status_history
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);

-- -----------------------------------------------------------------------------
-- Grants da role de aplicação: apenas SELECT. Nenhum INSERT/UPDATE/DELETE
-- direto em nenhuma tabela — toda escrita operacional passa pelas 9 funções
-- (ver 007_function_permissions.sql). Sem DELETE em nenhuma tabela, por
-- nenhuma role, no caminho operacional normal.
-- -----------------------------------------------------------------------------
GRANT SELECT ON
    rufino_linkedin.connections,
    rufino_linkedin.analyses,
    rufino_linkedin.message_versions,
    rufino_linkedin.approvals,
    rufino_linkedin.delivery_events,
    rufino_linkedin.followups,
    rufino_linkedin.workflow_errors,
    rufino_linkedin.connection_status_history
TO n8n_rufino_linkedin_dev;
