-- =============================================================================
-- 002_roles_and_schema.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — patch v1.4.1
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
--
-- ATOMICIDADE (fix v1.4.1, item 5): todo o arquivo roda dentro de uma única
-- transação — se qualquer instrução falhar, nada deste arquivo fica
-- meio-aplicado.
-- =============================================================================

BEGIN;

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
-- apenas EXECUTE nas 8 funções voltadas ao n8n + SELECT nas 8 tabelas (ver
-- 005_rls_and_grants.sql e o bloco de permissões dentro de
-- 006_functions.sql) — nenhum INSERT/UPDATE/DELETE direto em tabela. A nona
-- função (`transition_connection_status`) é interna — só a role owner e as
-- outras 8 funções (que rodam como owner) podem chamá-la; ver
-- 006_functions.sql e `references/postgres-functions.md` da skill.
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

-- ---------------------------------------------------------------------------
-- Acesso a pgcrypto (schema `extensions`) — fix v1.4.1, item 2.
--
-- As funções SECURITY DEFINER (006_functions.sql) chamam
-- extensions.gen_random_bytes(...) e extensions.digest(...) enquanto rodam
-- COMO a role owner (é assim que SECURITY DEFINER funciona — o corpo da
-- função executa com os privilégios de quem é dono da função, não de quem
-- a chama). Para essas chamadas resolverem, a role owner precisa de USAGE
-- no schema `extensions` e EXECUTE nas duas funções específicas do
-- pgcrypto usadas nesta jornada — conceder isso explicitamente em vez de
-- depender de qualquer grant a PUBLIC que a instalação da extensão possa
-- ou não ter deixado.
--
-- A role de aplicação (`n8n_rufino_linkedin_dev`) NUNCA recebe acesso ao
-- schema `extensions` — ela nunca chama digest()/gen_random_bytes()
-- diretamente, só através das funções SECURITY DEFINER, que já rodam como
-- a owner. Dar `USAGE`/`EXECUTE` de `extensions` à role de aplicação seria
-- um privilégio a mais que ela não usa e não deve ter.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA extensions TO n8n_rufino_linkedin_owner_dev;
GRANT EXECUTE ON FUNCTION extensions.digest(text, text) TO n8n_rufino_linkedin_owner_dev;
GRANT EXECUTE ON FUNCTION extensions.gen_random_bytes(integer) TO n8n_rufino_linkedin_owner_dev;

COMMIT;
