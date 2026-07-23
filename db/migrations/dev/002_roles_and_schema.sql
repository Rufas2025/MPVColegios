-- =============================================================================
-- 002_roles_and_schema.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV)
--
-- Cria o schema privado rufino_linkedin e as duas roles dedicadas do
-- ambiente DEV:
--   - n8n_rufino_linkedin_owner_dev: dona das tabelas/funções, NOLOGIN.
--   - n8n_rufino_linkedin_dev: role de aplicação, credencial real do n8n.
--
-- REGRA DE SENHA: esta migration NUNCA define uma senha real, nem sequer um
-- placeholder que possa ser executado acidentalmente como senha válida.
-- A role de aplicação é criada com LOGIN mas SEM cláusula PASSWORD — nesse
-- estado, autenticação por senha falha até que Anderson rode manualmente,
-- fora do controle de versão, um comando equivalente a:
--     ALTER ROLE n8n_rufino_linkedin_dev PASSWORD '<senha forte gerada fora deste repositório>';
-- Ver MANUAL-STEPS.md para o procedimento completo.
-- =============================================================================

-- Schema operacional privado — nunca "public".
CREATE SCHEMA IF NOT EXISTS rufino_linkedin;

COMMENT ON SCHEMA rufino_linkedin IS
    'Schema operacional privado da jornada Rufino LinkedIn Intelligence (DEV, EasyPanel/rufino-linkedin-dev). Objetos sempre referenciados de forma totalmente qualificada.';

-- ---------------------------------------------------------------------------
-- Role owner: dona das tabelas e funções SECURITY DEFINER. NOLOGIN — nunca é
-- usada para conectar (nem pelo n8n, nem por ninguém). É o que torna
-- SECURITY DEFINER seguro aqui: a role de aplicação nunca É a dona, só tem
-- EXECUTE.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_rufino_linkedin_owner_dev') THEN
        CREATE ROLE n8n_rufino_linkedin_owner_dev
            NOLOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
    END IF;
END;
$$;

COMMENT ON ROLE n8n_rufino_linkedin_owner_dev IS
    'Owner das tabelas e funções SECURITY DEFINER do schema rufino_linkedin (DEV). NOLOGIN — nunca usada para conectar. Sem senha: role sem LOGIN não autentica.';

-- ---------------------------------------------------------------------------
-- Role de aplicação: credencial real que o n8n usa para conectar ao
-- serviço linkedin-db (EasyPanel, projeto rufino-linkedin-dev). Recebe
-- apenas EXECUTE nas 9 funções + SELECT nas 8 tabelas (ver
-- 005_rls_and_grants.sql e 007_function_permissions.sql) — nenhum
-- INSERT/UPDATE/DELETE direto em tabela.
--
-- Explicitamente SEM: SUPERUSER, BYPASSRLS, CREATEDB, CREATEROLE,
-- REPLICATION — regra de segurança fechada para esta migration.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_rufino_linkedin_dev') THEN
        CREATE ROLE n8n_rufino_linkedin_dev
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS
            CONNECTION LIMIT 20;
        -- Nenhuma cláusula PASSWORD acima, de propósito — ver cabeçalho deste
        -- arquivo e MANUAL-STEPS.md. Sem senha definida, o login por senha
        -- falha até a ação manual de Anderson.
    END IF;
END;
$$;

COMMENT ON ROLE n8n_rufino_linkedin_dev IS
    'Role de aplicação usada pela credencial Postgres do n8n (DEV, serviço linkedin-db). Sem SUPERUSER/BYPASSRLS/CREATEDB/CREATEROLE/REPLICATION. Senha definida manualmente fora desta migration — ver MANUAL-STEPS.md.';

-- Dono do schema: a role owner (objetos criados nas próximas migrations
-- recebem OWNER TO explícito para essa role).
ALTER SCHEMA rufino_linkedin OWNER TO n8n_rufino_linkedin_owner_dev;
