-- =============================================================================
-- 005_rls_and_grants.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.4.2
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 005_rls_and_grants.sql
--
-- Isolamento primário desta arquitetura: (1) schema rufino_linkedin privado,
-- sem USAGE para PUBLIC; (2) grants mínimos — a role de aplicação só recebe
-- EXECUTE (nas 10 funções voltadas ao n8n, ver 006_functions.sql) e SELECT
-- (nas tabelas, aqui) — nunca INSERT/UPDATE/DELETE/TRUNCATE direto. RLS é
-- uma terceira camada de defesa (útil contra erro de configuração futuro),
-- não o mecanismo primário.
--
-- Não existe aqui nenhum conceito de "service_role"/Data API/Supavisor —
-- este é PostgreSQL self-hosted no EasyPanel. O equivalente de risco a
-- vigiar é o mesmo de qualquer Postgres: nunca usar a role "postgres"
-- (superuser do serviço linkedin-db) como credencial do n8n — isso é regra
-- operacional (ver MANUAL-STEPS.md), não algo que esta migration resolve.
--
-- CORREÇÃO v1.4.1 (item 1 do patch corretivo): a v1.4.0 habilitava **e
-- forçava** RLS (`FORCE ROW LEVEL SECURITY`) nas 8 tabelas. Isso era um bug
-- funcional, não só um exagero de cautela: `FORCE ROW LEVEL SECURITY` faz a
-- política valer até para o dono da tabela — e o dono é
-- `n8n_rufino_linkedin_owner_dev`, a mesma role que executa o corpo de
-- TODAS as 9 funções `SECURITY DEFINER` (INSERT/UPDATE feitos por
-- `register_connection`, `transition_connection_status` etc. rodam como
-- essa role). Como só existem policies de `SELECT` para a role de
-- aplicação — nenhuma policy cobre `INSERT`/`UPDATE` para a owner — forçar
-- RLS faria essas escritas serem negadas pela própria política, quebrando
-- todas as 9 funções assim que qualquer instância real tentasse gravar.
-- `ENABLE ROW LEVEL SECURITY` (sem `FORCE`) já dá a defesa adicional
-- pretendida — RLS continua avaliado para qualquer role que não seja a
-- dona da tabela — sem quebrar as funções. A owner ignorar RLS aqui não é
-- uma lacuna de segurança: ela é `NOLOGIN` (ninguém conecta como ela
-- diretamente) e só grava através do corpo das 9 funções, cujas próprias
-- regras de negócio (validação de transição, tokens, dedupe) são a
-- proteção real dessas escritas — RLS nunca foi pensada para restringir
-- *o que a função em si decide gravar*, só para restringir sessões
-- externas que tentassem ler/escrever a tabela fora de uma função.
-- =============================================================================

BEGIN;

-- Revoga tudo de PUBLIC no schema e nas tabelas — ponto de partida explícito,
-- nunca herdar o default do Postgres de conceder USAGE a PUBLIC no schema.
REVOKE ALL ON SCHEMA rufino_linkedin FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA rufino_linkedin FROM PUBLIC;

-- USAGE no schema apenas para as duas roles dedicadas desta jornada.
GRANT USAGE ON SCHEMA rufino_linkedin TO n8n_rufino_linkedin_owner_dev;
GRANT USAGE ON SCHEMA rufino_linkedin TO n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- RLS habilitado (não forçado) nas 8 tabelas — defesa adicional, não
-- primária. Sem FORCE: a role owner (dona das tabelas, NOLOGIN, só grava
-- através das 9 funções SECURITY DEFINER) continua isenta de RLS por
-- desenho — ver explicação no cabeçalho deste arquivo. RLS continua valendo
-- para qualquer outra role, incluindo a de aplicação.
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.connections               ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.analyses                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.message_versions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.approvals                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.delivery_events            ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.followups                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.workflow_errors            ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.connection_status_history  ENABLE ROW LEVEL SECURITY;

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
-- Grants da role de aplicação: apenas SELECT. Nenhum INSERT/UPDATE/DELETE/
-- TRUNCATE direto em nenhuma tabela — toda escrita operacional passa pelas
-- 10 funções voltadas ao n8n (ver 006_functions.sql). Sem DELETE em nenhuma
-- tabela, por nenhuma role, no caminho operacional normal.
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

COMMIT;
