-- =============================================================================
-- 008_validation_queries.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV)
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

-- 4) EXECUTE das 9 funções: apenas n8n_rufino_linkedin_dev (nunca PUBLIC).
SELECT p.proname,
       has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'EXECUTE') AS app_pode_executar,
       has_function_privilege('public', p.oid, 'EXECUTE')                  AS public_pode_executar
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado: app_pode_executar = true, public_pode_executar = false, em todas.

-- 5) Grants de tabela da role de aplicação: só SELECT, nunca INSERT/UPDATE/DELETE.
SELECT table_name, privilege_type
  FROM information_schema.role_table_grants
 WHERE grantee = 'n8n_rufino_linkedin_dev'
   AND table_schema = 'rufino_linkedin'
 ORDER BY table_name, privilege_type;
-- Esperado: só a linha "SELECT" por tabela (8 linhas), nenhum
-- INSERT/UPDATE/DELETE.

-- 6) RLS habilitado e forçado nas 8 tabelas.
SELECT c.relname, c.relrowsecurity AS rls_habilitado, c.relforcerowsecurity AS rls_forcado
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'rufino_linkedin'
   AND c.relkind = 'r'
 ORDER BY c.relname;
-- Esperado: rls_habilitado = true e rls_forcado = true em todas as 8.

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
