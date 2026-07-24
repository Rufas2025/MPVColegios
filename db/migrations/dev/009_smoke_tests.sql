-- =============================================================================
-- 009_smoke_tests.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.0
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 009_smoke_tests.sql
--
-- Roda inteiro dentro de BEGIN...ROLLBACK — NUNCA COMMIT. Todo dado criado
-- aqui desaparece ao final, mesmo em caso de falha (o próprio erro já
-- interrompe o script antes do ROLLBACK explícito, mas a transação nunca
-- commitada garante que nada persiste de qualquer jeito).
--
-- Regras de isolamento (Seção 11 da rodada v1.5.0):
--   - Registros de teste sempre identificáveis por idempotency_key com
--     prefixo "smoketest-v150-<cenario>" — nunca reaproveita dado real.
--   - Nenhum limite arbitrário como 1000: claim_due_connections/
--     claim_due_followups/claim_notification_jobs são sempre chamados com
--     limit=1 ou limit=5 (o mínimo suficiente para o cenário), nunca um
--     número grande "só para garantir".
--   - Cada claim confirma explicitamente que o registro devolvido é o
--     criado pelo próprio teste (por idempotency_key/connection_id
--     conhecido), nunca assume que "o primeiro da fila" é o certo.
--   - Ordenação com desempate determinístico (scheduled_at+connection_id,
--     scheduled_for+followup_id, created_at+notification_job_id) — já
--     garantido pelo SQL de 006_functions.sql, os testes aqui confirmam
--     que o registro certo volta mesmo quando há mais de um elegível.
--
-- Uso de SET LOCAL ROLE: alterna entre a role administrativa (que aplicou
-- 001-007) e n8n_rufino_linkedin_dev (a role de aplicação real) para
-- provar que o comportamento de segurança/negócio vale de fato para quem
-- vai rodar isso em produção, não só para quem tem privilégio total.
-- SET LOCAL ROLE/RESET ROLE são sempre statements de nível superior, nunca
-- dentro de um bloco DO — não é sintaxe válida ali.
--
-- "Não declarar que os smoke tests foram executados" além do que
-- realmente rodou nesta sessão: ver TEST-REPORT.md para o registro da
-- execução real contra PostgreSQL 16.13 descartável (não 17 — indisponível
-- neste ambiente, ver TEST-REPORT.md seção "Desvio de ambiente").
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- [PRE] Confirma, ainda como role administrativa e antes de qualquer SET
--       LOCAL ROLE, que nenhuma das 15 funções tem EXECUTE para PUBLIC.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_count integer;
BEGIN
    SELECT count(*) INTO v_count
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rufino_linkedin'
       AND has_function_privilege('public', p.oid, 'EXECUTE');

    IF v_count <> 0 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [PRE-1]: % funcao(oes) com EXECUTE para PUBLIC (esperado 0)', v_count;
    END IF;

    SELECT count(*) INTO v_count
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rufino_linkedin';

    IF v_count <> 15 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [PRE-2]: esperado 15 funcoes em rufino_linkedin, encontrado %', v_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [PRE]: 15 funcoes existem, 0 com EXECUTE para PUBLIC';
END;
$$;

-- -----------------------------------------------------------------------------
-- [PRE-2] Confirma que a role de aplicacao nao e membro da owner, e nao tem
--         privilegio administrativo -- checado antes de assumir a role, para
--         nao depender de nada que a propria role pudesse mascarar.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_is_member boolean;
    v_rolsuper boolean;
    v_rolbypassrls boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_auth_members m
          JOIN pg_roles r_member ON r_member.oid = m.member
          JOIN pg_roles r_role ON r_role.oid = m.roleid
         WHERE r_member.rolname = 'n8n_rufino_linkedin_dev'
           AND r_role.rolname = 'n8n_rufino_linkedin_owner_dev'
    ) INTO v_is_member;

    SELECT rolsuper, rolbypassrls INTO v_rolsuper, v_rolbypassrls
      FROM pg_roles WHERE rolname = 'n8n_rufino_linkedin_dev';

    IF v_is_member OR v_rolsuper OR v_rolbypassrls THEN
        RAISE EXCEPTION 'SMOKE FALHOU [PRE-2]: role de aplicacao com privilegio indevido (membro_owner=%, rolsuper=%, rolbypassrls=%)',
            v_is_member, v_rolsuper, v_rolbypassrls;
    END IF;

    RAISE NOTICE 'SMOKE OK [PRE-2]: role de aplicacao sem privilegio administrativo, sem membership na owner';
END;
$$;

SET LOCAL ROLE n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- [1] register_connection cria connection + analysis + message_versions v1.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
    v_status text;
    v_message_version_id uuid;
    v_already_existed boolean;
    v_analysis_count integer;
    v_mv_count integer;
BEGIN
    SELECT r.connection_id, r.status, r.message_version_id, r.already_existed
      INTO v_connection_id, v_status, v_message_version_id, v_already_existed
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-a', 'Fulano de Tal', 'Fulano', 'Coordenador', 'Escola Alpha', 'São Paulo',
        'https://linkedin.com/in/fulano-v150', NULL, CURRENT_DATE,
        'Resumo do perfil', '["networking"]'::jsonb, 'networking', 'Boa justificativa',
        0.85, false, '[]'::jsonb, 'brain-test-v150', 'Ola Fulano, prazer em conectar.'
      ) r;

    IF v_connection_id IS NULL OR v_status <> 'AGUARDANDO_D1' OR v_message_version_id IS NULL OR v_already_existed <> false THEN
        RAISE EXCEPTION 'SMOKE FALHOU [1]: register_connection nao retornou o esperado (status=%, mv=%, already_existed=%)',
            v_status, v_message_version_id, v_already_existed;
    END IF;

    SELECT count(*) INTO v_analysis_count FROM rufino_linkedin.analyses WHERE connection_id = v_connection_id;
    SELECT count(*) INTO v_mv_count FROM rufino_linkedin.message_versions
     WHERE connection_id = v_connection_id AND version = 1 AND source = 'gpt';

    IF v_analysis_count <> 1 OR v_mv_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [1]: esperado 1 analysis e 1 message_version v1/gpt, obtido analyses=% mv=%',
            v_analysis_count, v_mv_count;
    END IF;

    PERFORM set_config('smoketest.conn_a', v_connection_id::text, true);
    PERFORM set_config('smoketest.conn_a_mv1', v_message_version_id::text, true);
    RAISE NOTICE 'SMOKE OK [1]: register_connection cria connection+analysis+message_version v1 corretamente';
END;
$$;

-- -----------------------------------------------------------------------------
-- [2] Retry com a mesma idempotency_key retorna already_existed=true, sem
--     duplicar nenhuma linha.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_retry_connection_id uuid;
    v_already_existed boolean;
    v_conn_count integer;
    v_mv_count integer;
BEGIN
    SELECT r.connection_id, r.already_existed INTO v_retry_connection_id, v_already_existed
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-a', 'Fulano de Tal', 'Fulano', 'Coordenador', 'Escola Alpha', 'São Paulo',
        'https://linkedin.com/in/fulano-v150', NULL, CURRENT_DATE,
        'Resumo diferente no retry', '["outro"]'::jsonb, 'outro', 'Outra justificativa',
        0.5, true, '["tema"]'::jsonb, 'brain-test-v150-retry', 'Mensagem diferente no retry'
      ) r;

    IF v_retry_connection_id <> v_connection_id OR v_already_existed <> true THEN
        RAISE EXCEPTION 'SMOKE FALHOU [2]: retry deveria devolver a mesma connection_id (%) com already_existed=true (obtido %, %)',
            v_connection_id, v_retry_connection_id, v_already_existed;
    END IF;

    SELECT count(*) INTO v_conn_count FROM rufino_linkedin.connections WHERE idempotency_key = 'smoketest-v150-conn-a';
    SELECT count(*) INTO v_mv_count FROM rufino_linkedin.message_versions WHERE connection_id = v_connection_id;

    IF v_conn_count <> 1 OR v_mv_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [2]: retry duplicou registro (connections=%, message_versions=%)', v_conn_count, v_mv_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [2]: retry de register_connection idempotente, sem duplicar nada';
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_a')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- [3] claim_due_connections (limit=1) reivindica exatamente a conexao de
--     teste, transiciona para AGUARDANDO_APROVACAO, e cria o job de
--     notificacao APPROVAL correspondente.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_claimed_id uuid;
    v_status text;
    v_job_count integer;
BEGIN
    SELECT c.connection_id, c.status INTO v_claimed_id, v_status
      FROM rufino_linkedin.claim_due_connections(1) c;

    IF v_claimed_id IS DISTINCT FROM v_connection_id OR v_status <> 'AGUARDANDO_APROVACAO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [3]: claim_due_connections deveria reivindicar % (obtido % com status %)',
            v_connection_id, v_claimed_id, v_status;
    END IF;

    SELECT count(*) INTO v_job_count FROM rufino_linkedin.notification_jobs
     WHERE connection_id = v_connection_id AND job_type = 'APPROVAL' AND status = 'PENDING';

    IF v_job_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [3]: esperado 1 notification_job APPROVAL PENDING, obtido %', v_job_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [3]: claim_due_connections reivindica a conexao certa e cria o job de notificacao APPROVAL';
END;
$$;

-- -----------------------------------------------------------------------------
-- [4] claim_notification_jobs (limit=1) reivindica o job criado no item 3,
--     emite o action_token e o claim_token na hora (nunca antes), e o
--     callback_data compacto formado com o token cabe em 64 bytes para
--     todos os prefixos previstos (aprovacao/entrega e follow-up).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_job_id uuid;
    v_job_type text;
    v_raw_action text;
    v_raw_claim text;
    v_len integer;
    v_prefix text;
BEGIN
    SELECT nj.notification_job_id, nj.job_type, nj.raw_action_token, nj.raw_claim_token
      INTO v_job_id, v_job_type, v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj
     WHERE nj.connection_id = v_connection_id;

    IF v_job_id IS NULL OR v_job_type <> 'APPROVAL' OR v_raw_action IS NULL OR v_raw_claim IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [4]: claim_notification_jobs nao reivindicou o job esperado (job_id=%, job_type=%)', v_job_id, v_job_type;
    END IF;

    IF length(v_raw_action) <> 48 OR v_raw_action !~ '^[0-9a-f]{48}$' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [4]: raw_action_token deveria ter 48 chars hex minusculo, obtido "%" (% chars)', v_raw_action, length(v_raw_action);
    END IF;

    -- Todos os prefixos de callback_data previstos (aprovacao/entrega:
    -- a:A a:E a:R a:D a:S a:B; follow-up: f:R f:N) cabem em 64 bytes com
    -- um token de 48 chars hex.
    FOREACH v_prefix IN ARRAY ARRAY['a:A:', 'a:E:', 'a:R:', 'a:D:', 'a:S:', 'a:B:', 'f:R:', 'f:N:']
    LOOP
        v_len := octet_length(v_prefix || v_raw_action);
        IF v_len > 64 THEN
            RAISE EXCEPTION 'SMOKE FALHOU [4]: callback_data "%<token>" tem % bytes, excede o limite de 64 do Telegram', v_prefix, v_len;
        END IF;
    END LOOP;

    PERFORM set_config('smoketest.conn_a_job1', v_job_id::text, true);
    PERFORM set_config('smoketest.conn_a_action_token1', v_raw_action, true);
    PERFORM set_config('smoketest.conn_a_claim_token1', v_raw_claim, true);
    RAISE NOTICE 'SMOKE OK [4]: claim_notification_jobs emite token de 48 chars hex; callback_data compacto <= 64 bytes em todos os prefixos previstos (medido: % bytes)', v_len;
END;
$$;

-- -----------------------------------------------------------------------------
-- [5] confirm_notification_delivery registra a entrega (chat/message id,
--     delivered_at) e marca o job como DELIVERED.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_job_id uuid := current_setting('smoketest.conn_a_job1')::uuid;
    v_claim_token text := current_setting('smoketest.conn_a_claim_token1');
    v_confirmed_id uuid;
    v_delivered_at timestamptz;
    v_status text;
BEGIN
    SELECT r.notification_job_id, r.delivered_at INTO v_confirmed_id, v_delivered_at
      FROM rufino_linkedin.confirm_notification_delivery(v_claim_token, 'chat-smoketest', 'msg-smoketest-1') r;

    IF v_confirmed_id <> v_job_id OR v_delivered_at IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [5]: confirm_notification_delivery nao confirmou o job esperado';
    END IF;

    SELECT status INTO v_status FROM rufino_linkedin.notification_jobs WHERE notification_job_id = v_job_id;
    IF v_status <> 'DELIVERED' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [5]: job deveria estar DELIVERED, obtido %', v_status;
    END IF;

    PERFORM set_config('smoketest.conn_a_delivered_at1', v_delivered_at::text, true);
    RAISE NOTICE 'SMOKE OK [5]: confirm_notification_delivery marca o job como DELIVERED corretamente';
END;
$$;

-- -----------------------------------------------------------------------------
-- [6] Confirmar de novo com o MESMO claim_token depois de ja entregue e um
--     no-op idempotente -- devolve o delivered_at ja registrado, nao falha
--     e nao reprocessa.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_job_id uuid := current_setting('smoketest.conn_a_job1')::uuid;
    v_claim_token text := current_setting('smoketest.conn_a_claim_token1');
    v_original_delivered_at timestamptz := current_setting('smoketest.conn_a_delivered_at1')::timestamptz;
    v_confirmed_id uuid;
    v_delivered_at timestamptz;
BEGIN
    SELECT r.notification_job_id, r.delivered_at INTO v_confirmed_id, v_delivered_at
      FROM rufino_linkedin.confirm_notification_delivery(v_claim_token, 'chat-outro', 'msg-outro') r;

    IF v_confirmed_id <> v_job_id OR v_delivered_at <> v_original_delivered_at THEN
        RAISE EXCEPTION 'SMOKE FALHOU [6]: retry de confirm_notification_delivery deveria ser idempotente (delivered_at original % obtido %)',
            v_original_delivered_at, v_delivered_at;
    END IF;

    RAISE NOTICE 'SMOKE OK [6]: retry de confirm_notification_delivery apos entrega e idempotente (no-op seguro)';
END;
$$;

-- -----------------------------------------------------------------------------
-- [7] approve_message (APROVAR_E_PREPARAR) consome o action_token e
--     transiciona AGUARDANDO_APROVACAO -> APROVADO.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_action_token text := current_setting('smoketest.conn_a_action_token1');
    v_approval_id uuid;
    v_new_status text;
    v_status_real text;
BEGIN
    SELECT r.approval_id, r.new_status INTO v_approval_id, v_new_status
      FROM rufino_linkedin.approve_message(v_action_token, 'APROVAR_E_PREPARAR', 'telegram:anderson', 'smoketest-cbq-approve-a') r;

    IF v_approval_id IS NULL OR v_new_status <> 'APROVADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [7]: approve_message deveria transicionar para APROVADO (obtido %)', v_new_status;
    END IF;

    SELECT status INTO v_status_real FROM rufino_linkedin.connections WHERE connection_id = v_connection_id;
    IF v_status_real <> 'APROVADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [7]: status real da conexao deveria ser APROVADO, obtido %', v_status_real;
    END IF;

    PERFORM set_config('smoketest.conn_a_approval1', v_approval_id::text, true);
    RAISE NOTICE 'SMOKE OK [7]: approve_message (APROVAR_E_PREPARAR) consome o token e transiciona para APROVADO';
END;
$$;

-- -----------------------------------------------------------------------------
-- [8] Retry do MESMO callback_query_id com o MESMO conteudo devolve o
--     resultado ja persistido (mesmo approval_id) -- idempotente mesmo com
--     o action_token ja consumido pela primeira chamada.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_action_token text := current_setting('smoketest.conn_a_action_token1');
    v_original_approval_id uuid := current_setting('smoketest.conn_a_approval1')::uuid;
    v_approval_id uuid;
    v_new_status text;
    v_approvals_count integer;
BEGIN
    SELECT r.approval_id, r.new_status INTO v_approval_id, v_new_status
      FROM rufino_linkedin.approve_message(v_action_token, 'APROVAR_E_PREPARAR', 'telegram:anderson', 'smoketest-cbq-approve-a') r;

    IF v_approval_id <> v_original_approval_id OR v_new_status <> 'APROVADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [8]: retry deveria devolver o mesmo approval_id % (obtido %)', v_original_approval_id, v_approval_id;
    END IF;

    SELECT count(*) INTO v_approvals_count FROM rufino_linkedin.approvals WHERE approval_id = v_original_approval_id;
    IF v_approvals_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [8]: retry duplicou a linha de approvals (contagem=%)', v_approvals_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [8]: retry de approve_message com mesmo callback_query_id e mesmo conteudo e idempotente, mesmo com token ja consumido';
END;
$$;

-- -----------------------------------------------------------------------------
-- [9] Retry do MESMO callback_query_id com conteudo DIFERENTE (decisao
--     diferente) falha claramente como conflito -- nunca sobrescreve.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_action_token text := current_setting('smoketest.conn_a_action_token1');
    v_failed boolean := false;
BEGIN
    BEGIN
        PERFORM r.approval_id FROM rufino_linkedin.approve_message(v_action_token, 'DESCARTAR', 'telegram:anderson', 'smoketest-cbq-approve-a') r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%conteudo diferente%' THEN
            v_failed := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_failed THEN
        RAISE EXCEPTION 'SMOKE FALHOU [9]: callback_query_id repetido com conteudo diferente deveria ter sido rejeitado como conflito';
    END IF;

    RAISE NOTICE 'SMOKE OK [9]: callback_query_id repetido com conteudo diferente e rejeitado como conflito, nunca sobrescreve';
END;
$$;

-- -----------------------------------------------------------------------------
-- [10] Um action_token diferente, ja consumido de fato (nao so via
--      receipt), apresentado com um callback_query_id NOVO, e rejeitado
--      como "ja consumido" -- prova que a invalidacao de uso unico do
--      token e real, independente do mecanismo de recibo.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_action_token text := current_setting('smoketest.conn_a_action_token1');
    v_failed boolean := false;
BEGIN
    BEGIN
        PERFORM r.approval_id FROM rufino_linkedin.approve_message(v_action_token, 'APROVAR_E_PREPARAR', 'telegram:anderson', 'smoketest-cbq-approve-a-novo') r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%consumido%' THEN
            v_failed := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_failed THEN
        RAISE EXCEPTION 'SMOKE FALHOU [10]: action_token ja consumido, apresentado com um callback_query_id novo, deveria ser rejeitado';
    END IF;

    RAISE NOTICE 'SMOKE OK [10]: action_token consumido e rejeitado mesmo com callback_query_id novo (uso unico real, nao so idempotencia por recibo)';
END;
$$;

-- -----------------------------------------------------------------------------
-- [11] present_message_for_delivery rejeita versao obsoleta, aceita a
--      vigente, e cria o job de notificacao DELIVERY.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_mv1 uuid := current_setting('smoketest.conn_a_mv1')::uuid;
    v_failed boolean := false;
    v_status text;
    v_job_count integer;
BEGIN
    -- v_mv1 e a unica versao ate agora, entao ela E a vigente aqui -- para
    -- provar a rejeicao de obsoleta, usamos um uuid aleatorio que nao
    -- corresponde a nenhuma versao real.
    BEGIN
        PERFORM r.status FROM rufino_linkedin.present_message_for_delivery(v_connection_id, gen_random_uuid()) r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%nao e a versao vigente%' THEN
            v_failed := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_failed THEN
        RAISE EXCEPTION 'SMOKE FALHOU [11]: present_message_for_delivery deveria rejeitar message_version_id que nao e a vigente';
    END IF;

    SELECT r.status INTO v_status FROM rufino_linkedin.present_message_for_delivery(v_connection_id, v_mv1) r;
    IF v_status <> 'PRONTO_PARA_ENVIO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [11]: present_message_for_delivery deveria transicionar para PRONTO_PARA_ENVIO (obtido %)', v_status;
    END IF;

    SELECT count(*) INTO v_job_count FROM rufino_linkedin.notification_jobs
     WHERE connection_id = v_connection_id AND job_type = 'DELIVERY' AND status = 'PENDING';
    IF v_job_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [11]: esperado 1 notification_job DELIVERY PENDING, obtido %', v_job_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [11]: present_message_for_delivery rejeita versao obsoleta, aceita a vigente, cria job DELIVERY';
END;
$$;

-- -----------------------------------------------------------------------------
-- [12] Ciclo completo de entrega: claim_notification_jobs (DELIVERY) ->
--      confirm_notification_delivery -> mark_message_sent (MARCAR_ENVIADA)
--      exige p_first_followup_at futuro, cria followups.sequence=1, e
--      transiciona ENVIADO -> FOLLOWUP_PENDENTE na mesma chamada.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_job_id uuid;
    v_raw_action text;
    v_raw_claim text;
    v_delivery_event_id uuid;
    v_new_status text;
    v_followup_id uuid;
    v_failed boolean := false;
    v_followup_count integer;
BEGIN
    SELECT nj.notification_job_id, nj.raw_action_token, nj.raw_claim_token
      INTO v_job_id, v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj
     WHERE nj.connection_id = v_connection_id AND nj.job_type = 'DELIVERY';

    IF v_job_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [12]: claim_notification_jobs nao reivindicou o job DELIVERY esperado';
    END IF;

    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-smoketest', 'msg-smoketest-2') r;

    -- p_first_followup_at ausente deve ser rejeitado quando MARCAR_ENVIADA.
    BEGIN
        PERFORM r.new_status FROM rufino_linkedin.mark_message_sent(v_raw_action, 'MARCAR_ENVIADA', 'telegram:anderson', 'smoketest-cbq-sent-sem-data') r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%obrigatorio%' THEN
            v_failed := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'SMOKE FALHOU [12]: mark_message_sent(MARCAR_ENVIADA) sem p_first_followup_at deveria ter sido rejeitado';
    END IF;

    SELECT r.delivery_event_id, r.new_status, r.followup_id
      INTO v_delivery_event_id, v_new_status, v_followup_id
      FROM rufino_linkedin.mark_message_sent(v_raw_action, 'MARCAR_ENVIADA', 'telegram:anderson', 'smoketest-cbq-sent-a', now() + interval '2 days') r;

    IF v_delivery_event_id IS NULL OR v_new_status <> 'FOLLOWUP_PENDENTE' OR v_followup_id IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [12]: mark_message_sent(MARCAR_ENVIADA) nao completou o ciclo esperado (status=%)', v_new_status;
    END IF;

    SELECT count(*) INTO v_followup_count FROM rufino_linkedin.followups WHERE connection_id = v_connection_id AND sequence = 1;
    IF v_followup_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [12]: esperado exatamente 1 followup sequence=1, obtido %', v_followup_count;
    END IF;

    PERFORM set_config('smoketest.conn_a_followup1', v_followup_id::text, true);
    PERFORM set_config('smoketest.conn_a_delivery_action_token', v_raw_action, true);
    RAISE NOTICE 'SMOKE OK [12]: ciclo de entrega completo -- mark_message_sent cria followups.sequence=1 e transiciona para FOLLOWUP_PENDENTE';
END;
$$;

-- -----------------------------------------------------------------------------
-- [13] Retry do MESMO callback_query_id (mesmo action_token, mesma acao,
--      mesma data) de mark_message_sent e idempotente -- devolve o mesmo
--      followup_id, sem duplicar delivery_events nem followups.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_original_followup uuid := current_setting('smoketest.conn_a_followup1')::uuid;
    v_followup_id uuid;
    v_followup_count integer;
    v_delivery_events_count integer;
BEGIN
    -- Mesmo action_token, mesma acao, mesma data e mesmo callback_query_id
    -- do item 12 (retry real: o n8n reenvia o mesmo payload) -- o token ja
    -- foi consumido, mas o recibo de callback_query_id e checado ANTES do
    -- token, entao o retry funciona mesmo assim.
    SELECT r.followup_id INTO v_followup_id
      FROM rufino_linkedin.mark_message_sent(
        current_setting('smoketest.conn_a_delivery_action_token'),
        'MARCAR_ENVIADA', 'telegram:anderson', 'smoketest-cbq-sent-a', now() + interval '2 days'
      ) r;

    IF v_followup_id <> v_original_followup THEN
        RAISE EXCEPTION 'SMOKE FALHOU [13]: retry de mark_message_sent deveria devolver o mesmo followup_id % (obtido %)',
            v_original_followup, v_followup_id;
    END IF;

    SELECT count(*) INTO v_followup_count FROM rufino_linkedin.followups WHERE connection_id = v_connection_id AND sequence = 1;
    SELECT count(*) INTO v_delivery_events_count FROM rufino_linkedin.delivery_events WHERE connection_id = v_connection_id AND event_type = 'MARCADO_COMO_ENVIADO';

    IF v_followup_count <> 1 OR v_delivery_events_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [13]: retry duplicou registros (followups=%, delivery_events=%)', v_followup_count, v_delivery_events_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [13]: retry de mark_message_sent e idempotente mesmo com o action_token original ja consumido';
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_a_followup1')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- [14] claim_due_followups (limit=1) reivindica exatamente o followup de
--      teste e gera um claim_token de 48 chars hex.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_followup_id uuid := current_setting('smoketest.conn_a_followup1')::uuid;
    v_claimed_id uuid;
    v_raw_claim text;
BEGIN
    SELECT f.followup_id, f.raw_claim_token INTO v_claimed_id, v_raw_claim
      FROM rufino_linkedin.claim_due_followups(1) f;

    IF v_claimed_id IS DISTINCT FROM v_followup_id THEN
        RAISE EXCEPTION 'SMOKE FALHOU [14]: claim_due_followups deveria reivindicar % (obtido %)', v_followup_id, v_claimed_id;
    END IF;

    IF length(v_raw_claim) <> 48 OR v_raw_claim !~ '^[0-9a-f]{48}$' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [14]: claim_token deveria ter 48 chars hex minusculo, obtido "%"', v_raw_claim;
    END IF;

    PERFORM set_config('smoketest.conn_a_followup1_claim', v_raw_claim, true);
    RAISE NOTICE 'SMOKE OK [14]: claim_due_followups reivindica o followup certo e gera claim_token de 48 chars hex';
END;
$$;

-- -----------------------------------------------------------------------------
-- [15] complete_followup RESPONDEU encerra a jornada
--      (FOLLOWUP_PENDENTE -> RESPONDEU -> ENCERRADO), sem criar novo
--      follow-up.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_claim_token text := current_setting('smoketest.conn_a_followup1_claim');
    v_new_status text;
    v_final_status text;
BEGIN
    SELECT r.new_connection_status INTO v_new_status
      FROM rufino_linkedin.complete_followup(v_claim_token, 'RESPONDEU', 'telegram:anderson', 'smoketest-cbq-followup-a') r;

    IF v_new_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [15]: complete_followup(RESPONDEU) deveria encerrar a jornada (obtido %)', v_new_status;
    END IF;

    SELECT status INTO v_final_status FROM rufino_linkedin.connections WHERE connection_id = v_connection_id;
    IF v_final_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [15]: status real deveria ser ENCERRADO, obtido %', v_final_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [15]: complete_followup(RESPONDEU) encerra a jornada corretamente';
END;
$$;

-- -----------------------------------------------------------------------------
-- [16] Retry do MESMO callback_query_id de complete_followup e idempotente
--      -- devolve o mesmo resultado, mesmo com o claim_token ja invalidado
--      pela primeira chamada (claim_token_hash e zerado ao completar).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_new_status text;
BEGIN
    SELECT r.new_connection_status INTO v_new_status
      FROM rufino_linkedin.complete_followup(
        current_setting('smoketest.conn_a_followup1_claim'), 'RESPONDEU', 'telegram:anderson', 'smoketest-cbq-followup-a'
      ) r;

    IF v_new_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [16]: retry de complete_followup deveria devolver ENCERRADO (obtido %)', v_new_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [16]: retry de complete_followup e idempotente mesmo com o claim_token ja invalidado';
END;
$$;

-- -----------------------------------------------------------------------------
-- [17]/[18] Ciclo completo SEM_RESPOSTA: primeiro SEM_RESPOSTA com
--      p_next_followup_at cria o proximo followup (sequence+1) e volta a
--      FOLLOWUP_PENDENTE; segundo SEM_RESPOSTA sem p_next_followup_at
--      encerra a jornada. Tudo numa unica conexao de teste (conn_b),
--      registrada e conduzida neste mesmo bloco.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
    v_mv1 uuid;
    v_raw_action text;
    v_raw_claim text;
    v_new_status text;
    v_followup1 uuid;
    v_followup2 uuid;
    v_next_seq integer;
BEGIN
    SELECT r.connection_id, r.message_version_id INTO v_connection_id, v_mv1
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-b', 'Ciclano Teste', 'Ciclano', 'Diretor', 'Escola Beta', 'Rio de Janeiro',
        'https://linkedin.com/in/ciclano-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial conn_b'
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
    v_claimed_id uuid;
    v_raw_action text;
    v_raw_claim text;
    v_new_status text;
    v_followup1 uuid;
    v_followup2 uuid;
    v_next_seq integer;
    v_mv1 uuid;
BEGIN
    SELECT c.connection_id INTO v_claimed_id FROM rufino_linkedin.claim_due_connections(1) c;
    IF v_claimed_id IS DISTINCT FROM v_connection_id THEN
        RAISE EXCEPTION 'SMOKE FALHOU [17]: claim_due_connections nao reivindicou conn_b (obtido %)', v_claimed_id;
    END IF;

    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-b', 'msg-b1') r;
    PERFORM r.new_status FROM rufino_linkedin.approve_message(v_raw_action, 'APROVAR_E_PREPARAR', 'telegram:anderson', 'smoketest-cbq-approve-b') r;

    SELECT mv.message_version_id INTO v_mv1 FROM rufino_linkedin.message_versions mv WHERE mv.connection_id = v_connection_id ORDER BY mv.version DESC LIMIT 1;
    PERFORM r.status FROM rufino_linkedin.present_message_for_delivery(v_connection_id, v_mv1) r;

    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id AND nj.job_type = 'DELIVERY';
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-b', 'msg-b2') r;

    SELECT r.followup_id INTO v_followup1
      FROM rufino_linkedin.mark_message_sent(v_raw_action, 'MARCAR_ENVIADA', 'telegram:anderson', 'smoketest-cbq-sent-b', now() + interval '2 days') r;

    PERFORM set_config('smoketest.conn_b_followup1', v_followup1::text, true);
    RAISE NOTICE 'SMOKE OK [17-prep]: conn_b conduzida ate FOLLOWUP_PENDENTE com followup1=%', v_followup1;
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_b_followup1')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_b')::uuid;
    v_followup1 uuid := current_setting('smoketest.conn_b_followup1')::uuid;
    v_claimed_id uuid;
    v_claim_token text;
    v_new_status text;
    v_followup2 uuid;
    v_next_seq integer;
BEGIN
    SELECT f.followup_id, f.raw_claim_token INTO v_claimed_id, v_claim_token FROM rufino_linkedin.claim_due_followups(1) f;
    IF v_claimed_id IS DISTINCT FROM v_followup1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [17]: claim_due_followups nao reivindicou o followup1 de conn_b';
    END IF;

    SELECT r.new_connection_status, r.next_followup_id, r.next_followup_sequence
      INTO v_new_status, v_followup2, v_next_seq
      FROM rufino_linkedin.complete_followup(v_claim_token, 'SEM_RESPOSTA', 'anderson', 'smoketest-cbq-followup-b1', NULL, now() + interval '3 days') r;

    IF v_new_status <> 'FOLLOWUP_PENDENTE' OR v_followup2 IS NULL OR v_next_seq <> 2 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [17]: SEM_RESPOSTA com proxima data deveria criar sequence=2 e voltar a FOLLOWUP_PENDENTE (status=%, next_seq=%)', v_new_status, v_next_seq;
    END IF;

    PERFORM set_config('smoketest.conn_b_followup2', v_followup2::text, true);
    RAISE NOTICE 'SMOKE OK [17]: complete_followup(SEM_RESPOSTA, com proxima data) cria followup sequence=2 e volta a FOLLOWUP_PENDENTE';
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_b_followup2')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_b')::uuid;
    v_followup2 uuid := current_setting('smoketest.conn_b_followup2')::uuid;
    v_claimed_id uuid;
    v_claim_token text;
    v_new_status text;
    v_final_status text;
BEGIN
    SELECT f.followup_id, f.raw_claim_token INTO v_claimed_id, v_claim_token FROM rufino_linkedin.claim_due_followups(1) f;
    IF v_claimed_id IS DISTINCT FROM v_followup2 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [18]: claim_due_followups nao reivindicou o followup2 de conn_b';
    END IF;

    SELECT r.new_connection_status INTO v_new_status
      FROM rufino_linkedin.complete_followup(v_claim_token, 'SEM_RESPOSTA', 'anderson', 'smoketest-cbq-followup-b2') r;

    IF v_new_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [18]: SEM_RESPOSTA sem proxima data deveria encerrar a jornada (obtido %)', v_new_status;
    END IF;

    SELECT status INTO v_final_status FROM rufino_linkedin.connections WHERE connection_id = v_connection_id;
    IF v_final_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [18]: status real deveria ser ENCERRADO, obtido %', v_final_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [18]: complete_followup(SEM_RESPOSTA, sem proxima data) encerra a jornada corretamente';
END;
$$;

-- -----------------------------------------------------------------------------
-- [19]/[20] Reclaim de follow-up: um claim abandonado (claim_expires_at no
--      passado, simulando worker que caiu) e reivindicado de novo por
--      outro worker, com um NOVO claim_token -- o antigo passa a ser
--      rejeitado. O followup ja executado, por sua vez, nunca volta a ser
--      reivindicavel.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-reclaim-f', 'Reclaim Followup', 'Reclaim', 'Diretor', 'Escola Gama', 'BH',
        'https://linkedin.com/in/reclaim-f-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial reclaim-f'
      ) r;
    PERFORM set_config('smoketest.conn_rf', v_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_rf')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_rf')::uuid;
    v_raw_action text;
    v_raw_claim text;
    v_mv1 uuid;
    v_followup1 uuid;
BEGIN
    PERFORM c.connection_id FROM rufino_linkedin.claim_due_connections(1) c;
    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-rf', 'msg-rf1') r;
    PERFORM r.new_status FROM rufino_linkedin.approve_message(v_raw_action, 'APROVAR_E_PREPARAR', 'telegram:anderson', 'smoketest-cbq-approve-rf') r;

    SELECT mv.message_version_id INTO v_mv1 FROM rufino_linkedin.message_versions mv WHERE mv.connection_id = v_connection_id ORDER BY mv.version DESC LIMIT 1;
    PERFORM r.status FROM rufino_linkedin.present_message_for_delivery(v_connection_id, v_mv1) r;

    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id AND nj.job_type = 'DELIVERY';
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-rf', 'msg-rf2') r;

    SELECT r.followup_id INTO v_followup1
      FROM rufino_linkedin.mark_message_sent(v_raw_action, 'MARCAR_ENVIADA', 'telegram:anderson', 'smoketest-cbq-sent-rf', now() + interval '2 days') r;

    PERFORM set_config('smoketest.conn_rf_followup1', v_followup1::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_rf_followup1')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_followup1 uuid := current_setting('smoketest.conn_rf_followup1')::uuid;
    v_claimed_id uuid;
    v_claim_token_a text;
BEGIN
    -- Worker A reivindica.
    SELECT f.followup_id, f.raw_claim_token INTO v_claimed_id, v_claim_token_a FROM rufino_linkedin.claim_due_followups(1) f;
    IF v_claimed_id IS DISTINCT FROM v_followup1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [19]: claim_due_followups nao reivindicou o followup de reclaim';
    END IF;
    PERFORM set_config('smoketest.conn_rf_worker_a_token', v_claim_token_a, true);
END;
$$;

-- Simula o worker A caindo: forca o claim a parecer expirado.
RESET ROLE;
UPDATE rufino_linkedin.followups SET claim_expires_at = now() - interval '1 minute'
 WHERE followup_id = current_setting('smoketest.conn_rf_followup1')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_followup1 uuid := current_setting('smoketest.conn_rf_followup1')::uuid;
    v_claimed_id uuid;
    v_claim_token_b text;
    v_stale_rejected boolean := false;
    v_new_status text;
BEGIN
    -- Worker B reivindica de novo (reclaim) -- mesmo followup_id, novo token.
    SELECT f.followup_id, f.raw_claim_token INTO v_claimed_id, v_claim_token_b FROM rufino_linkedin.claim_due_followups(1) f;
    IF v_claimed_id IS DISTINCT FROM v_followup1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [19]: reclaim nao reivindicou o mesmo followup_id esperado';
    END IF;

    -- Worker A (token antigo) tenta concluir -- deve falhar.
    BEGIN
        PERFORM r.followup_id FROM rufino_linkedin.complete_followup(
            current_setting('smoketest.conn_rf_worker_a_token'), 'RESPONDEU', 'anderson', 'smoketest-cbq-followup-rf-stale'
        ) r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%invalido%' THEN
            v_stale_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_stale_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [19]: worker A (token antigo, apos reclaim) deveria ter sido rejeitado';
    END IF;

    -- Worker B (token novo) conclui com sucesso.
    SELECT r.new_connection_status INTO v_new_status
      FROM rufino_linkedin.complete_followup(v_claim_token_b, 'RESPONDEU', 'anderson', 'smoketest-cbq-followup-rf-fresh') r;
    IF v_new_status <> 'ENCERRADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [19]: worker B (token novo) deveria concluir com sucesso (obtido %)', v_new_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [19]: reclaim de follow-up rotaciona o token; worker antigo rejeitado, worker novo conclui com sucesso';
END;
$$;

-- -----------------------------------------------------------------------------
-- [20] O followup ja executado nunca volta a ser reivindicado, mesmo que
--      seu claim (agora nulo) fosse reavaliado -- claim_due_followups
--      filtra executed_at IS NULL incondicionalmente.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_followup1 uuid := current_setting('smoketest.conn_rf_followup1')::uuid;
    v_reclaimed_count integer;
BEGIN
    SELECT count(*) INTO v_reclaimed_count FROM rufino_linkedin.claim_due_followups(5) f WHERE f.followup_id = v_followup1;
    IF v_reclaimed_count <> 0 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [20]: followup ja executado foi reivindicado de novo (nao deveria)';
    END IF;

    RAISE NOTICE 'SMOKE OK [20]: followup executado nunca e reivindicado de novo por claim_due_followups';
END;
$$;

-- -----------------------------------------------------------------------------
-- [21] Reclaim de notification job: um claim expirado (worker que caiu
--      antes de confirmar) e reivindicado de novo -- job_id igual, mas
--      claim_token E action_token NOVOS (o action_token antigo e
--      invalidado por issue_action_token ao ser reemitido). Worker antigo
--      falha tanto ao confirmar quanto ao usar o action_token antigo.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-reclaim-n', 'Reclaim Notif', 'Reclaim', 'Diretor', 'Escola Delta', 'BH',
        'https://linkedin.com/in/reclaim-n-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial reclaim-n'
      ) r;
    PERFORM set_config('smoketest.conn_rn', v_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_rn')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_rn')::uuid;
    v_job_id uuid;
    v_claim_a text;
    v_action_a text;
BEGIN
    PERFORM c.connection_id FROM rufino_linkedin.claim_due_connections(1) c;

    SELECT nj.notification_job_id, nj.raw_claim_token, nj.raw_action_token
      INTO v_job_id, v_claim_a, v_action_a
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;

    PERFORM set_config('smoketest.conn_rn_job', v_job_id::text, true);
    PERFORM set_config('smoketest.conn_rn_worker_a_claim', v_claim_a, true);
    PERFORM set_config('smoketest.conn_rn_worker_a_action', v_action_a, true);
END;
$$;

-- Simula o worker A caindo antes de confirmar: forca o claim a expirar.
RESET ROLE;
UPDATE rufino_linkedin.notification_jobs SET claim_expires_at = now() - interval '1 minute'
 WHERE notification_job_id = current_setting('smoketest.conn_rn_job')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_job_id uuid := current_setting('smoketest.conn_rn_job')::uuid;
    v_claimed_id uuid;
    v_claim_b text;
    v_action_b text;
    v_rejected boolean := false;
BEGIN
    -- Worker B reivindica de novo -- mesmo job_id, tokens novos.
    SELECT nj.notification_job_id, nj.raw_claim_token, nj.raw_action_token
      INTO v_claimed_id, v_claim_b, v_action_b
      FROM rufino_linkedin.claim_notification_jobs(1) nj;

    IF v_claimed_id IS DISTINCT FROM v_job_id THEN
        RAISE EXCEPTION 'SMOKE FALHOU [21]: reclaim de notification job nao reivindicou o mesmo job_id esperado';
    END IF;

    -- Worker A (claim_token antigo) tenta confirmar -- deve falhar.
    v_rejected := false;
    BEGIN
        PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(
            current_setting('smoketest.conn_rn_worker_a_claim'), 'chat-stale', 'msg-stale'
        ) r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%invalido%' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [21]: worker A (claim_token antigo, apos reclaim) deveria ter sido rejeitado ao confirmar';
    END IF;

    -- Worker A (action_token antigo) tenta aprovar -- deve falhar (foi
    -- invalidado quando o novo action_token foi emitido no reclaim).
    v_rejected := false;
    BEGIN
        PERFORM r.approval_id FROM rufino_linkedin.approve_message(
            current_setting('smoketest.conn_rn_worker_a_action'), 'APROVAR_E_PREPARAR', 'telegram:anderson', 'smoketest-cbq-approve-rn-stale'
        ) r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%invalido%' OR SQLERRM LIKE '%consumido%' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [21]: worker A (action_token antigo, apos reclaim) deveria ter sido rejeitado';
    END IF;

    -- Worker B (tokens novos) confirma e aprova com sucesso.
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_claim_b, 'chat-fresh', 'msg-fresh') r;
    PERFORM r.approval_id FROM rufino_linkedin.approve_message(v_action_b, 'DESCARTAR', 'telegram:anderson', 'smoketest-cbq-approve-rn-fresh') r;

    RAISE NOTICE 'SMOKE OK [21]: reclaim de notification job rotaciona claim_token e action_token; worker antigo rejeitado nos dois, worker novo funciona nos dois';
END;
$$;

-- -----------------------------------------------------------------------------
-- [22] Fluxo EDITAR: approve_message(EDITAR) nao transiciona, emite
--      edit_token; save_message_edit cria version=2/human_edit e cria um
--      novo job de notificacao APPROVAL.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
    v_raw_action text;
    v_raw_claim text;
    v_raw_edit text;
    v_status_after_edit_decision text;
    v_mv_id uuid;
    v_version integer;
    v_job_count integer;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-edit', 'Editar Teste', 'Editar', 'Diretor', 'Escola Epsilon', 'Curitiba',
        'https://linkedin.com/in/editar-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial editar'
      ) r;
    PERFORM set_config('smoketest.conn_edit', v_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_edit')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_edit')::uuid;
    v_raw_action text;
    v_raw_claim text;
    v_raw_edit text;
    v_status_after text;
    v_mv_id uuid;
    v_version integer;
    v_job_count integer;
BEGIN
    PERFORM c.connection_id FROM rufino_linkedin.claim_due_connections(1) c;
    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-edit', 'msg-edit') r;

    SELECT r.new_status, r.raw_edit_token INTO v_status_after, v_raw_edit
      FROM rufino_linkedin.approve_message(v_raw_action, 'EDITAR', 'telegram:anderson', 'smoketest-cbq-editar') r;

    IF v_status_after <> 'AGUARDANDO_APROVACAO' OR v_raw_edit IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [22]: approve_message(EDITAR) deveria manter AGUARDANDO_APROVACAO e emitir edit_token (status=%, token=%)', v_status_after, v_raw_edit;
    END IF;

    SELECT r.connection_id, r.message_version_id, r.version INTO v_connection_id, v_mv_id, v_version
      FROM rufino_linkedin.save_message_edit(v_raw_edit, 'Mensagem editada manualmente por Anderson.', 'anderson') r;

    IF v_version <> 2 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [22]: save_message_edit deveria criar version=2 (obtido %)', v_version;
    END IF;

    SELECT count(*) INTO v_job_count FROM rufino_linkedin.notification_jobs
     WHERE connection_id = v_connection_id AND job_type = 'APPROVAL' AND status = 'PENDING' AND message_version_id = v_mv_id;
    IF v_job_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [22]: save_message_edit deveria criar 1 novo job APPROVAL PENDING para a versao 2 (obtido %)', v_job_count;
    END IF;

    -- Drena o job recem-criado (so reivindica, sem processar mais nada) --
    -- isolamento do teste (Secao 11): nenhum job PENDING deste teste pode
    -- ficar na fila compartilhada para interferir na ordenacao por
    -- created_at de claim_notification_jobs em testes seguintes.
    PERFORM nj.notification_job_id FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;

    RAISE NOTICE 'SMOKE OK [22]: fluxo EDITAR completo -- approve_message emite edit_token, save_message_edit cria version=2 e novo job APPROVAL';
END;
$$;

-- -----------------------------------------------------------------------------
-- [23]-[26] Fluxo REFAZER: approve_message(REFAZER) emite
--      regeneration_token; save_regenerated_message cria version gpt e
--      novo job APPROVAL; token de regeneracao e de uso unico; token
--      expirado e rejeitado; status diferente de REFAZER e rejeitado.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-refazer', 'Refazer Teste', 'Refazer', 'Diretor', 'Escola Zeta', 'Porto Alegre',
        'https://linkedin.com/in/refazer-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial refazer'
      ) r;
    PERFORM set_config('smoketest.conn_refazer', v_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_refazer')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_refazer')::uuid;
    v_raw_action text;
    v_raw_claim text;
    v_raw_regen text;
    v_status_after text;
    v_mv_id uuid;
    v_version integer;
    v_job_count integer;
    v_rejected boolean;
BEGIN
    PERFORM c.connection_id FROM rufino_linkedin.claim_due_connections(1) c;
    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-refazer', 'msg-refazer') r;

    SELECT r.new_status, r.raw_regeneration_token INTO v_status_after, v_raw_regen
      FROM rufino_linkedin.approve_message(v_raw_action, 'REFAZER', 'telegram:anderson', 'smoketest-cbq-refazer') r;

    IF v_status_after <> 'REFAZER' OR v_raw_regen IS NULL THEN
        RAISE EXCEPTION 'SMOKE FALHOU [23]: approve_message(REFAZER) deveria transicionar para REFAZER e emitir regeneration_token (status=%)', v_status_after;
    END IF;

    -- [24] Status diferente de REFAZER e rejeitado: tentamos consumir com a
    -- conexao ainda no meio (aqui ja esta REFAZER, entao testamos a
    -- validacao inversa depois de sair de REFAZER, no final deste bloco).

    SELECT r.connection_id, r.message_version_id, r.version INTO v_connection_id, v_mv_id, v_version
      FROM rufino_linkedin.save_regenerated_message(v_raw_regen, 'Nova versao gerada pelo GPT.', 'gpt') r;

    IF v_version <> 2 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [23]: save_regenerated_message deveria criar version=2 (obtido %)', v_version;
    END IF;

    SELECT count(*) INTO v_job_count FROM rufino_linkedin.notification_jobs
     WHERE connection_id = v_connection_id AND job_type = 'APPROVAL' AND status = 'PENDING' AND message_version_id = v_mv_id;
    IF v_job_count <> 1 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [23]: save_regenerated_message deveria criar 1 novo job APPROVAL PENDING (obtido %)', v_job_count;
    END IF;

    -- Drena o job recem-criado -- mesma disciplina de isolamento do item 22.
    PERFORM nj.notification_job_id FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;

    -- [24] regeneration_token e de uso unico: reusar o mesmo token bruto
    -- agora deve falhar (ja foi zerado por save_regenerated_message).
    v_rejected := false;
    BEGIN
        PERFORM r.connection_id FROM rufino_linkedin.save_regenerated_message(v_raw_regen, 'Outra tentativa.', 'gpt') r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%invalido, expirado ou ja consumido%' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [24]: reuso do regeneration_token deveria ter sido rejeitado (uso unico)';
    END IF;

    RAISE NOTICE 'SMOKE OK [23]: fluxo REFAZER completo -- regeneration_token emitido, save_regenerated_message cria nova versao e novo job APPROVAL';
    RAISE NOTICE 'SMOKE OK [24]: regeneration_token e de uso unico -- reuso rejeitado';
END;
$$;

-- -----------------------------------------------------------------------------
-- [25] regeneration_token expirado e rejeitado mesmo com hash correto.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-regen-exp', 'Regen Expirado', 'Regen', 'Diretor', 'Escola Eta', 'Recife',
        'https://linkedin.com/in/regen-exp-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial regen-exp'
      ) r;
    PERFORM set_config('smoketest.conn_regen_exp', v_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_regen_exp')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_regen_exp')::uuid;
    v_raw_action text;
    v_raw_claim text;
    v_raw_regen text;
BEGIN
    PERFORM c.connection_id FROM rufino_linkedin.claim_due_connections(1) c;
    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-re', 'msg-re') r;

    SELECT r.raw_regeneration_token INTO v_raw_regen
      FROM rufino_linkedin.approve_message(v_raw_action, 'REFAZER', 'telegram:anderson', 'smoketest-cbq-refazer-exp') r;

    PERFORM set_config('smoketest.conn_regen_exp_token', v_raw_regen, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET pending_regeneration_token_expires_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_regen_exp')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    BEGIN
        PERFORM r.connection_id FROM rufino_linkedin.save_regenerated_message(
            current_setting('smoketest.conn_regen_exp_token'), 'Tentativa com token expirado.', 'gpt'
        ) r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%invalido, expirado ou ja consumido%' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [25]: regeneration_token expirado deveria ter sido rejeitado';
    END IF;

    RAISE NOTICE 'SMOKE OK [25]: regeneration_token expirado e rejeitado mesmo com hash correto';
END;
$$;

-- -----------------------------------------------------------------------------
-- [26] save_regenerated_message rejeita quando o status atual nao e
--      REFAZER, mesmo com um token de hash valido e nao expirado --
--      cenario forjado administrativamente (nao alcancavel pelo fluxo
--      normal, mas a validacao de defesa em profundidade precisa existir).
-- -----------------------------------------------------------------------------
RESET ROLE;
DO $$
DECLARE
    v_connection_id uuid;
    v_raw_token text;
    v_hash text;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-wrongstatus', 'Status Errado', 'Status', 'Diretor', 'Escola Theta', 'Salvador',
        'https://linkedin.com/in/wrongstatus-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial status-errado'
      ) r;

    v_raw_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_hash := encode(extensions.digest(v_raw_token, 'sha256'), 'hex');

    UPDATE rufino_linkedin.connections
       SET pending_regeneration_token_hash = v_hash,
           pending_regeneration_token_expires_at = now() + interval '1 day'
     WHERE connection_id = v_connection_id;
    -- status permanece NOVO/AGUARDANDO_D1 -- nunca REFAZER.

    PERFORM set_config('smoketest.conn_wrongstatus_token', v_raw_token, true);
END;
$$;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    BEGIN
        PERFORM r.connection_id FROM rufino_linkedin.save_regenerated_message(
            current_setting('smoketest.conn_wrongstatus_token'), 'Nao deveria funcionar.', 'gpt'
        ) r;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%esperado "REFAZER"%' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [26]: save_regenerated_message deveria rejeitar quando o status atual nao e REFAZER';
    END IF;

    RAISE NOTICE 'SMOKE OK [26]: save_regenerated_message rejeita corretamente quando o status atual nao e REFAZER';
END;
$$;

-- -----------------------------------------------------------------------------
-- [27] Decisao DESCARTAR transiciona para o estado terminal DESCARTADO.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-discard', 'Descartar Teste', 'Descartar', 'Diretor', 'Escola Iota', 'Fortaleza',
        'https://linkedin.com/in/discard-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial descartar'
      ) r;
    PERFORM set_config('smoketest.conn_discard', v_connection_id::text, true);
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE connection_id = current_setting('smoketest.conn_discard')::uuid;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_discard')::uuid;
    v_raw_action text;
    v_raw_claim text;
    v_new_status text;
    v_final_status text;
BEGIN
    PERFORM c.connection_id FROM rufino_linkedin.claim_due_connections(1) c;
    SELECT nj.raw_action_token, nj.raw_claim_token INTO v_raw_action, v_raw_claim
      FROM rufino_linkedin.claim_notification_jobs(1) nj WHERE nj.connection_id = v_connection_id;
    PERFORM r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(v_raw_claim, 'chat-desc', 'msg-desc') r;

    SELECT r.new_status INTO v_new_status
      FROM rufino_linkedin.approve_message(v_raw_action, 'DESCARTAR', 'telegram:anderson', 'smoketest-cbq-descartar') r;

    IF v_new_status <> 'DESCARTADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [27]: approve_message(DESCARTAR) deveria transicionar para DESCARTADO (obtido %)', v_new_status;
    END IF;

    SELECT status INTO v_final_status FROM rufino_linkedin.connections WHERE connection_id = v_connection_id;
    IF v_final_status <> 'DESCARTADO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [27]: status real deveria ser DESCARTADO, obtido %', v_final_status;
    END IF;

    RAISE NOTICE 'SMOKE OK [27]: approve_message(DESCARTAR) transiciona para o estado terminal DESCARTADO';
END;
$$;

-- -----------------------------------------------------------------------------
-- [28] record_workflow_error: primeira ocorrencia grava retry_count=0,
--      nao transiciona (ainda dentro do limite); segunda ocorrencia com
--      execution_id diferente esgota o limite (retry_limit=1), transiciona
--      para ERRO, e a linha da PRIMEIRA ocorrencia continua existindo
--      (auditoria nunca perdida).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid;
    v_id1 uuid;
    v_id2 uuid;
    v_rc1 integer;
    v_rc2 integer;
    v_transitioned1 boolean;
    v_transitioned2 boolean;
    v_retry_allowed1 boolean;
    v_retry_allowed2 boolean;
    v_final_status text;
BEGIN
    SELECT r.connection_id INTO v_connection_id
      FROM rufino_linkedin.register_connection(
        'smoketest-v150-conn-err', 'Erro Teste', 'Erro', 'Diretor', 'Escola Kappa', 'Manaus',
        'https://linkedin.com/in/erro-v150', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-v150', 'Mensagem inicial erro'
      ) r;

    SELECT r.workflow_error_id, r.retry_count, r.transitioned_to_erro, r.retry_allowed
      INTO v_id1, v_rc1, v_transitioned1, v_retry_allowed1
      FROM rufino_linkedin.record_workflow_error(
        v_connection_id, 'WF-SMOKETEST', 'erro_smoke_v150', 'Falha simulada 1', '{}'::jsonb, 'AGUARDANDO_D1', NULL, 1, 'smoketest-exec-1'
      ) r;

    IF v_rc1 <> 0 OR v_transitioned1 <> false OR v_retry_allowed1 <> true THEN
        RAISE EXCEPTION 'SMOKE FALHOU [28]: primeira ocorrencia deveria ter retry_count=0, transitioned=false, retry_allowed=true (obtido %,%,%)',
            v_rc1, v_transitioned1, v_retry_allowed1;
    END IF;

    SELECT r.workflow_error_id, r.retry_count, r.transitioned_to_erro, r.retry_allowed
      INTO v_id2, v_rc2, v_transitioned2, v_retry_allowed2
      FROM rufino_linkedin.record_workflow_error(
        v_connection_id, 'WF-SMOKETEST', 'erro_smoke_v150', 'Falha simulada 2', '{}'::jsonb, 'AGUARDANDO_D1', NULL, 1, 'smoketest-exec-2'
      ) r;

    IF v_id2 = v_id1 OR v_rc2 <> 1 OR v_transitioned2 <> true OR v_retry_allowed2 <> false THEN
        RAISE EXCEPTION 'SMOKE FALHOU [28]: segunda ocorrencia deveria ter retry_count=1, transitioned=true, retry_allowed=false, id diferente (obtido id=%,%,%,%)',
            v_id2, v_rc2, v_transitioned2, v_retry_allowed2;
    END IF;

    SELECT status INTO v_final_status FROM rufino_linkedin.connections WHERE connection_id = v_connection_id;
    IF v_final_status <> 'ERRO' THEN
        RAISE EXCEPTION 'SMOKE FALHOU [28]: conexao deveria estar em ERRO apos retentativas esgotadas (obtido %)', v_final_status;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM rufino_linkedin.workflow_errors WHERE workflow_error_id = v_id1) THEN
        RAISE EXCEPTION 'SMOKE FALHOU [28]: o registro da primeira ocorrencia desapareceu -- auditoria nao preservada';
    END IF;

    PERFORM set_config('smoketest.conn_err', v_connection_id::text, true);
    RAISE NOTICE 'SMOKE OK [28]: record_workflow_error preserva as duas ocorrencias; retry_count/retry_allowed corretos; transiciona para ERRO na (limite+1)-esima ocorrencia';
END;
$$;

-- -----------------------------------------------------------------------------
-- [29] Retry com o MESMO execution_id (mesma ocorrencia relatada de novo
--      pela mesma execucao do n8n) e idempotente -- devolve o mesmo
--      workflow_error_id, sem inserir uma nova linha.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_err')::uuid;
    v_before_count integer;
    v_after_count integer;
    v_id_retry uuid;
    v_id_original uuid;
BEGIN
    SELECT we.workflow_error_id INTO v_id_original FROM rufino_linkedin.workflow_errors we
     WHERE we.connection_id = v_connection_id AND we.execution_id = 'smoketest-exec-1';

    SELECT count(*) INTO v_before_count FROM rufino_linkedin.workflow_errors WHERE connection_id = v_connection_id;

    SELECT r.workflow_error_id INTO v_id_retry
      FROM rufino_linkedin.record_workflow_error(
        v_connection_id, 'WF-SMOKETEST', 'erro_smoke_v150', 'Falha simulada 1 (retry)', '{}'::jsonb, 'AGUARDANDO_D1', NULL, 1, 'smoketest-exec-1'
      ) r;

    SELECT count(*) INTO v_after_count FROM rufino_linkedin.workflow_errors WHERE connection_id = v_connection_id;

    IF v_id_retry <> v_id_original OR v_after_count <> v_before_count THEN
        RAISE EXCEPTION 'SMOKE FALHOU [29]: retry com mesmo execution_id deveria ser idempotente (id original=%, retry=%; linhas antes=%, depois=%)',
            v_id_original, v_id_retry, v_before_count, v_after_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [29]: record_workflow_error e idempotente para o mesmo execution_id (sem SELECT-depois-INSERT, via INSERT...ON CONFLICT)';
END;
$$;

-- -----------------------------------------------------------------------------
-- [30] Escrita direta numa tabela falha para a role de aplicacao.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_rejected boolean := false;
BEGIN
    BEGIN
        UPDATE rufino_linkedin.connections SET nome = 'tentativa direta' WHERE connection_id = v_connection_id;
    EXCEPTION WHEN insufficient_privilege THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [30]: UPDATE direto deveria ter sido negado por falta de grant de escrita';
    END IF;

    RAISE NOTICE 'SMOKE OK [30]: escrita direta (UPDATE) negada para a role de aplicacao';
END;
$$;

-- -----------------------------------------------------------------------------
-- [31] As 3 funcoes internas (transition_connection_status,
--      issue_action_token, create_notification_job) nao sao chamaveis
--      diretamente pela role de aplicacao.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_connection_id uuid := current_setting('smoketest.conn_a')::uuid;
    v_rejected boolean;
BEGIN
    v_rejected := false;
    BEGIN
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'ENCERRADO', 'ENCERRADO', 'smoke-test', 'tentativa direta', 'SMOKE-TEST', NULL
        ) t;
    EXCEPTION WHEN insufficient_privilege THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [31]: transition_connection_status deveria ser negada para chamada direta da role de aplicacao';
    END IF;

    v_rejected := false;
    BEGIN
        PERFORM it.raw_token FROM rufino_linkedin.issue_action_token(v_connection_id, gen_random_uuid(), 'APPROVAL') it;
    EXCEPTION WHEN insufficient_privilege THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [31]: issue_action_token deveria ser negada para chamada direta da role de aplicacao';
    END IF;

    v_rejected := false;
    BEGIN
        PERFORM j.notification_job_id FROM rufino_linkedin.create_notification_job(v_connection_id, gen_random_uuid(), 'APPROVAL') j;
    EXCEPTION WHEN insufficient_privilege THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [31]: create_notification_job deveria ser negada para chamada direta da role de aplicacao';
    END IF;

    RAISE NOTICE 'SMOKE OK [31]: as 3 funcoes internas negadas para chamada direta da role de aplicacao';
END;
$$;

-- -----------------------------------------------------------------------------
-- [32] A role de aplicacao nao tem USAGE no schema extensions -- nao
--      consegue chamar extensions.gen_random_bytes/digest diretamente.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    BEGIN
        PERFORM extensions.gen_random_bytes(8);
    EXCEPTION WHEN insufficient_privilege THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'SMOKE FALHOU [32]: role de aplicacao nao deveria conseguir chamar extensions.gen_random_bytes diretamente';
    END IF;

    RAISE NOTICE 'SMOKE OK [32]: role de aplicacao sem acesso direto ao schema extensions';
END;
$$;

-- -----------------------------------------------------------------------------
-- [33] Confirmacao final: todas as 15 funcoes seguem sem EXECUTE para
--      PUBLIC (repete a checagem do [PRE], depois de toda a sequencia de
--      testes acima -- garante que nada na sequencia alterou permissoes).
-- -----------------------------------------------------------------------------
RESET ROLE;
DO $$
DECLARE
    v_count integer;
BEGIN
    SELECT count(*) INTO v_count
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rufino_linkedin'
       AND has_function_privilege('public', p.oid, 'EXECUTE');

    IF v_count <> 0 THEN
        RAISE EXCEPTION 'SMOKE FALHOU [33]: % funcao(oes) com EXECUTE para PUBLIC ao final da sequencia (esperado 0)', v_count;
    END IF;

    RAISE NOTICE 'SMOKE OK [33]: nenhuma das 15 funcoes tem EXECUTE para PUBLIC ao final da sequencia de testes';
END;
$$;

-- -----------------------------------------------------------------------------
-- [34] Nenhum dado permanece: toda a sequencia acima roda dentro desta
-- transacao, que termina em ROLLBACK, nunca COMMIT. Se qualquer "SMOKE
-- FALHOU" acima chegou a ser lancado como excecao nao capturada, o proprio
-- erro ja teria interrompido o script antes de chegar aqui -- o ROLLBACK
-- explicito cobre tanto o caminho de sucesso quanto a limpeza depois de
-- uma falha capturada.
-- -----------------------------------------------------------------------------
ROLLBACK;

