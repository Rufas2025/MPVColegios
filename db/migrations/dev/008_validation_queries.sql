-- =============================================================================
-- 008_validation_queries.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.1
--
-- SOMENTE LEITURA. Nenhuma instrução aqui cria, altera ou remove qualquer
-- objeto — só SELECT, para conferir depois de aplicar 001–007 que o
-- resultado bate com o desenho. Execução manual, um bloco de cada vez.
-- =============================================================================

-- 1) 11 tabelas esperadas no schema rufino_linkedin.
SELECT table_name
  FROM information_schema.tables
 WHERE table_schema = 'rufino_linkedin'
 ORDER BY table_name;
-- Esperado (11 linhas): action_tokens, analyses, approvals, callback_receipts,
-- connection_status_history, connections, delivery_events, followups,
-- message_versions, notification_jobs, workflow_errors.

-- 2) 15 funções esperadas no schema rufino_linkedin.
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado (15 linhas): approve_message, claim_due_connections,
-- claim_due_followups, claim_notification_jobs, complete_followup,
-- confirm_notification_delivery, create_notification_job, issue_action_token,
-- mark_message_sent, present_message_for_delivery, record_workflow_error,
-- register_connection, save_message_edit, save_regenerated_message,
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
-- Esperado: security_definer = true em todas as 15; owner =
-- n8n_rufino_linkedin_owner_dev em todas; config_search_path contendo
-- "search_path=rufino_linkedin, extensions, pg_temp" em todas.

-- 4) EXECUTE das 15 funções: 12 executáveis por n8n_rufino_linkedin_dev,
--    3 internas (transition_connection_status, issue_action_token,
--    create_notification_job) só acessíveis à role owner e às outras 12
--    que as chamam por dentro; PUBLIC nunca em nenhuma das 15.
SELECT p.proname,
       has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'EXECUTE') AS app_pode_executar,
       has_function_privilege('public', p.oid, 'EXECUTE')                  AS public_pode_executar
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado: public_pode_executar = false em TODAS as 15. app_pode_executar =
-- false SOMENTE em transition_connection_status, issue_action_token e
-- create_notification_job; true nas outras 12.

-- 4b) Confirmação direta e nomeada do item acima.
SELECT
    count(*) FILTER (WHERE has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'EXECUTE')) AS executaveis_pela_app,
    count(*) AS total_funcoes
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin';
-- Esperado: executaveis_pela_app = 12, total_funcoes = 15.

-- 5) Grants de tabela da role de aplicação: só SELECT, nunca INSERT/UPDATE/DELETE.
SELECT table_name, privilege_type
  FROM information_schema.role_table_grants
 WHERE grantee = 'n8n_rufino_linkedin_dev'
   AND table_schema = 'rufino_linkedin'
 ORDER BY table_name, privilege_type;
-- Esperado: só a linha "SELECT" por tabela (11 linhas), nenhum
-- INSERT/UPDATE/DELETE/TRUNCATE.

-- 6) RLS habilitado, mas NÃO forçado, nas 11 tabelas.
SELECT c.relname, c.relrowsecurity AS rls_habilitado, c.relforcerowsecurity AS rls_forcado
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'rufino_linkedin'
   AND c.relkind = 'r'
 ORDER BY c.relname;
-- Esperado: rls_habilitado = true e rls_forcado = FALSE em todas as 11.

-- 7) Roles: owner NOLOGIN; app sem SUPERUSER/BYPASSRLS/CREATEDB/CREATEROLE/REPLICATION.
SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolreplication
  FROM pg_roles
 WHERE rolname IN ('n8n_rufino_linkedin_owner_dev', 'n8n_rufino_linkedin_dev')
 ORDER BY rolname;
-- Esperado: owner com rolcanlogin=false; app com rolcanlogin=true e todas
-- as demais colunas acima em false para as duas roles.

-- 8) Senha da role de aplicação: NULL até a ação manual de Anderson.
SELECT rolname, (rolpassword IS NOT NULL) AS senha_ja_definida
  FROM pg_authid
 WHERE rolname = 'n8n_rufino_linkedin_dev';
-- Antes da ação manual: senha_ja_definida = false. Depois: true.

-- 9) pgcrypto confirmada em extensions, versão 1.3.
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
   AND (
        column_name ILIKE '%raw_token%'
     OR column_name = 'action_token'
     OR column_name = 'edit_token'
     OR column_name = 'claim_token'
     OR column_name ILIKE '%regeneration_token'
        AND column_name NOT LIKE '%_hash' AND column_name NOT LIKE '%_expires_at'
   );
-- Esperado: 0 linhas. Só *_hash deve existir (token_hash, claim_token_hash,
-- action_token_hash, pending_regeneration_token_hash, active_edit_token_hash).

-- 11) Acesso a pgcrypto: a role owner tem USAGE no schema extensions e
--     EXECUTE nas duas funções específicas; a role de aplicação NÃO tem
--     USAGE em extensions (Correção 9, v1.5.0 — reafirmado).
SELECT
    has_schema_privilege('n8n_rufino_linkedin_owner_dev', 'extensions', 'USAGE')       AS owner_usage_extensions,
    has_schema_privilege('n8n_rufino_linkedin_dev', 'extensions', 'USAGE')             AS app_usage_extensions,
    has_function_privilege('n8n_rufino_linkedin_owner_dev', 'extensions.digest(text,text)', 'EXECUTE')            AS owner_execute_digest,
    has_function_privilege('n8n_rufino_linkedin_owner_dev', 'extensions.gen_random_bytes(integer)', 'EXECUTE')    AS owner_execute_gen_random_bytes;
-- Esperado: owner_usage_extensions = true, app_usage_extensions = false,
-- owner_execute_digest = true, owner_execute_gen_random_bytes = true.

-- 12) Mensagem inicial: toda connections tem exatamente uma message_versions
--     de version=1 e source='gpt'.
SELECT c.connection_id
  FROM rufino_linkedin.connections c
  LEFT JOIN rufino_linkedin.message_versions mv
    ON mv.connection_id = c.connection_id AND mv.version = 1 AND mv.source = 'gpt'
 WHERE mv.message_version_id IS NULL;
-- Esperado: 0 linhas. Só relevante depois que existirem dados reais — logo
-- após a migration, com o banco vazio, esta consulta naturalmente retorna
-- 0 linhas.

-- 13) Followups com claim expirado ainda não reivindicado de novo (só
--     informativo, não indica erro por si só).
SELECT followup_id, connection_id, claimed_at, claim_expires_at, executed_at
  FROM rufino_linkedin.followups
 WHERE executed_at IS NULL
   AND claim_expires_at IS NOT NULL
   AND claim_expires_at <= now();
-- Informativo: linhas aqui são candidatas a reivindicação pelo próximo
-- claim_due_followups.

-- 14) Colunas novas/alteradas da v1.5.0 existem com o tipo esperado.
SELECT table_name, column_name, data_type
  FROM information_schema.columns
 WHERE table_schema = 'rufino_linkedin'
   AND (
         (table_name = 'connections' AND column_name IN ('pending_regeneration_token_hash', 'pending_regeneration_token_expires_at', 'active_edit_token_hash', 'active_edit_token_expires_at'))
      OR (table_name = 'followups' AND column_name IN ('callback_query_id', 'claim_token_hash', 'claim_expires_at', 'claimed_by', 'claim_execution_id'))
      OR (table_name = 'action_tokens')
      OR (table_name = 'callback_receipts')
      OR (table_name = 'notification_jobs')
   )
 ORDER BY table_name, column_name;
-- Esperado: todas as colunas das 3 tabelas novas, mais as 4 de connections
-- e as 5 de followups listadas acima. connections.pending_action_token_hash/
-- _expires_at NÃO devem aparecer (removidas na v1.5.0).

-- 15) connections NÃO tem mais pending_action_token_hash/_expires_at
--     (substituídas por action_tokens, v1.5.0).
SELECT column_name
  FROM information_schema.columns
 WHERE table_schema = 'rufino_linkedin'
   AND table_name = 'connections'
   AND column_name IN ('pending_action_token_hash', 'pending_action_token_expires_at');
-- Esperado: 0 linhas.

-- 16) UNIQUE constraints de posse/dedupe (v1.5.0): followups.claim_token_hash,
--     followups.callback_query_id, notification_jobs.claim_token_hash,
--     action_tokens.token_hash, callback_receipts (PK em callback_query_id).
SELECT t.relname AS tabela, c.conname, c.contype
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'rufino_linkedin'
   AND c.conname IN (
        'followups_claim_token_hash_key', 'followups_callback_query_id_key',
        'notification_jobs_claim_token_hash_key', 'action_tokens_token_hash_key'
   )
 ORDER BY tabela, c.conname;
-- Esperado: 4 linhas, todas contype = 'u' (UNIQUE).

-- 17) Índice UNIQUE parcial de idempotência de record_workflow_error
--     (Correção 8) existe.
SELECT indexname, indexdef
  FROM pg_indexes
 WHERE schemaname = 'rufino_linkedin'
   AND indexname = 'workflow_errors_execution_dedupe_key';
-- Esperado: 1 linha, indexdef contendo "UNIQUE" e "NULLS NOT DISTINCT" e o
-- WHERE "execution_id IS NOT NULL AND resolved = false".

-- 18) Estados sem saída (auditoria estrutural do modelo de transições —
--     inalterado desde a v1.4.2, a máquina de estados em si não mudou
--     nesta rodada). DESCARTADO e ENCERRADO são terminais por desenho.
WITH estados_nao_terminais(status) AS (
    VALUES ('NOVO'), ('AGUARDANDO_ANALISE'), ('AGUARDANDO_D1'), ('AGUARDANDO_APROVACAO'),
           ('APROVADO'), ('REFAZER'), ('PRONTO_PARA_ENVIO'), ('ENVIADO'),
           ('RESPONDEU'), ('SEM_RESPOSTA'), ('FOLLOWUP_PENDENTE')
),
arestas(de, para) AS (
    VALUES ('NOVO','AGUARDANDO_ANALISE'), ('NOVO','AGUARDANDO_D1'), ('AGUARDANDO_ANALISE','AGUARDANDO_D1'),
           ('AGUARDANDO_D1','AGUARDANDO_APROVACAO'), ('AGUARDANDO_APROVACAO','APROVADO'),
           ('AGUARDANDO_APROVACAO','AGUARDANDO_APROVACAO'), ('AGUARDANDO_APROVACAO','REFAZER'),
           ('AGUARDANDO_APROVACAO','DESCARTADO'), ('REFAZER','AGUARDANDO_APROVACAO'),
           ('APROVADO','PRONTO_PARA_ENVIO'), ('PRONTO_PARA_ENVIO','ENVIADO'),
           ('PRONTO_PARA_ENVIO','AGUARDANDO_APROVACAO'), ('ENVIADO','FOLLOWUP_PENDENTE'),
           ('FOLLOWUP_PENDENTE','RESPONDEU'), ('FOLLOWUP_PENDENTE','SEM_RESPOSTA'),
           ('RESPONDEU','ENCERRADO'), ('SEM_RESPOSTA','FOLLOWUP_PENDENTE'), ('SEM_RESPOSTA','ENCERRADO')
)
SELECT ent.status AS estado_sem_saida
  FROM estados_nao_terminais ent
 WHERE NOT EXISTS (SELECT 1 FROM arestas a WHERE a.de = ent.status);
-- Esperado: 0 linhas. Esta consulta espelha exatamente a lista de arestas
-- de transition_connection_status em 006_functions.sql.

-- 19) Roles: nenhuma role já existente com atributo administrativo
--     divergente (informativo — 002_roles_and_schema.sql já aborta
--     automaticamente se isso acontecer).
SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolreplication
  FROM pg_roles
 WHERE rolname IN ('n8n_rufino_linkedin_owner_dev', 'n8n_rufino_linkedin_dev');

-- 20) Role de aplicação não é membro da role owner.
SELECT r_member.rolname AS member, r_role.rolname AS of_role
  FROM pg_auth_members m
  JOIN pg_roles r_member ON r_member.oid = m.member
  JOIN pg_roles r_role ON r_role.oid = m.roleid
 WHERE r_member.rolname = 'n8n_rufino_linkedin_dev'
   AND r_role.rolname = 'n8n_rufino_linkedin_owner_dev';
-- Esperado: 0 linhas.

-- 21) delivery_events.delivery_mode aceita somente MANUAL_ASSISTED
--     enquanto o adaptador API_APPROVED não estiver implementado (Correção 9).
SELECT conname, pg_get_constraintdef(oid) AS definicao
  FROM pg_constraint
 WHERE conrelid = 'rufino_linkedin.delivery_events'::regclass
   AND conname = 'delivery_events_delivery_mode_check';
-- Esperado: 1 linha, definicao contendo apenas 'MANUAL_ASSISTED' na lista
-- IN (...) — sem 'LINKEDIN_MESSAGES_API_APPROVED'.

-- 22) [v1.5.1, Correção 2] Índice UNIQUE parcial de job ativo por
--     conexão/tipo existe, e a constraint antiga (que impedia múltiplas
--     linhas DELIVERED/SUPERSEDED históricas) não existe mais.
SELECT indexname, indexdef
  FROM pg_indexes
 WHERE schemaname = 'rufino_linkedin'
   AND indexname = 'notification_jobs_one_active_per_connection_type_idx';
-- Esperado: 1 linha, indexdef contendo "UNIQUE" e
-- "WHERE ((status = 'PENDING'::text) OR (status = 'CLAIMED'::text))" (ou
-- equivalente com ANY/ARRAY, conforme o plano do Postgres).

SELECT conname
  FROM pg_constraint
 WHERE conrelid = 'rufino_linkedin.notification_jobs'::regclass
   AND conname = 'notification_jobs_active_per_connection_type_key';
-- Esperado: 0 linhas — a constraint antiga, que bloqueava indevidamente
-- duas linhas DELIVERED (ou duas SUPERSEDED) para a mesma conexão/tipo,
-- foi substituída pelo índice parcial acima.

-- 23) [v1.5.1, Correção 1] Nenhum callback_receipts.result contém a
--     CHAVE raw_edit_token/raw_regeneration_token/raw_action_token/
--     raw_claim_token, e nenhum valor de token bruto (48 ou 64 caracteres
--     hex, os dois comprimentos usados nesta jornada) aparece em lugar
--     nenhum do JSON serializado como texto — verificação de conteúdo,
--     não só de nome de coluna.
SELECT callback_query_id, result
  FROM rufino_linkedin.callback_receipts
 WHERE result ? 'raw_edit_token'
    OR result ? 'raw_regeneration_token'
    OR result ? 'raw_action_token'
    OR result ? 'raw_claim_token';
-- Esperado: 0 linhas — nenhuma dessas chaves deve existir no JSON, em
-- nenhuma linha, de nenhuma operação (approve_message, mark_message_sent,
-- complete_followup).

SELECT callback_query_id
  FROM rufino_linkedin.callback_receipts
 WHERE result::text ~ '[0-9a-f]{48}' OR result::text ~ '[0-9a-f]{64}';
-- Esperado: 0 linhas — nenhum valor de token bruto (hex de 24 ou 32
-- bytes) aparece em texto puro em nenhum resultado persistido, mesmo sob
-- uma chave com nome diferente.
