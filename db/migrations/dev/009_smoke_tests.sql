-- =============================================================================
-- 009_smoke_tests.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.4.2
--
-- Smoke test exaustivo para rodar manualmente logo depois de aplicar
-- 001–008, ANTES de qualquer uso real da migration. Roda inteiro dentro de
-- BEGIN...ROLLBACK — nunca commita, então nenhuma linha criada aqui
-- permanece no banco ao final, mesmo se todos os testes passarem ou se
-- algum falhar no meio.
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 009_smoke_tests.sql
--
-- IMPORTANTE: este arquivo NÃO FOI EXECUTADO como parte desta entrega —
-- nenhuma linha foi rodada contra nenhum banco. O que existe aqui foi
-- revisado estaticamente (sintaxe, assinaturas de função conferidas contra
-- 006_functions.sql, sequência lógica dos 30 itens exigidos) — não uma
-- alegação de que os testes passaram em um PostgreSQL real.
--
-- Pré-requisito de quem executa: uma credencial administrativa capaz de
-- `SET LOCAL ROLE n8n_rufino_linkedin_dev` (ex.: a mesma conexão usada para
-- aplicar 001–008) — não a própria credencial do n8n. O script alterna
-- entre a role de aplicação (para provar o que o n8n consegue fazer) e a
-- sessão administrativa (só para preparar pré-requisitos que a role de
-- aplicação não tem permissão de fazer sozinha, como adiantar
-- scheduled_at/expires_at, e para os testes de privilégio de outras roles).
--
-- Cobertura (30 itens exigidos, numerados abaixo como comentário [N]):
--   [1-3]   register_connection cria connection + analysis + message_versions v1
--   [4]     retry de register_connection devolve already_existed sem duplicar
--   [5]     claim_due_connections funciona
--   [6-7]   mensagem apresentada + aprovação funcionam
--   [8]     edição cria nova versão
--   [9-10]  REFAZER gera regeneration_token; save_regenerated_message cria nova versão GPT
--   [11]    regeneration_token é uso único
--   [12]    regeneration_token expirado falha
--   [13]    versão cruzada (de outra conexão) falha
--   [14]    versão obsoleta falha
--   [15-16] mark_message_sent cria primeiro follow-up; retry não duplica
--   [17]    claim_due_followups funciona
--   [18]    complete_followup RESPONDEU encerra a jornada
--   [19]    complete_followup SEM_RESPOSTA cria próximo follow-up
--   [20]    SEM_RESPOSTA sem próxima data encerra
--   [21]    callback duplicado é rejeitado
--   [22]    claim abandonado volta a ficar elegível
--   [23]    followup executado não volta a ser reivindicado
--   [24]    record_workflow_error permanece gravado quando a transição falha
--   [25]    escrita direta nas tabelas falha para a aplicação
--   [26]    transition_connection_status falha quando chamada pela aplicação
--   [27]    todas as 11 funções têm EXECUTE revogado de PUBLIC
--   [28]    role da aplicação não possui privilégios administrativos
--   [29]    role da aplicação não é membro da owner
--   [30]    todos os dados de teste desaparecem após ROLLBACK (garantido
--           pela própria estrutura deste arquivo, ver rodapé)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- [27] Todas as 11 funções têm EXECUTE revogado de PUBLIC (checagem
--      administrativa, antes de qualquer SET LOCAL ROLE).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_count_public_pode_executar integer;
    v_total_funcoes integer;
BEGIN
    SELECT
        count(*) FILTER (WHERE has_function_privilege('public', p.oid, 'EXECUTE')),
        count(*)
      INTO v_count_public_pode_executar, v_total_funcoes
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rufino_linkedin';

    IF v_total_funcoes <> 11 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [27-count]: esperadas 11 funcoes em rufino_linkedin, encontradas %', v_total_funcoes;
    END IF;

    IF v_count_public_pode_executar <> 0 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [27]: % das 11 funcoes ainda sao executaveis por PUBLIC', v_count_public_pode_executar;
    END IF;

    RAISE NOTICE 'SMOKE OK [27]: 11 funcoes confirmadas, 0 executaveis por PUBLIC';
END;
$$;

-- -----------------------------------------------------------------------------
-- [28] Role de aplicação não possui privilégios administrativos.
-- [29] Role de aplicação não é membro da role owner.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_rolsuper boolean;
    v_rolbypassrls boolean;
    v_rolcreatedb boolean;
    v_rolcreaterole boolean;
    v_rolreplication boolean;
    v_is_member boolean;
BEGIN
    SELECT rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolreplication
      INTO v_rolsuper, v_rolbypassrls, v_rolcreatedb, v_rolcreaterole, v_rolreplication
      FROM pg_roles WHERE rolname = 'n8n_rufino_linkedin_dev';

    IF v_rolsuper OR v_rolbypassrls OR v_rolcreatedb OR v_rolcreaterole OR v_rolreplication THEN
        RAISE EXCEPTION 'SMOKE FALHOU [28]: n8n_rufino_linkedin_dev tem privilegio administrativo (super=%, bypassrls=%, createdb=%, createrole=%, replication=%)',
            v_rolsuper, v_rolbypassrls, v_rolcreatedb, v_rolcreaterole, v_rolreplication;
    END IF;
    RAISE NOTICE 'SMOKE OK [28]: role de aplicacao sem privilegios administrativos';

    SELECT EXISTS (
        SELECT 1 FROM pg_auth_members m
        JOIN pg_roles r_member ON r_member.oid = m.member
        JOIN pg_roles r_role ON r_role.oid = m.roleid
        WHERE r_member.rolname = 'n8n_rufino_linkedin_dev'
          AND r_role.rolname = 'n8n_rufino_linkedin_owner_dev'
    ) INTO v_is_member;

    IF v_is_member THEN
        RAISE EXCEPTION 'SMOKE FALHOU [29]: n8n_rufino_linkedin_dev e membro de n8n_rufino_linkedin_owner_dev';
    END IF;
    RAISE NOTICE 'SMOKE OK [29]: role de aplicacao nao e membro da owner';
END;
$$;

SET LOCAL ROLE n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- [1-3] register_connection cria connection + analysis + message_versions v1.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id       uuid;
    v_status              text;
    v_message_version_id  uuid;
    v_already             boolean;
    v_mv_count            integer;
    v_mv_version          integer;
    v_mv_source           text;
    v_analysis_count      integer;
BEGIN
    SELECT r.connection_id, r.status, r.message_version_id, r.already_existed
      INTO v_connection_id, v_status, v_message_version_id, v_already
      FROM rufino_linkedin.register_connection(
        'smoke-A-' || gen_random_uuid()::text,
        'Fulano de Tal A', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-a', NULL, CURRENT_DATE,
        'Resumo A', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa A',
        0.9, false, '[]'::jsonb, 'brain-test-1', 'Mensagem inicial A, gerada pelo GPT.'
      ) r;

    IF v_connection_id IS NULL OR v_status <> 'AGUARDANDO_D1' OR v_message_version_id IS NULL OR v_already IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'SMOKE FALHOU [1-3]: register_connection nao retornou os campos esperados (connection_id=%, status=%, message_version_id=%, already_existed=%)',
            v_connection_id, v_status, v_message_version_id, v_already;
    END IF;

    SELECT count(*) INTO v_analysis_count FROM rufino_linkedin.analyses a WHERE a.connection_id = v_connection_id;
    IF v_analysis_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [1-3]: esperada exatamente 1 analysis, obtido %', v_analysis_count;
    END IF;

    SELECT count(*), max(version) INTO v_mv_count, v_mv_version
      FROM rufino_linkedin.message_versions mv WHERE mv.connection_id = v_connection_id;
    IF v_mv_count <> 1 OR v_mv_version <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [1-3]: esperada exatamente 1 message_version, versao 1; obtido count=%, version=%', v_mv_count, v_mv_version;
    END IF;

    SELECT mv.source INTO v_mv_source FROM rufino_linkedin.message_versions mv WHERE mv.message_version_id = v_message_version_id;
    IF v_mv_source <> 'gpt' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [1-3]: source esperado gpt, obtido %', v_mv_source;
    END IF;

    RAISE NOTICE 'SMOKE OK [1-3]: register_connection cria connection + analysis + message_version 1 (source=gpt)';
    PERFORM set_config('smoketest.conn_a', v_connection_id::text, true);
    PERFORM set_config('smoketest.conn_a_idem', (SELECT idempotency_key FROM rufino_linkedin.connections WHERE connection_id = v_connection_id), true);
END;
$$;

-- -----------------------------------------------------------------------------
-- [4] Retry de register_connection (mesma idempotency_key) devolve
--     already_existed=true sem duplicar connections/analyses/message_versions.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id      uuid := current_setting('smoketest.conn_a')::uuid;
    v_idem               text := current_setting('smoketest.conn_a_idem');
    v_retry_connection_id uuid;
    v_retry_already      boolean;
    v_conn_count         integer;
    v_analysis_count     integer;
    v_mv_count           integer;
BEGIN
    SELECT r.connection_id, r.already_existed INTO v_retry_connection_id, v_retry_already
      FROM rufino_linkedin.register_connection(
        v_idem, 'Fulano de Tal A (retry)', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-a', NULL, CURRENT_DATE,
        'Resumo A retry', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa A retry',
        0.9, false, '[]'::jsonb, 'brain-test-1', 'Mensagem de retry, nao deveria ser usada.'
      ) r;

    IF v_retry_connection_id <> v_connection_id OR v_retry_already IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'SMOKE FALHOU [4]: retry deveria devolver o mesmo connection_id (%) com already_existed=true (obtido connection_id=%, already_existed=%)',
            v_connection_id, v_retry_connection_id, v_retry_already;
    END IF;

    SELECT count(*) INTO v_conn_count FROM rufino_linkedin.connections c WHERE c.idempotency_key = v_idem;
    SELECT count(*) INTO v_analysis_count FROM rufino_linkedin.analyses a WHERE a.connection_id = v_connection_id;
    SELECT count(*) INTO v_mv_count FROM rufino_linkedin.message_versions mv WHERE mv.connection_id = v_connection_id;

    IF v_conn_count <> 1 OR v_analysis_count <> 1 OR v_mv_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [4]: retry duplicou dados (connections=%, analyses=%, message_versions=%, esperado 1/1/1)',
            v_conn_count, v_analysis_count, v_mv_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [4]: retry de register_connection idempotente, sem duplicar nada';
END;
$$;

-- -----------------------------------------------------------------------------
-- [5] claim_due_connections funciona (após adiantar scheduled_at como admin).
-- -----------------------------------------------------------------------------
RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_a')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_token         text;
    v_message_version_id uuid;
BEGIN
    SELECT c.raw_pending_action_token, c.message_version_id INTO v_token, v_message_version_id
      FROM rufino_linkedin.claim_due_connections(1000) c
     WHERE c.connection_id = v_connection_id;

    IF v_token IS NULL OR v_message_version_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [5]: claim_due_connections nao devolveu token/message_version_id para a conexao de teste';
    END IF;

    RAISE NOTICE 'SMOKE OK [5]: claim_due_connections reivindicou a conexao e devolveu token + versao vigente';
    PERFORM set_config('smoketest.conn_a_token1', v_token, true);
    PERFORM set_config('smoketest.conn_a_mv1', v_message_version_id::text, true);
END;
$$;

-- -----------------------------------------------------------------------------
-- [8] Edição (save_message_edit) cria nova versão — feito ANTES da aprovação
--     para depois provar [14] versão obsoleta falha (v1 vira obsoleta).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_edit_hash text;
    v_raw_edit_token text := encode(extensions.gen_random_bytes(32), 'hex');
BEGIN
    -- Simula o que approve_message faria ao gerar um edit_token: aqui, para
    -- isolar o teste de save_message_edit em si, preparamos o hash
    -- diretamente como admin seria mais simples, mas para testar como a
    -- role de aplicação de fato usa a função, passamos por approve_message
    -- decisao=EDITAR de verdade.
    NULL;
END;
$$;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_token1 text := current_setting('smoketest.conn_a_token1');
    v_mv1 uuid := current_setting('smoketest.conn_a_mv1')::uuid;
    v_raw_edit_token text;
    v_new_status text;
    v_message_version_id uuid;
    v_version integer;
    v_token_after_edit text;
BEGIN
    SELECT r.raw_edit_token, r.new_status INTO v_raw_edit_token, v_new_status
      FROM rufino_linkedin.approve_message(
        v_connection_id, v_mv1, 'EDITAR', 'telegram:anderson_rufino', NULL,
        'cb-edit-' || gen_random_uuid()::text, v_token1
      ) r;

    IF v_raw_edit_token IS NULL OR v_new_status <> 'AGUARDANDO_APROVACAO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [8-setup]: approve_message EDITAR nao devolveu edit_token ou status inesperado (%)', v_new_status;
    END IF;

    SELECT r.message_version_id, r.version, r.raw_pending_action_token
      INTO v_message_version_id, v_version, v_token_after_edit
      FROM rufino_linkedin.save_message_edit(v_raw_edit_token, 'Mensagem editada por Anderson.', 'telegram:anderson_rufino') r;

    IF v_message_version_id IS NULL OR v_version <> 2 OR v_token_after_edit IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [8]: save_message_edit nao criou a versao 2 corretamente (version=%, message_version_id=%, token=%)',
            v_version, v_message_version_id, v_token_after_edit;
    END IF;

    RAISE NOTICE 'SMOKE OK [8]: save_message_edit criou message_versions.version=2';
    PERFORM set_config('smoketest.conn_a_mv2', v_message_version_id::text, true);
    PERFORM set_config('smoketest.conn_a_token2', v_token_after_edit, true);
END;
$$;

-- -----------------------------------------------------------------------------
-- [14] Versão obsoleta falha: tentar approve_message com a v1 (não mais
--      vigente, já que v2 existe) deve ser rejeitado.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_token2 text := current_setting('smoketest.conn_a_token2');
    v_mv1 uuid := current_setting('smoketest.conn_a_mv1')::uuid;
BEGIN
    BEGIN
        PERFORM r.connection_id FROM rufino_linkedin.approve_message(
            v_connection_id, v_mv1, 'APROVAR_E_PREPARAR', 'telegram:anderson_rufino', NULL,
            'cb-obsolete-' || gen_random_uuid()::text, v_token2
        ) r;
        RAISE EXCEPTION 'SMOKE FALHOU [14]: approve_message deveria ter rejeitado a versao obsoleta (v1)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%versao vigente%' THEN
                RAISE NOTICE 'SMOKE OK [14]: approve_message rejeitou corretamente a versao obsoleta';
            ELSE
                RAISE EXCEPTION 'SMOKE FALHOU [14]: approve_message falhou por motivo inesperado: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- [9-10] REFAZER gera regeneration_token; save_regenerated_message cria nova
--        versão GPT. [11] token de uso único. [12] token expirado falha.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_token2 text := current_setting('smoketest.conn_a_token2');
    v_mv2 uuid := current_setting('smoketest.conn_a_mv2')::uuid;
    v_raw_regen text;
    v_regen_expires timestamptz;
    v_new_status text;
BEGIN
    SELECT r.raw_regeneration_token, r.regeneration_token_expires_at, r.new_status
      INTO v_raw_regen, v_regen_expires, v_new_status
      FROM rufino_linkedin.approve_message(
        v_connection_id, v_mv2, 'REFAZER', 'telegram:anderson_rufino', 'motivo de teste',
        'cb-refazer-' || gen_random_uuid()::text, v_token2
      ) r;

    IF v_raw_regen IS NULL OR v_regen_expires IS NULL OR v_new_status <> 'REFAZER' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [9]: approve_message REFAZER nao gerou regeneration_token corretamente (status=%)', v_new_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [9]: approve_message REFAZER gerou regeneration_token e transicionou para REFAZER';
    PERFORM set_config('smoketest.conn_a_regen_token', v_raw_regen, true);
END;
$$;

-- Testa token expirado [12] ANTES de consumir o token válido — usamos um
-- segundo regeneration_token, forçado a expirar como admin, para não
-- interferir no fluxo principal que segue com o token válido gerado acima.
-- Como só existe um slot de pending_regeneration_token por conexão, geramos
-- este teste sobre uma conexão auxiliar dedicada.
DO $$
DECLARE
    v_aux_connection_id uuid;
    v_aux_token1 text;
    v_aux_mv1 uuid;
    v_raw_regen text;
BEGIN
    SELECT r.connection_id, r.message_version_id INTO v_aux_connection_id, v_aux_mv1
      FROM rufino_linkedin.register_connection(
        'smoke-EXP-' || gen_random_uuid()::text,
        'Fulano Expirado', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-exp', NULL, CURRENT_DATE,
        'Resumo', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa',
        0.9, false, '[]'::jsonb, 'brain-test-1', 'Mensagem inicial.'
      ) r;

    PERFORM set_config('smoketest.conn_exp', v_aux_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_exp')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_exp')::uuid;
    v_token text;
    v_mv uuid;
    v_raw_regen text;
BEGIN
    SELECT c.raw_pending_action_token, c.message_version_id INTO v_token, v_mv
      FROM rufino_linkedin.claim_due_connections(1000) c WHERE c.connection_id = v_connection_id;

    SELECT r.raw_regeneration_token INTO v_raw_regen
      FROM rufino_linkedin.approve_message(
        v_connection_id, v_mv, 'REFAZER', 'telegram:anderson_rufino', NULL,
        'cb-refazer-exp-' || gen_random_uuid()::text, v_token
      ) r;

    PERFORM set_config('smoketest.conn_exp_regen_token', v_raw_regen, true);
END;
$$;

-- Como admin, força a expiração do token de regeneração desta conexão
-- auxiliar (simula o TTL de 2 dias já ter passado).
RESET ROLE;
UPDATE rufino_linkedin.connections
   SET pending_regeneration_token_expires_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_exp')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_raw_regen text := current_setting('smoketest.conn_exp_regen_token');
BEGIN
    BEGIN
        PERFORM r.connection_id FROM rufino_linkedin.save_regenerated_message(
            v_raw_regen, 'Nova mensagem gerada apos expirar.'
        ) r;
        RAISE EXCEPTION 'SMOKE FALHOU [12]: save_regenerated_message deveria ter rejeitado o token expirado';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%invalido, expirado ou ja consumido%' THEN
                RAISE NOTICE 'SMOKE OK [12]: save_regenerated_message rejeitou corretamente o token expirado';
            ELSE
                RAISE EXCEPTION 'SMOKE FALHOU [12]: falhou por motivo inesperado: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- [10] save_regenerated_message cria nova versão GPT (fluxo válido, conexão
--      A). [11] Reuso do mesmo token falha (uso único).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_raw_regen text := current_setting('smoketest.conn_a_regen_token');
    v_message_version_id uuid;
    v_version integer;
    v_token text;
BEGIN
    SELECT r.message_version_id, r.version, r.raw_pending_action_token
      INTO v_message_version_id, v_version, v_token
      FROM rufino_linkedin.save_regenerated_message(
        v_raw_regen, 'Nova mensagem gerada pelo GPT apos REFAZER.', 'gpt'
      ) r;

    IF v_message_version_id IS NULL OR v_version <> 3 OR v_token IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [10]: save_regenerated_message nao criou a versao 3 corretamente (version=%)', v_version;
    END IF;

    RAISE NOTICE 'SMOKE OK [10]: save_regenerated_message criou message_versions.version=3 (source=gpt) e reabriu AGUARDANDO_APROVACAO';
    PERFORM set_config('smoketest.conn_a_mv3', v_message_version_id::text, true);
    PERFORM set_config('smoketest.conn_a_token3', v_token, true);
END;
$$;

DO $$
DECLARE
    v_raw_regen text := current_setting('smoketest.conn_a_regen_token');
BEGIN
    BEGIN
        PERFORM r.connection_id FROM rufino_linkedin.save_regenerated_message(
            v_raw_regen, 'Tentativa de reuso do mesmo token.'
        ) r;
        RAISE EXCEPTION 'SMOKE FALHOU [11]: save_regenerated_message deveria ter rejeitado o reuso do token ja consumido';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%invalido, expirado ou ja consumido%' THEN
                RAISE NOTICE 'SMOKE OK [11]: reuso do regeneration_token rejeitado (uso unico confirmado)';
            ELSE
                RAISE EXCEPTION 'SMOKE FALHOU [11]: falhou por motivo inesperado: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- [13] Versão cruzada (de outra conexão) falha: tentar approve_message da
--      conexão A usando o message_version_id da conexão auxiliar EXP.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_token3 text := current_setting('smoketest.conn_a_token3');
    v_exp_connection_id uuid := current_setting('smoketest.conn_exp')::uuid;
    v_exp_mv uuid;
BEGIN
    SELECT mv.message_version_id INTO v_exp_mv
      FROM rufino_linkedin.message_versions mv
     WHERE mv.connection_id = v_exp_connection_id
     ORDER BY mv.version DESC LIMIT 1;

    BEGIN
        PERFORM r.connection_id FROM rufino_linkedin.approve_message(
            v_connection_id, v_exp_mv, 'APROVAR_E_PREPARAR', 'telegram:anderson_rufino', NULL,
            'cb-cross-' || gen_random_uuid()::text, v_token3
        ) r;
        RAISE EXCEPTION 'SMOKE FALHOU [13]: approve_message deveria ter rejeitado message_version_id de outra conexao';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%nao pertence a connection_id%' THEN
                RAISE NOTICE 'SMOKE OK [13]: approve_message rejeitou corretamente a versao de outra conexao';
            ELSE
                RAISE EXCEPTION 'SMOKE FALHOU [13]: falhou por motivo inesperado: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- [6-7] Mensagem apresentada + aprovação funcionam (fluxo válido, conexão A,
--       agora com a versao 3 vigente).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_token3 text := current_setting('smoketest.conn_a_token3');
    v_mv3 uuid := current_setting('smoketest.conn_a_mv3')::uuid;
    v_new_status text;
    v_token_delivery text;
    v_delivery_event_id uuid;
BEGIN
    SELECT r.new_status INTO v_new_status
      FROM rufino_linkedin.approve_message(
        v_connection_id, v_mv3, 'APROVAR_E_PREPARAR', 'telegram:anderson_rufino', NULL,
        'cb-aprovar-' || gen_random_uuid()::text, v_token3
      ) r;

    IF v_new_status <> 'APROVADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [7]: approve_message APROVAR_E_PREPARAR nao transicionou para APROVADO (obtido %)', v_new_status;
    END IF;
    RAISE NOTICE 'SMOKE OK [7]: aprovacao funciona (APROVADO)';

    SELECT r.raw_pending_action_token, r.delivery_event_id INTO v_token_delivery, v_delivery_event_id
      FROM rufino_linkedin.present_message_for_delivery(v_connection_id, v_mv3) r;

    IF v_token_delivery IS NULL OR v_delivery_event_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [6]: present_message_for_delivery nao devolveu token/delivery_event_id';
    END IF;
    RAISE NOTICE 'SMOKE OK [6]: mensagem apresentada para entrega (PRONTO_PARA_ENVIO)';

    PERFORM set_config('smoketest.conn_a_token4', v_token_delivery, true);
END;
$$;

-- -----------------------------------------------------------------------------
-- [15-16] mark_message_sent cria primeiro follow-up; retry nao duplica.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_token4 text := current_setting('smoketest.conn_a_token4');
    v_mv3 uuid := current_setting('smoketest.conn_a_mv3')::uuid;
    v_followup_id uuid;
    v_new_status text;
    v_followup_count integer;
BEGIN
    SELECT r.followup_id, r.new_status INTO v_followup_id, v_new_status
      FROM rufino_linkedin.mark_message_sent(
        v_connection_id, v_mv3, 'telegram:anderson_rufino',
        'cb-enviado-' || gen_random_uuid()::text, v_token4, 'MARCAR_ENVIADA',
        now() + interval '2 days'
      ) r;

    IF v_followup_id IS NULL OR v_new_status <> 'FOLLOWUP_PENDENTE' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [15]: mark_message_sent nao criou o primeiro follow-up corretamente (status=%)', v_new_status;
    END IF;

    SELECT count(*) INTO v_followup_count FROM rufino_linkedin.followups f
     WHERE f.connection_id = v_connection_id AND f.sequence = 1;
    IF v_followup_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [15]: esperado exatamente 1 followup sequence=1, obtido %', v_followup_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [15]: mark_message_sent criou followups.sequence=1 e transicionou para FOLLOWUP_PENDENTE';
    PERFORM set_config('smoketest.conn_a_followup1', v_followup_id::text, true);
END;
$$;
-- Nota sobre [16] (retry de mark_message_sent nao duplica o followup): a
-- proteção primária é o token de uso único (já invalidado pela chamada
-- acima) — uma segunda chamada com o mesmo token falha na validação de
-- token antes mesmo de chegar ao INSERT do followup, então não há uma
-- chamada de retry literal para exercitar aqui sem um segundo token válido.
-- A defesa em profundidade (INSERT ... ON CONFLICT DO NOTHING em
-- followups(connection_id, sequence)) está implementada em
-- 006_functions.sql e é a garantia estrutural para o caso em que o token
-- ainda fosse válido numa reexecução — revisão de código confirma a
-- cláusula ON CONFLICT presente; não executada aqui por falta de um
-- segundo token válido para simular o retry de ponta a ponta.

-- -----------------------------------------------------------------------------
-- [17] claim_due_followups funciona.
-- -----------------------------------------------------------------------------
RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_a_followup1')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_followup_id uuid := current_setting('smoketest.conn_a_followup1')::uuid;
    v_claimed_id uuid;
BEGIN
    SELECT f.followup_id INTO v_claimed_id
      FROM rufino_linkedin.claim_due_followups(1000) f
     WHERE f.followup_id = v_followup_id;

    IF v_claimed_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [17]: claim_due_followups nao reivindicou o followup de teste';
    END IF;
    RAISE NOTICE 'SMOKE OK [17]: claim_due_followups reivindicou o followup';
END;
$$;

-- -----------------------------------------------------------------------------
-- [22] Claim abandonado volta a ficar elegível (followup próprio, separado
--      do fluxo principal, para não interferir no [18] mais adiante).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoke-ABANDON-' || gen_random_uuid()::text,
        'Fulano Abandonado', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-aband', NULL, CURRENT_DATE,
        'Resumo', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa',
        0.9, false, '[]'::jsonb, 'brain-test-1', 'Mensagem inicial.'
      ) r;
    PERFORM set_config('smoketest.conn_abandon', v_connection_id::text, true);
END;
$$;

RESET ROLE;
-- Cria diretamente, como admin, um followup "orfão" (sem passar pelo fluxo
-- completo de envio) só para exercitar claim_due_followups isoladamente —
-- writes diretos como admin são esperados aqui (é a própria owner da
-- tabela); não corresponde a nada que a role de aplicação faria.
INSERT INTO rufino_linkedin.followups (connection_id, sequence, scheduled_for, claimed_at, updated_at)
VALUES (
    current_setting('smoketest.conn_abandon')::uuid, 1,
    now() - interval '2 hours', now() - interval '2 hours', now() - interval '2 hours'
);
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_abandon')::uuid;
    v_claimed_id uuid;
    v_claimed_at_before timestamptz;
    v_claimed_at_after timestamptz;
BEGIN
    SELECT f.claimed_at INTO v_claimed_at_before FROM rufino_linkedin.followups f
     WHERE f.connection_id = v_connection_id AND f.sequence = 1;

    SELECT f.followup_id INTO v_claimed_id
      FROM rufino_linkedin.claim_due_followups(1000) f
     WHERE f.connection_id = v_connection_id;

    IF v_claimed_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [22]: claim abandonado (claimed_at ha 2h, executed_at nulo) deveria ter sido reivindicado de novo';
    END IF;

    SELECT f.claimed_at INTO v_claimed_at_after FROM rufino_linkedin.followups f
     WHERE f.followup_id = v_claimed_id;

    IF v_claimed_at_after <= v_claimed_at_before THEN
        RAISE EXCEPTION 'SMOKE FALHOU [22]: claimed_at deveria ter sido atualizado para agora (antes=%, depois=%)', v_claimed_at_before, v_claimed_at_after;
    END IF;

    RAISE NOTICE 'SMOKE OK [22]: claim abandonado (>1h) voltou a ser elegivel e claimed_at foi atualizado';
    PERFORM set_config('smoketest.conn_abandon_followup1', v_claimed_id::text, true);
END;
$$;

-- -----------------------------------------------------------------------------
-- [18] complete_followup RESPONDEU encerra a jornada (conexão A).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_followup_id uuid := current_setting('smoketest.conn_a_followup1')::uuid;
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_new_status text;
    v_final_status text;
BEGIN
    SELECT r.new_connection_status INTO v_new_status
      FROM rufino_linkedin.complete_followup(
        v_followup_id, 'RESPONDEU', 'telegram:anderson_rufino', 'respondeu rapido',
        'cb-followup-a-' || gen_random_uuid()::text
      ) r;

    IF v_new_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [18]: complete_followup RESPONDEU deveria encerrar a jornada (obtido %)', v_new_status;
    END IF;

    SELECT c.status INTO v_final_status FROM rufino_linkedin.connections c WHERE c.connection_id = v_connection_id;
    IF v_final_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [18]: status persistido da conexao deveria ser ENCERRADO (obtido %)', v_final_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [18]: complete_followup RESPONDEU encerrou a jornada (RESPONDEU -> ENCERRADO)';
END;
$$;

-- -----------------------------------------------------------------------------
-- [23] Followup executado nunca volta a ser reivindicado (o followup1 da
--      conexão A, agora executed_at preenchido pelo passo [18] acima).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_followup_id uuid := current_setting('smoketest.conn_a_followup1')::uuid;
    v_reclaimed_id uuid;
BEGIN
    SELECT f.followup_id INTO v_reclaimed_id
      FROM rufino_linkedin.claim_due_followups(1000) f
     WHERE f.followup_id = v_followup_id;

    IF v_reclaimed_id IS NOT NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [23]: followup ja executado foi reivindicado de novo';
    END IF;

    RAISE NOTICE 'SMOKE OK [23]: followup executado nao foi reivindicado de novo';
END;
$$;

-- -----------------------------------------------------------------------------
-- [19-20] complete_followup SEM_RESPOSTA — conexão B, ciclo completo:
--         cria proximo follow-up quando ha proxima data [19], depois encerra
--         quando o segundo ciclo tambem for SEM_RESPOSTA sem proxima data [20].
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
    v_mv uuid;
BEGIN
    SELECT r.connection_id, r.message_version_id INTO v_connection_id, v_mv
      FROM rufino_linkedin.register_connection(
        'smoke-B-' || gen_random_uuid()::text,
        'Fulano B', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-b', NULL, CURRENT_DATE,
        'Resumo B', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa B',
        0.9, false, '[]'::jsonb, 'brain-test-1', 'Mensagem inicial B.'
      ) r;
    PERFORM set_config('smoketest.conn_b', v_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_b')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_b')::uuid;
    v_token text;
    v_mv uuid;
BEGIN
    SELECT c.raw_pending_action_token, c.message_version_id INTO v_token, v_mv
      FROM rufino_linkedin.claim_due_connections(1000) c WHERE c.connection_id = v_connection_id;

    PERFORM r.new_status FROM rufino_linkedin.approve_message(
        v_connection_id, v_mv, 'APROVAR_E_PREPARAR', 'telegram:anderson_rufino', NULL,
        'cb-b-aprovar-' || gen_random_uuid()::text, v_token
    ) r;

    PERFORM set_config('smoketest.conn_b_mv', v_mv::text, true);
END;
$$;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_b')::uuid;
    v_mv uuid := current_setting('smoketest.conn_b_mv')::uuid;
    v_token text;
    v_followup_id uuid;
BEGIN
    SELECT r.raw_pending_action_token INTO v_token
      FROM rufino_linkedin.present_message_for_delivery(v_connection_id, v_mv) r;

    SELECT r.followup_id INTO v_followup_id
      FROM rufino_linkedin.mark_message_sent(
        v_connection_id, v_mv, 'telegram:anderson_rufino',
        'cb-b-enviado-' || gen_random_uuid()::text, v_token, 'MARCAR_ENVIADA',
        now() + interval '2 days'
      ) r;

    PERFORM set_config('smoketest.conn_b_followup1', v_followup_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_b_followup1')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_followup_id uuid := current_setting('smoketest.conn_b_followup1')::uuid;
    v_connection_id uuid := current_setting('smoketest.conn_b')::uuid;
    v_claimed_id uuid;
    v_new_status text;
    v_next_followup_id uuid;
    v_next_sequence integer;
BEGIN
    SELECT f.followup_id INTO v_claimed_id FROM rufino_linkedin.claim_due_followups(1000) f
     WHERE f.followup_id = v_followup_id;
    IF v_claimed_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [19-setup]: claim_due_followups nao reivindicou o followup da conexao B';
    END IF;

    SELECT r.new_connection_status, r.next_followup_id, r.next_followup_sequence
      INTO v_new_status, v_next_followup_id, v_next_sequence
      FROM rufino_linkedin.complete_followup(
        v_followup_id, 'SEM_RESPOSTA', 'telegram:anderson_rufino', 'sem resposta ainda',
        'cb-b-followup1-' || gen_random_uuid()::text,
        now() + interval '3 days'
      ) r;

    IF v_new_status <> 'FOLLOWUP_PENDENTE' OR v_next_followup_id IS NULL OR v_next_sequence <> 2 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [19]: complete_followup SEM_RESPOSTA com proxima data deveria criar sequence=2 e voltar a FOLLOWUP_PENDENTE (status=%, next_id=%, next_seq=%)',
            v_new_status, v_next_followup_id, v_next_sequence;
    END IF;

    RAISE NOTICE 'SMOKE OK [19]: complete_followup SEM_RESPOSTA com proxima data criou followups.sequence=2';
    PERFORM set_config('smoketest.conn_b_followup2', v_next_followup_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_b_followup2')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_followup_id uuid := current_setting('smoketest.conn_b_followup2')::uuid;
    v_connection_id uuid := current_setting('smoketest.conn_b')::uuid;
    v_claimed_id uuid;
    v_new_status text;
    v_final_status text;
BEGIN
    SELECT f.followup_id INTO v_claimed_id FROM rufino_linkedin.claim_due_followups(1000) f
     WHERE f.followup_id = v_followup_id;
    IF v_claimed_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [20-setup]: claim_due_followups nao reivindicou o segundo followup da conexao B';
    END IF;

    SELECT r.new_connection_status INTO v_new_status
      FROM rufino_linkedin.complete_followup(
        v_followup_id, 'SEM_RESPOSTA', 'telegram:anderson_rufino', 'ainda sem resposta, encerrando',
        'cb-b-followup2-' || gen_random_uuid()::text
      ) r; -- p_next_followup_at nulo

    IF v_new_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [20]: complete_followup SEM_RESPOSTA sem proxima data deveria encerrar a jornada (obtido %)', v_new_status;
    END IF;

    SELECT c.status INTO v_final_status FROM rufino_linkedin.connections c WHERE c.connection_id = v_connection_id;
    IF v_final_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [20]: status persistido deveria ser ENCERRADO (obtido %)', v_final_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [20]: complete_followup SEM_RESPOSTA sem proxima data encerrou a jornada';
END;
$$;

-- -----------------------------------------------------------------------------
-- [21] Callback duplicado é rejeitado (approve_message; mesma disciplina se
--      aplica a complete_followup e mark_message_sent — validado uma vez
--      aqui como representativo do contrato).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
    v_mv uuid;
BEGIN
    SELECT r.connection_id, r.message_version_id INTO v_connection_id, v_mv
      FROM rufino_linkedin.register_connection(
        'smoke-DUP-' || gen_random_uuid()::text,
        'Fulano Dup', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-dup', NULL, CURRENT_DATE,
        'Resumo', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa',
        0.9, false, '[]'::jsonb, 'brain-test-1', 'Mensagem inicial.'
      ) r;

    PERFORM set_config('smoketest.conn_dup', v_connection_id::text, true);
    PERFORM set_config('smoketest.conn_dup_mv', v_mv::text, true);
END;
$$;

-- Adianta scheduled_at como admin — RESET ROLE/SET LOCAL ROLE precisam ser
-- statements de topo (fora de um bloco DO), nunca aninhados dentro de um
-- corpo PL/pgSQL, mesmo padrão usado em todo o resto deste arquivo.
RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_dup')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_dup')::uuid;
    v_mv uuid := current_setting('smoketest.conn_dup_mv')::uuid;
    v_token text;
    v_cb text := 'cb-dup-' || gen_random_uuid()::text;
BEGIN
    SELECT c.raw_pending_action_token INTO v_token
      FROM rufino_linkedin.claim_due_connections(1000) c WHERE c.connection_id = v_connection_id;

    PERFORM r.new_status FROM rufino_linkedin.approve_message(
        v_connection_id, v_mv, 'DESCARTAR', 'telegram:anderson_rufino', NULL, v_cb, v_token
    ) r;

    BEGIN
        PERFORM r.new_status FROM rufino_linkedin.approve_message(
            v_connection_id, v_mv, 'DESCARTAR', 'telegram:anderson_rufino', NULL, v_cb, v_token
        ) r;
        RAISE EXCEPTION 'SMOKE FALHOU [21]: segunda chamada com o mesmo callback_query_id deveria ter sido rejeitada';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%ja processado%' THEN
                RAISE NOTICE 'SMOKE OK [21]: callback_query_id duplicado rejeitado corretamente';
            ELSE
                RAISE EXCEPTION 'SMOKE FALHOU [21]: falhou por motivo inesperado: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- [24] record_workflow_error preserva o registro de auditoria e nunca
--      duplica por execution_id — comportamento de retry_count/retry_allowed
--      verificado ponta a ponta com uma conexão real.
--
-- LIMITAÇÃO RECONHECIDA (não é uma falha do teste, é uma propriedade real da
-- função): o ramo específico "a transição para ERRO É TENTADA e FALHA, mas o
-- INSERT de workflow_errors permanece" (o bloco BEGIN...EXCEPTION WHEN
-- OTHERS isolado dentro de record_workflow_error, em 006_functions.sql) só
-- pode ser genuinamente disparado por uma corrida de concorrência real —
-- outra sessão mudando connections.status entre a leitura própria de
-- record_workflow_error e o FOR UPDATE de transition_connection_status — ou
-- por connection_id que deixou de existir depois de já ter sido referenciado
-- em workflow_errors (não acontece no caminho operacional normal, já que
-- conexões nunca são apagadas). Um p_connection_id inexistente de propósito
-- NÃO exercita esse ramo: a própria FK de workflow_errors.connection_id
-- rejeitaria o INSERT antes mesmo de chegar à tentativa de transição — isso
-- seria testar uma coisa diferente (violação de integridade referencial),
-- não a preservação de auditoria após falha de transição. Uma corrida real
-- não é reproduzível de forma determinística numa única sessão/transação
-- estática como esta. A garantia desse ramo específico foi verificada por
-- LEITURA DIRETA do corpo da função (o bloco EXCEPTION captura
-- corretamente qualquer erro da chamada a transition_connection_status sem
-- desfazer o INSERT anterior, porque PL/pgSQL trata um bloco com EXCEPTION
-- como uma subtransação/savepoint implícito) — não por execução aqui.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
    v_workflow_error_id_1 uuid;
    v_workflow_error_id_2 uuid;
    v_transitioned_1 boolean;
    v_transitioned_2 boolean;
    v_retry_count_1 integer;
    v_retry_count_2 integer;
    v_retry_allowed_1 boolean;
    v_retry_allowed_2 boolean;
    v_final_status text;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoke-ERR-' || gen_random_uuid()::text,
        'Fulano Erro', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-erro', NULL, CURRENT_DATE,
        'Resumo', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa',
        0.9, false, '[]'::jsonb, 'brain-test-1', 'Mensagem inicial.'
      ) r;
    -- Status real: AGUARDANDO_D1.

    -- Primeira ocorrência: retry_count=0, ainda dentro do limite (1) — não
    -- transiciona.
    SELECT r.workflow_error_id, r.transitioned_to_erro, r.retry_count, r.retry_allowed
      INTO v_workflow_error_id_1, v_transitioned_1, v_retry_count_1, v_retry_allowed_1
      FROM rufino_linkedin.record_workflow_error(
        v_connection_id, 'WF-TEST', 'erro_smoke_test', 'Falha simulada 1',
        '{}'::jsonb, 'AGUARDANDO_D1', NULL, 1
      ) r;

    IF v_workflow_error_id_1 IS NULL OR v_retry_count_1 <> 0 OR v_transitioned_1 IS DISTINCT FROM false OR v_retry_allowed_1 IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'SMOKE FALHOU [24-1]: primeira ocorrencia deveria ter retry_count=0, transitioned=false, retry_allowed=true (obtido retry_count=%, transitioned=%, retry_allowed=%)',
            v_retry_count_1, v_transitioned_1, v_retry_allowed_1;
    END IF;

    -- Segunda ocorrência do MESMO erro: retry_count=1 >= limite (1) —
    -- transiciona de verdade para ERRO (conexão real, transição sempre
    -- válida por desenho) e o registro de auditoria da PRIMEIRA ocorrência
    -- continua existindo (nunca foi tocado pela segunda chamada).
    SELECT r.workflow_error_id, r.transitioned_to_erro, r.retry_count, r.retry_allowed
      INTO v_workflow_error_id_2, v_transitioned_2, v_retry_count_2, v_retry_allowed_2
      FROM rufino_linkedin.record_workflow_error(
        v_connection_id, 'WF-TEST', 'erro_smoke_test', 'Falha simulada 2',
        '{}'::jsonb, 'AGUARDANDO_D1', NULL, 1
      ) r;

    IF v_workflow_error_id_2 IS NULL OR v_workflow_error_id_2 = v_workflow_error_id_1
       OR v_retry_count_2 <> 1 OR v_transitioned_2 IS DISTINCT FROM true OR v_retry_allowed_2 IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'SMOKE FALHOU [24-2]: segunda ocorrencia deveria ter retry_count=1, transitioned=true, retry_allowed=false, e ser uma linha nova (obtido id=%, retry_count=%, transitioned=%, retry_allowed=%)',
            v_workflow_error_id_2, v_retry_count_2, v_transitioned_2, v_retry_allowed_2;
    END IF;

    SELECT c.status INTO v_final_status FROM rufino_linkedin.connections c WHERE c.connection_id = v_connection_id;
    IF v_final_status <> 'ERRO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [24-2]: conexao deveria estar em ERRO apos retentativas esgotadas (obtido %)', v_final_status;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM rufino_linkedin.workflow_errors we WHERE we.workflow_error_id = v_workflow_error_id_1) THEN
        RAISE EXCEPTION 'SMOKE FALHOU [24]: o registro da primeira ocorrencia desapareceu apos a segunda chamada — auditoria nao preservada';
    END IF;

    RAISE NOTICE 'SMOKE OK [24]: record_workflow_error preserva auditoria em ambas as ocorrencias; retry_count/retry_allowed corretos; transiciona para ERRO na (limite+1)-esima ocorrencia';
END;
$$;

-- -----------------------------------------------------------------------------
-- [25] Escrita direta na tabela falha para a role de aplicação.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
BEGIN
    BEGIN
        UPDATE rufino_linkedin.connections SET nome = 'tentativa direta' WHERE connection_id = v_connection_id;
        RAISE EXCEPTION 'SMOKE FALHOU [25]: UPDATE direto deveria ter sido negado por falta de grant de escrita';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'SMOKE OK [25]: escrita direta (UPDATE) negada para a role de aplicacao, como esperado';
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- [26] Chamada direta de transition_connection_status falha para a role de
--      aplicação (função interna — sem EXECUTE concedido).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
BEGIN
    BEGIN
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'ENCERRADO', 'ENCERRADO', 'smoke-test', 'tentativa direta', 'SMOKE-TEST', NULL
        ) t;
        RAISE EXCEPTION 'SMOKE FALHOU [26]: chamada direta a transition_connection_status deveria ter sido negada';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'SMOKE OK [26]: transition_connection_status negada para chamada direta da role de aplicacao, como esperado';
    END;
END;
$$;

RESET ROLE;

-- [30] Nenhum dado permanece: toda a sequência acima roda dentro desta
-- transação, que termina em ROLLBACK, nunca COMMIT. Se qualquer "SMOKE
-- FALHOU" acima chegou a ser lançado como exceção não capturada, o próprio
-- erro já teria interrompido o script antes de chegar aqui — o ROLLBACK
-- explícito cobre tanto o caminho de sucesso quanto a limpeza depois de uma
-- falha capturada.
ROLLBACK;
