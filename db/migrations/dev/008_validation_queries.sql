-- =============================================================================
-- 008_validation_queries.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.4.2
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

-- 2) 11 funções esperadas no schema rufino_linkedin.
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado (11 linhas): approve_message, claim_due_connections,
-- claim_due_followups, complete_followup, mark_message_sent,
-- present_message_for_delivery, record_workflow_error, register_connection,
-- save_message_edit, save_regenerated_message, transition_connection_status.

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

-- 4) EXECUTE das 11 funções: 10 executáveis por n8n_rufino_linkedin_dev,
--    1 interna (transition_connection_status) só acessível à role owner e
--    às outras 10 funções que a chamam por dentro; PUBLIC nunca em nenhuma
--    das 11.
SELECT p.proname,
       has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'EXECUTE') AS app_pode_executar,
       has_function_privilege('public', p.oid, 'EXECUTE')                  AS public_pode_executar
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin'
 ORDER BY p.proname;
-- Esperado: public_pode_executar = false em TODAS as 11. app_pode_executar =
-- true em 10 (register_connection, present_message_for_delivery,
-- claim_due_connections, approve_message, save_message_edit,
-- save_regenerated_message, mark_message_sent, claim_due_followups,
-- complete_followup, record_workflow_error) e = false só em
-- transition_connection_status.

-- 4b) Confirmação direta e nomeada do item acima, para não depender de
--     conferir 11 linhas manualmente: conta quantas são executáveis pela
--     role de aplicação.
SELECT
    count(*) FILTER (WHERE has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'EXECUTE')) AS executaveis_pela_app,
    count(*) AS total_funcoes
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'rufino_linkedin';
-- Esperado: executaveis_pela_app = 10, total_funcoes = 11.

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
--     reivindicada de novo (só é informativo, não indica erro por si só,
--     já que pode ser um claim legitimamente em andamento).
SELECT followup_id, connection_id, claimed_at, executed_at, updated_at
  FROM rufino_linkedin.followups
 WHERE claimed_at IS NOT NULL
   AND executed_at IS NULL
   AND claimed_at <= now() - interval '1 hour';
-- Informativo: linhas aqui são candidatas a reivindicação pelo próximo
-- claim_due_followups (não é, por si só, um erro de migration).

-- 14) Colunas novas da v1.4.2 existem com o tipo esperado (Correção 1:
--     regeneration token em connections; Correção 2: callback_query_id em
--     followups).
SELECT table_name, column_name, data_type
  FROM information_schema.columns
 WHERE table_schema = 'rufino_linkedin'
   AND (
         (table_name = 'connections' AND column_name IN ('pending_regeneration_token_hash', 'pending_regeneration_token_expires_at'))
      OR (table_name = 'followups' AND column_name = 'callback_query_id')
   )
 ORDER BY table_name, column_name;
-- Esperado (3 linhas): connections.pending_regeneration_token_expires_at
-- (timestamp with time zone), connections.pending_regeneration_token_hash
-- (text), followups.callback_query_id (text).

-- 15) UNIQUE de followups.callback_query_id existe (Correção 2/6 —
--     dedupe de complete_followup).
SELECT conname, contype
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'rufino_linkedin'
   AND t.relname = 'followups'
   AND conname = 'followups_callback_query_id_key';
-- Esperado: 1 linha, contype = 'u' (UNIQUE).

-- 16) Nenhuma tabela contém coluna de valor bruto de regeneration_token
--     (mesma auditoria estrutural do item 10, estendida à v1.4.2).
SELECT table_name, column_name
  FROM information_schema.columns
 WHERE table_schema = 'rufino_linkedin'
   AND column_name ILIKE '%regeneration_token%'
   AND column_name NOT LIKE '%_hash'
   AND column_name NOT LIKE '%_expires_at';
-- Esperado: 0 linhas. Só pending_regeneration_token_hash e
-- pending_regeneration_token_expires_at devem existir.

-- 17) Estados sem saída (auditoria estrutural do modelo de transições —
--     Correções 1 e 2): para cada status não-terminal, deve existir pelo
--     menos uma aresta de saída na lista abaixo. DESCARTADO e ENCERRADO são
--     terminais por desenho e ficam de fora desta lista de propósito.
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
-- de transition_connection_status em 006_functions.sql — se divergir dali,
-- corrigir a lista acima antes de reexecutar, não o inverso.

-- 18) Roles: nenhuma role já existente com atributo administrativo
--     divergente (informativo — 002_roles_and_schema.sql já aborta
--     automaticamente se isso acontecer; esta consulta é só para inspeção
--     manual antes de aplicar).
SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolreplication
  FROM pg_roles
 WHERE rolname IN ('n8n_rufino_linkedin_owner_dev', 'n8n_rufino_linkedin_dev');
-- Esperado, se as roles já existirem antes de aplicar: owner com
-- rolcanlogin=false e as demais colunas em false; app com rolcanlogin=true
-- e as demais colunas em false. Se este SELECT retornar 0 linhas, as roles
-- ainda não existem — 002 vai criá-las do zero, sem esta checagem se aplicar.

-- 19) Role de aplicação não é membro da role owner (Correção 5 — herança de
--     role quebraria o isolamento SECURITY DEFINER).
SELECT r_member.rolname AS member, r_role.rolname AS of_role
  FROM pg_auth_members m
  JOIN pg_roles r_member ON r_member.oid = m.member
  JOIN pg_roles r_role ON r_role.oid = m.roleid
 WHERE r_member.rolname = 'n8n_rufino_linkedin_dev'
   AND r_role.rolname = 'n8n_rufino_linkedin_owner_dev';
-- Esperado: 0 linhas.
