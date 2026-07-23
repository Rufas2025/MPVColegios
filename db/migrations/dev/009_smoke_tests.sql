-- =============================================================================
-- 009_smoke_tests.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — patch v1.4.1, item 9
--
-- Smoke test rápido para rodar manualmente logo depois de aplicar
-- 001–007/008, ANTES de qualquer uso real da migration. Roda inteiro
-- dentro de BEGIN...ROLLBACK — nunca commita, então nenhuma linha criada
-- aqui permanece no banco ao final, mesmo se todos os testes passarem.
--
-- Pré-requisito de quem executa: uma credencial administrativa capaz de
-- `SET LOCAL ROLE n8n_rufino_linkedin_dev` (ex.: a mesma conexão usada para
-- aplicar 001–008) — não a própria credencial do n8n. O script alterna
-- entre a role de aplicação (para provar o que o n8n consegue fazer) e a
-- sessão administrativa (só para preparar um pré-requisito de teste que a
-- role de aplicação não tem permissão de fazer sozinha, como adiantar um
-- scheduled_at).
--
-- Assume um banco praticamente vazio (recém-migrado) — o passo 2 usa
-- claim_due_connections com um limite alto (1000) para garantir que a
-- conexão de teste seja reivindicada mesmo que existam outras linhas
-- elegíveis; como tudo roda dentro do ROLLBACK final, qualquer efeito sobre
-- linhas reais que por acaso já existissem também é desfeito.
--
-- O que este script prova, nesta ordem:
--   1. register_connection funciona para a role de aplicação e cria a
--      mensagem inicial (message_versions, version=1, source='gpt').
--   2. As funções SECURITY DEFINER conseguem chamar extensions.digest /
--      extensions.gen_random_bytes e gravar nas tabelas (via
--      claim_due_connections -> transition_connection_status).
--   3. Escrita direta numa tabela falha para a role de aplicação.
--   4. Chamada direta de transition_connection_status falha para a role de
--      aplicação (função interna, sem EXECUTE concedido).
-- =============================================================================

BEGIN;

SET LOCAL ROLE n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- 1) register_connection funciona e cria a mensagem inicial.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id       uuid;
    v_status              text;
    v_scheduled_at        timestamptz;
    v_message_version_id  uuid;
    v_already             boolean;
    v_mv_count            integer;
    v_mv_version          integer;
    v_mv_source           text;
BEGIN
    SELECT r.connection_id, r.status, r.scheduled_at, r.message_version_id, r.already_existed
      INTO v_connection_id, v_status, v_scheduled_at, v_message_version_id, v_already
      FROM rufino_linkedin.register_connection(
        'smoke-test-' || gen_random_uuid()::text,
        'Fulano de Tal', 'Fulano', 'Coordenador', 'Escola Teste', 'São Paulo',
        'https://linkedin.com/in/fulano-teste', NULL, CURRENT_DATE,
        'Resumo de teste', '["gancho1"]'::jsonb, 'gancho1', 'Justificativa de teste',
        0.9, false, '[]'::jsonb, 'brain-test-1',
        'Mensagem inicial de teste, gerada pelo GPT.'
      ) r;

    IF v_connection_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU (1): register_connection nao retornou connection_id';
    END IF;
    IF v_status <> 'AGUARDANDO_D1' THEN
        RAISE EXCEPTION 'SMOKE FALHOU (1): status esperado AGUARDANDO_D1, obtido %', v_status;
    END IF;
    IF v_message_version_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU (1): register_connection nao retornou message_version_id';
    END IF;
    IF v_already IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'SMOKE FALHOU (1): already_existed deveria ser false numa conexao nova';
    END IF;

    SELECT count(*), max(version) INTO v_mv_count, v_mv_version
      FROM rufino_linkedin.message_versions mv WHERE mv.connection_id = v_connection_id;

    IF v_mv_count <> 1 OR v_mv_version <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU (1): esperada exatamente 1 message_version, versao 1; obtido count=%, version=%', v_mv_count, v_mv_version;
    END IF;

    SELECT mv.source INTO v_mv_source FROM rufino_linkedin.message_versions mv WHERE mv.message_version_id = v_message_version_id;
    IF v_mv_source <> 'gpt' THEN
        RAISE EXCEPTION 'SMOKE FALHOU (1): source esperado gpt, obtido %', v_mv_source;
    END IF;

    RAISE NOTICE 'SMOKE OK (1): register_connection cria connection + analysis + message_version 1 (source=gpt), como a role de aplicacao';

    -- Guarda o connection_id numa GUC de sessão (escopo desta transação) para
    -- os passos seguintes lerem — variáveis PL/pgSQL não sobrevivem ao fim
    -- de um bloco DO, mas set_config(..., true) com is_local=true sim,
    -- dentro da mesma transação.
    PERFORM set_config('smoketest.connection_id', v_connection_id::text, true);
END;
$$;

-- -----------------------------------------------------------------------------
-- 2) SECURITY DEFINER acessa pgcrypto e tabelas: adianta o scheduled_at (como
--    sessão administrativa, só para o teste poder reivindicar agora) e
--    confirma que claim_due_connections + transition_connection_status
--    geram e persistem o token via extensions.gen_random_bytes/digest.
-- -----------------------------------------------------------------------------
RESET ROLE;

UPDATE rufino_linkedin.connections
   SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.connection_id')::uuid;

SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.connection_id')::uuid;
    v_token         text;
    v_hash          text;
BEGIN
    SELECT c.raw_pending_action_token INTO v_token
      FROM rufino_linkedin.claim_due_connections(1000) c
     WHERE c.connection_id = v_connection_id;

    IF v_token IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU (2): claim_due_connections nao devolveu raw_pending_action_token para a conexao de teste (pgcrypto inacessivel dentro da SECURITY DEFINER, ou conexao nao reivindicada)';
    END IF;

    SELECT c.pending_action_token_hash INTO v_hash
      FROM rufino_linkedin.connections c WHERE c.connection_id = v_connection_id;

    IF v_hash IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU (2): pending_action_token_hash nao foi persistido na tabela';
    END IF;

    RAISE NOTICE 'SMOKE OK (2): claim_due_connections + transition_connection_status geraram e persistiram o token via extensions.gen_random_bytes/extensions.digest, mesmo a role de aplicacao nao tendo acesso direto ao schema extensions';
END;
$$;

-- -----------------------------------------------------------------------------
-- 3) Escrita direta na tabela falha para a role de aplicação (sem
--    INSERT/UPDATE/DELETE fora de função).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.connection_id')::uuid;
BEGIN
    BEGIN
        UPDATE rufino_linkedin.connections SET nome = 'tentativa direta' WHERE connection_id = v_connection_id;
        RAISE EXCEPTION 'SMOKE FALHOU (3): UPDATE direto deveria ter sido negado por falta de grant de escrita';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'SMOKE OK (3): escrita direta (UPDATE) negada para a role de aplicacao, como esperado';
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) Chamada direta de transition_connection_status falha para a role de
--    aplicação (função interna desde a v1.4.1 — sem EXECUTE concedido).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.connection_id')::uuid;
BEGIN
    BEGIN
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'AGUARDANDO_APROVACAO', 'APROVADO', 'smoke-test', 'tentativa direta', 'SMOKE-TEST', NULL
        ) t;
        RAISE EXCEPTION 'SMOKE FALHOU (4): chamada direta a transition_connection_status deveria ter sido negada (funcao interna, sem EXECUTE para a role de aplicacao)';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'SMOKE OK (4): transition_connection_status negada para chamada direta da role de aplicacao, como esperado';
    END;
END;
$$;

RESET ROLE;

-- Nenhum dado permanece: toda a sequência acima roda dentro desta
-- transação, que termina em ROLLBACK, nunca COMMIT. Se qualquer "SMOKE
-- FALHOU" acima chegou a ser lançado como exceção não capturada, o próprio
-- erro já teria interrompido o script antes de chegar aqui — o ROLLBACK
-- explícito cobre tanto o caminho de sucesso quanto a limpeza depois de uma
-- falha capturada.
ROLLBACK;
