-- =============================================================================
-- 008_validation_queries.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — patch v1.4.1
--
-- SOMENTE LEITURA. Nenhuma instrução aqui cria, altera ou remove qualquer
-- objeto — só SELECT, para conferir depois de aplicar 001–007 que o
-- resultado bate com o desenho. Execução manual, um bloco de cada vez,
-- fora do escopo desta rodada (nenhum SQL foi executado nesta entrega).
-- =============================================================================

-- 1) 8 tabelas esperadas no schema rufino_linkedin.
SELECT table_name
  FROM information_schema.tables
 WHERE table_schema = 'rufino_linkedin'
 ORDER BY table_name;
-- Esperado (8 linhas): analyses, approvals, connection_status_history,
-- connections, delivery_events, followups, message_versions, workflow_errors.

-- 2) 9 funções esperadas no schema rufino_linkedin.
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado (9 linhas): approve_message, claim_due_connections,
-- claim_due_followups, mark_message_sent, present_message_for_delivery,
-- record_workflow_error, register_connection, save_message_edit,
-- transition_connection_status.

-- 3) Todas as funções são SECURITY DEFINER, de propriedade da role owner,
--    com search_path fixado explicitamente.
SELECT p.proname,
       p.prosecdef                                   AS security_definer,
       pg_get_userbyid(p.proowner)                    AS owner,
       p.proconfig                                     AS config_search_path
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado: security_definer = true em todas; owner =
-- n8n_rufino_linkedin_owner_dev em todas; config_search_path contendo
-- "search_path=rufino_linkedin, extensions, pg_temp" em todas.

-- 4) EXECUTE das 9 funções: 8 executáveis por n8n_rufino_linkedin_dev,
--    1 interna (transition_connection_status) só acessível à role owner e
--    às outras 8 funções que a chamam por dentro; PUBLIC nunca em nenhuma
--    das 9 (fix v1.4.1, item 4).
SELECT p.proname,
       has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'EXECUTE') AS app_pode_executar,
       has_function_privilege('public', p.oid, 'EXECUTE')                  AS public_pode_executar
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado: public_pode_executar = false em TODAS as 9. app_pode_executar =
-- true em 8 (register_connection, present_message_for_delivery,
-- claim_due_connections, approve_message, save_message_edit,
-- mark_message_sent, claim_due_followups, record_workflow_error) e = false
-- só em transition_connection_status.

-- 4b) Confirmação direta e nomeada do item acima, para não depender de
--     conferir 9 linhas manualmente: conta quantas são executáveis pela
--     role de aplicação.
SELECT
    count(*) FILTER (WHERE has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'EXECUTE')) AS executaveis_pela_app,
    count(*) AS total_funcoes
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin';
-- Esperado: executaveis_pela_app = 8, total_funcoes = 9.

-- 5) Grants de tabela da role de aplicação: só SELECT, nunca INSERT/UPDATE/DELETE.
SELECT table_name, privilege_type
  FROM information_schema.role_table_grants
 WHERE grantee = 'n8n_rufino_linkedin_dev'
   AND table_schema = 'rufino_linkedin'
 ORDER BY table_name, privilege_type;
-- Esperado: só a linha "SELECT" por tabela (8 linhas), nenhum
-- INSERT/UPDATE/DELETE.

-- 6) RLS habilitado, mas NÃO forçado, nas 8 tabelas (fix v1.4.1, item 1:
--    FORCE ROW LEVEL SECURITY quebrava as próprias funções SECURITY
--    DEFINER, porque a role owner passava a ser sujeita à RLS mesmo sendo
--    dona das tabelas, e não existe policy de INSERT/UPDATE para ela).
SELECT c.relname, c.relrowsecurity AS rls_habilitado, c.relforcerowsecurity AS rls_forcado
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'rufino_linkedin'
   AND c.relkind = 'r'
 ORDER BY c.relname;
-- Esperado: rls_habilitado = true e rls_forcado = FALSE em todas as 8.

-- 7) Roles: owner NOLOGIN; app sem SUPERUSER/BYPASSRLS/CREATEDB/CREATEROLE/REPLICATION.
SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolreplication
  FROM pg_roles
 WHERE rolname IN ('n8n_rufino_linkedin_owner_dev', 'n8n_rufino_linkedin_dev')
 ORDER BY rolname;
-- Esperado: owner com rolcanlogin=false; app com rolcanlogin=true e todas
-- as demais colunas acima em false para as duas roles.

-- 8) Senha da role de aplicação: NULL até a ação manual de Anderson
--    (ver MANUAL-STEPS.md). NÃO expõe o hash em texto puro — só confirma
--    se já foi definida (rolpassword IS NOT NULL) ou não.
SELECT rolname, (rolpassword IS NOT NULL) AS senha_ja_definida
  FROM pg_authid
 WHERE rolname = 'n8n_rufino_linkedin_dev';
-- Antes da ação manual: senha_ja_definida = false. Depois: true.

-- 9) pgcrypto confirmada em extensions, versão 1.3 (mesma checagem do preflight,
--    para conferência pós-migration).
SELECT e.extname, e.extversion, n.nspname AS schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'pgcrypto';
-- Esperado: extname='pgcrypto', extversion='1.3', schema='extensions'.

-- 10) Nenhuma tabela contém coluna de valor bruto de token (auditoria
--     estrutural rápida — confirma pelo nome de coluna, não substitui
--     revisão de dado real).
SELECT table_name, column_name
  FROM information_schema.columns
 WHERE table_schema = 'rufino_linkedin'
   AND (column_name ILIKE '%raw_token%' OR column_name = 'action_token' OR column_name = 'edit_token');
-- Esperado: 0 linhas. Só *_hash deve existir (pending_action_token_hash,
-- active_edit_token_hash).

-- 11) Acesso a pgcrypto (fix v1.4.1, item 2): a role owner tem USAGE no
--     schema extensions e EXECUTE nas duas funções específicas; a role de
--     aplicação NÃO tem USAGE em extensions (ela nunca chama
--     digest()/gen_random_bytes() diretamente — só via SECURITY DEFINER).
SELECT
    has_schema_privilege('n8n_rufino_linkedin_owner_dev', 'extensions', 'USAGE')       AS owner_usage_extensions,
    has_schema_privilege('n8n_rufino_linkedin_dev', 'extensions', 'USAGE')             AS app_usage_extensions,
    has_function_privilege('n8n_rufino_linkedin_owner_dev', 'extensions.digest(text,text)', 'EXECUTE')            AS owner_execute_digest,
    has_function_privilege('n8n_rufino_linkedin_owner_dev', 'extensions.gen_random_bytes(integer)', 'EXECUTE')    AS owner_execute_gen_random_bytes;
-- Esperado: owner_usage_extensions = true, app_usage_extensions = false,
-- owner_execute_digest = true, owner_execute_gen_random_bytes = true.

-- 12) Mensagem inicial (fix v1.4.1, item 3): toda connections tem
--     exatamente uma message_versions de version=1 e source='gpt' — não
--     deve haver conexão sem mensagem inicial nem duplicidade de version 1.
SELECT c.connection_id
  FROM rufino_linkedin.connections c
  LEFT JOIN rufino_linkedin.message_versions mv
    ON mv.connection_id = c.connection_id AND mv.version = 1 AND mv.source = 'gpt'
 WHERE mv.message_version_id IS NULL;
-- Esperado: 0 linhas (nenhuma conexão sem sua message_version 1 de origem
-- 'gpt'). Só relevante depois que existirem dados reais — logo após a
-- migration, com o banco vazio, esta consulta naturalmente retorna 0 linhas.

-- 13) Followups: nenhuma linha com claimed_at preenchido, executed_at nulo
--     e mais velha que o timeout de claim abandonado sem já ter sido
--     reivindicada de novo (auditoria do fix v1.4.1, item 8 — só é
--     informativo, não indica erro por si só, já que pode ser um claim
--     legitimamente em andamento).
SELECT followup_id, connection_id, claimed_at, executed_at, updated_at
  FROM rufino_linkedin.followups
 WHERE claimed_at IS NOT NULL
   AND executed_at IS NULL
   AND claimed_at <= now() - interval '1 hour';
-- Informativo: linhas aqui são candidatas a reivindicação pelo próximo
-- claim_due_followups (não é, por si só, um erro de migration).
