-- =============================================================================
-- 001_preflight.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.0
-- Ambiente: DEV — EasyPanel, projeto rufino-linkedin-dev, serviço n8n / linkedin-db
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 001_preflight.sql (vale para todos
-- os arquivos 001–009 desta migration — sem essa flag, um erro no meio de
-- um arquivo não interrompe o psql, que segue tentando rodar os comandos
-- seguintes dentro da mesma transação já abortada).
--
-- Objetivo: validar pré-condições antes de qualquer objeto ser criado.
-- Este script é SOMENTE LEITURA — não cria, altera, remove ou move nenhum
-- objeto, role, schema ou extensão. Se qualquer condição falhar, aborta com
-- erro claro (RAISE EXCEPTION) e a migration inteira não deve prosseguir.
--
-- Não tenta mover nem reinstalar pgcrypto em nenhuma hipótese — se o schema
-- da extensão divergir do esperado, a correção é manual, fora deste script.
-- =============================================================================

DO $preflight$
DECLARE
    v_server_version_num integer := current_setting('server_version_num')::integer;
    v_server_version_text text := current_setting('server_version');
    v_current_database text := current_database();
    v_expected_database text := 'rufino-linkedin-dev';
    v_pgcrypto_installed boolean;
    v_pgcrypto_schema text;
    v_pgcrypto_version text;
    v_expected_pgcrypto_schema text := 'extensions';
BEGIN
    -- 1) Versão do PostgreSQL compatível.
    --    Ambiente confirmado: PostgreSQL 17.10. Exigimos >= 13 (mínimo que
    --    suporta os recursos usados nesta migration: FOR UPDATE SKIP LOCKED
    --    já disponível desde 9.5, mas fixamos 13 como piso de suporte real).
    IF v_server_version_num < 130000 THEN
        RAISE EXCEPTION
            'PREFLIGHT FALHOU: versão do PostgreSQL incompatível (% / server_version_num=%). Esta migration requer PostgreSQL 13 ou superior.',
            v_server_version_text, v_server_version_num;
    END IF;

    -- 2) Banco atual é o banco operacional esperado (rufino-linkedin-dev).
    IF v_current_database <> v_expected_database THEN
        RAISE EXCEPTION
            'PREFLIGHT FALHOU: banco atual é "%", esperado "%". Esta migration só deve ser aplicada no banco operacional da jornada LinkedIn em DEV (serviço linkedin-db, projeto rufino-linkedin-dev no EasyPanel).',
            v_current_database, v_expected_database;
    END IF;

    -- 3) Extensão pgcrypto instalada no banco atual.
    SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto')
      INTO v_pgcrypto_installed;

    IF NOT v_pgcrypto_installed THEN
        RAISE EXCEPTION
            'PREFLIGHT FALHOU: extensão pgcrypto não está instalada no banco "%". Esta migration não instala extensões — confirme/instale manualmente e reexecute o preflight antes de prosseguir.',
            v_current_database;
    END IF;

    -- 4) pgcrypto instalada no schema esperado (extensions), não em public
    --    nem em outro schema. Confirmado por consulta real em pg_extension
    --    nesta rodada: schema "extensions", versão 1.3.
    SELECT n.nspname, e.extversion
      INTO v_pgcrypto_schema, v_pgcrypto_version
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pgcrypto';

    IF v_pgcrypto_schema IS DISTINCT FROM v_expected_pgcrypto_schema THEN
        RAISE EXCEPTION
            'PREFLIGHT FALHOU: pgcrypto está instalada no schema "%", esperado "%". Esta migration não move a extensão — corrija manualmente (fora deste script) e reexecute o preflight antes de aplicar 006_functions.sql.',
            v_pgcrypto_schema, v_expected_pgcrypto_schema;
    END IF;

    RAISE NOTICE
        'PREFLIGHT OK — PostgreSQL % (compatível); banco atual "%" (esperado); pgcrypto % instalada em schema "%" (esperado "%").',
        v_server_version_text, v_current_database, v_pgcrypto_version, v_pgcrypto_schema, v_expected_pgcrypto_schema;
END;
$preflight$;
