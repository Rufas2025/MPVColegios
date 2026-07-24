-- =============================================================================
-- 006_functions.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.0
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 006_functions.sql
--
-- 15 funções PostgreSQL SECURITY DEFINER (v1.5.0 — estabilização da camada
-- PostgreSQL, ver CHANGELOG.md):
--    1. register_connection                  (executável pela role de aplicação)
--    2. transition_connection_status         (INTERNA)
--    3. issue_action_token                   (INTERNA — nova)
--    4. create_notification_job              (INTERNA — nova)
--    5. present_message_for_delivery          (executável pela role de aplicação)
--    6. claim_due_connections                 (executável pela role de aplicação)
--    7. approve_message                       (executável pela role de aplicação)
--    8. save_message_edit                     (executável pela role de aplicação)
--    9. save_regenerated_message              (executável pela role de aplicação)
--   10. mark_message_sent                     (executável pela role de aplicação)
--   11. claim_due_followups                   (executável pela role de aplicação)
--   12. complete_followup                     (executável pela role de aplicação)
--   13. record_workflow_error                 (executável pela role de aplicação)
--   14. claim_notification_jobs               (executável pela role de aplicação) — nova
--   15. confirm_notification_delivery         (executável pela role de aplicação) — nova
--
-- 12 das 15 são executáveis pela role de aplicação; 3 são internas
-- (transition_connection_status, issue_action_token, create_notification_job)
-- — só chamáveis pelas outras (que rodam como a role owner) ou por uma
-- sessão administrativa que assuma a role owner.
--
-- MUDANÇA ARQUITETURAL CENTRAL (v1.5.0): o antigo par de colunas genérico
-- connections.pending_action_token_hash/_expires_at foi substituído por uma
-- tabela própria (action_tokens), escopada (APPROVAL/DELIVERY) e amarrada à
-- message_version_id vigente no momento da emissão. approve_message e
-- mark_message_sent não recebem mais connection_id nem message_version_id
-- como parâmetro — ambos são resolvidos inteiramente a partir do hash do
-- token apresentado. O token em si só é gerado na hora em que
-- claim_notification_jobs reivindica o job de notificação correspondente
-- (nunca antes) — isso elimina qualquer janela em que um token bruto
-- gerado precisasse ser "recuperado" de algum lugar (nunca é persistido em
-- claro, então não haveria de onde recuperá-lo).
--
-- Outbox durável (notification_jobs): a intenção de notificar o Telegram é
-- persistida antes de qualquer chamada externa. claim_due_connections e
-- present_message_for_delivery criam o job (via create_notification_job);
-- claim_notification_jobs reivindica e devolve tudo que o n8n precisa para
-- montar e enviar a mensagem; confirm_notification_delivery registra a
-- confirmação. O PostgreSQL nunca garante exactly-once para o envio em si
-- ao Telegram (o n8n pode cair depois de enviar e antes de confirmar,
-- resultando em reenvio de uma segunda mensagem com um novo action_token —
-- a primeira fica com um token morto, nunca dois tokens vivos
-- simultaneamente) — o que é garantido é que a intenção nunca se perde e
-- que uma confirmação já registrada nunca é reprocessada.
--
-- Idempotência real de callback (callback_receipts): approve_message,
-- mark_message_sent e complete_followup checam um recibo por
-- callback_query_id ANTES de tocar em qualquer token. Mesmo
-- callback_query_id + mesmo conteúdo (fingerprint) devolve o resultado já
-- persistido, inclusive depois de o token original já ter sido consumido.
-- Mesmo callback_query_id + conteúdo diferente falha claramente (conflito,
-- nunca sobrescreve).
--
-- Callback_data compacto (Telegram): os tokens usados em action_tokens e
-- em followups.claim_token_hash são gerados com 24 bytes aleatórios (48
-- caracteres hex minúsculo) — cabem com folga nos 64 bytes do campo
-- callback_data junto com um prefixo curto (ex.: "a:A:<48 chars>" = 52
-- bytes; "f:R:<48 chars>" = 52 bytes). Ver 009_smoke_tests.sql para os
-- testes de octet_length, e references/n8n-standards.md para o formato
-- exato. edit_token e regeneration_token (inalterados) continuam com 32
-- bytes — não trafegam em callback_data, então a restrição de 64 bytes não
-- se aplica a eles.
--
-- Hardening aplicado a todas, sem exceção:
--   - SECURITY DEFINER, owner n8n_rufino_linkedin_owner_dev (NOLOGIN).
--   - search_path fixado explicitamente (rufino_linkedin, extensions,
--     pg_temp).
--   - Toda referência a objeto é totalmente qualificada.
--   - extensions.digest / extensions.gen_random_bytes — pgcrypto no schema
--     "extensions"; a role owner recebeu USAGE nesse schema e EXECUTE
--     nessas duas funções em 002_roles_and_schema.sql. A role de aplicação
--     nunca recebe acesso a extensions (Correção 9 — reafirmado).
--   - Nenhuma delas usa SQL dinâmico.
--   - Atômicas, exceto o bloco de exceção isolado em record_workflow_error.
--   - Nenhum token bruto (action_token, claim_token, edit_token,
--     regeneration_token) é persistido — apenas o hash SHA-256.
--
-- ATOMICIDADE: este arquivo cria as 15 funções E aplica REVOKE EXECUTE FROM
-- PUBLIC + GRANT EXECUTE autorizado dentro da MESMA transação.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1) register_connection — inalterada desde a v1.4.2 (fora de escopo desta
--    rodada: não lida com callback do Telegram nem com tokens de ação).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.register_connection(
    p_idempotency_key   text,
    p_nome              text,
    p_primeiro_nome     text,
    p_cargo             text,
    p_instituicao       text,
    p_cidade            text,
    p_profile_url       text,
    p_conversation_url  text,
    p_data_conexao      date,
    p_resumo            text,
    p_ganchos           jsonb,
    p_melhor_gancho     text,
    p_justificativa     text,
    p_confianca         numeric,
    p_sensivel          boolean,
    p_alertas           jsonb,
    p_brain_version     text,
    p_mensagem          text,
    p_workflow_name     text DEFAULT 'WF-01',
    p_execution_id      text DEFAULT NULL
)
RETURNS TABLE (
    connection_id       uuid,
    status               text,
    scheduled_at         timestamptz,
    message_version_id   uuid,
    already_existed      boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_connection_id       uuid;
    v_scheduled_at        timestamptz;
    v_dow                 integer;
    v_days_to_add         integer;
    v_target_date         date;
    v_message_version_id  uuid;
BEGIN
    IF p_idempotency_key IS NULL OR p_nome IS NULL OR p_primeiro_nome IS NULL
       OR p_profile_url IS NULL OR p_data_conexao IS NULL THEN
        RAISE EXCEPTION 'register_connection: parametros obrigatorios ausentes';
    END IF;

    IF p_mensagem IS NULL OR btrim(p_mensagem) = '' THEN
        RAISE EXCEPTION 'register_connection: p_mensagem obrigatoria (nao pode ser nula ou vazia)';
    END IF;

    v_dow := EXTRACT(ISODOW FROM p_data_conexao + INTERVAL '1 day')::integer;
    v_days_to_add := CASE
        WHEN v_dow = 6 THEN 2
        WHEN v_dow = 7 THEN 1
        ELSE 0
    END;
    v_target_date := p_data_conexao + INTERVAL '1 day' + (v_days_to_add || ' days')::interval;
    v_scheduled_at := (v_target_date::text || ' 09:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';

    INSERT INTO rufino_linkedin.connections (
        connection_id, idempotency_key, nome, primeiro_nome, cargo, instituicao, cidade,
        profile_url, conversation_url, data_conexao, scheduled_at, status, lock_version
    ) VALUES (
        gen_random_uuid(), p_idempotency_key, p_nome, p_primeiro_nome, p_cargo, p_instituicao, p_cidade,
        p_profile_url, p_conversation_url, p_data_conexao, v_scheduled_at, 'NOVO', 0
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING rufino_linkedin.connections.connection_id INTO v_connection_id;

    IF v_connection_id IS NULL THEN
        SELECT c.connection_id INTO v_connection_id
          FROM rufino_linkedin.connections c
         WHERE c.idempotency_key = p_idempotency_key;

        SELECT mv.message_version_id INTO v_message_version_id
          FROM rufino_linkedin.message_versions mv
         WHERE mv.connection_id = v_connection_id
         ORDER BY mv.version DESC
         LIMIT 1;

        RETURN QUERY
        SELECT c.connection_id, c.status, c.scheduled_at, v_message_version_id, true
          FROM rufino_linkedin.connections c
         WHERE c.connection_id = v_connection_id;
        RETURN;
    END IF;

    INSERT INTO rufino_linkedin.analyses (
        connection_id, resumo, ganchos, melhor_gancho, justificativa, confianca, sensivel, alertas, brain_version
    ) VALUES (
        v_connection_id, p_resumo, p_ganchos, p_melhor_gancho, p_justificativa, p_confianca,
        COALESCE(p_sensivel, false), COALESCE(p_alertas, '[]'::jsonb), p_brain_version
    );

    INSERT INTO rufino_linkedin.message_versions (
        connection_id, version, message_body, source, edited_by
    ) VALUES (
        v_connection_id, 1, p_mensagem, 'gpt', NULL
    )
    RETURNING rufino_linkedin.message_versions.message_version_id INTO v_message_version_id;

    INSERT INTO rufino_linkedin.connection_status_history (
        connection_id, previous_status, new_status, actor, reason, workflow_name, execution_id
    ) VALUES (
        v_connection_id, NULL, 'NOVO', 'sistema', 'registro inicial via register_connection', p_workflow_name, p_execution_id
    );

    UPDATE rufino_linkedin.connections
       SET status = 'AGUARDANDO_D1',
           lock_version = lock_version + 1,
           updated_at = now()
     WHERE rufino_linkedin.connections.connection_id = v_connection_id;

    INSERT INTO rufino_linkedin.connection_status_history (
        connection_id, previous_status, new_status, actor, reason, workflow_name, execution_id
    ) VALUES (
        v_connection_id, 'NOVO', 'AGUARDANDO_D1', 'sistema', 'analise presente no payload, scheduled_at calculado', p_workflow_name, p_execution_id
    );

    RETURN QUERY
    SELECT v_connection_id, 'AGUARDANDO_D1'::text, v_scheduled_at, v_message_version_id, false;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 2) transition_connection_status — INTERNA. v1.5.0: simplificada — não
--    gera mais token nenhum (isso foi para action_tokens/issue_action_token,
--    acionado por quem realmente precisa de um token, não automaticamente a
--    cada transição). Só valida a aresta, atualiza status/lock_version e
--    grava o histórico.
-- =============================================================================
CREATE FUNCTION rufino_linkedin.transition_connection_status(
    p_connection_id             uuid,
    p_expected_current_status   text,
    p_new_status                text,
    p_actor                     text,
    p_reason                    text,
    p_workflow_name             text,
    p_execution_id              text DEFAULT NULL
)
RETURNS TABLE (
    connection_id  uuid,
    status         text,
    lock_version   integer,
    updated_at     timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_current_status  text;
    v_valid_edge      boolean;
    v_lock_version    integer;
    v_updated_at      timestamptz;
BEGIN
    IF p_connection_id IS NULL OR p_expected_current_status IS NULL OR p_new_status IS NULL
       OR p_actor IS NULL OR p_workflow_name IS NULL THEN
        RAISE EXCEPTION 'transition_connection_status: parametros obrigatorios ausentes';
    END IF;

    SELECT c.status INTO v_current_status
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'transition_connection_status: connection_id % nao encontrado', p_connection_id;
    END IF;

    IF v_current_status IS DISTINCT FROM p_expected_current_status THEN
        RAISE EXCEPTION 'transition_connection_status: conflito de concorrencia - status atual e "%", esperado "%"',
            v_current_status, p_expected_current_status;
    END IF;

    -- Lista de arestas inalterada desde a v1.4.2 (statuses.md) — a
    -- máquina de estados em si não muda nesta rodada, só o mecanismo de
    -- token/notificação em volta dela.
    IF p_new_status = 'ERRO' THEN
        v_valid_edge := true;
    ELSIF p_expected_current_status = 'ERRO' THEN
        v_valid_edge := true;
    ELSE
        v_valid_edge := EXISTS (
            SELECT 1 FROM (VALUES
                ('NOVO', 'AGUARDANDO_ANALISE'),
                ('NOVO', 'AGUARDANDO_D1'),
                ('AGUARDANDO_ANALISE', 'AGUARDANDO_D1'),
                ('AGUARDANDO_D1', 'AGUARDANDO_APROVACAO'),
                ('AGUARDANDO_APROVACAO', 'APROVADO'),
                ('AGUARDANDO_APROVACAO', 'AGUARDANDO_APROVACAO'),
                ('AGUARDANDO_APROVACAO', 'REFAZER'),
                ('AGUARDANDO_APROVACAO', 'DESCARTADO'),
                ('REFAZER', 'AGUARDANDO_APROVACAO'),
                ('APROVADO', 'PRONTO_PARA_ENVIO'),
                ('PRONTO_PARA_ENVIO', 'ENVIADO'),
                ('PRONTO_PARA_ENVIO', 'AGUARDANDO_APROVACAO'),
                ('ENVIADO', 'FOLLOWUP_PENDENTE'),
                ('FOLLOWUP_PENDENTE', 'RESPONDEU'),
                ('FOLLOWUP_PENDENTE', 'SEM_RESPOSTA'),
                ('RESPONDEU', 'ENCERRADO'),
                ('SEM_RESPOSTA', 'FOLLOWUP_PENDENTE'),
                ('SEM_RESPOSTA', 'ENCERRADO')
            ) AS edges(from_status, to_status)
            WHERE edges.from_status = p_expected_current_status
              AND edges.to_status = p_new_status
        );
    END IF;

    IF NOT v_valid_edge THEN
        RAISE EXCEPTION 'transition_connection_status: transicao invalida de "%" para "%"',
            p_expected_current_status, p_new_status;
    END IF;

    UPDATE rufino_linkedin.connections
       SET status = p_new_status,
           lock_version = rufino_linkedin.connections.lock_version + 1,
           updated_at = now()
     WHERE rufino_linkedin.connections.connection_id = p_connection_id
     RETURNING rufino_linkedin.connections.lock_version, rufino_linkedin.connections.updated_at
       INTO v_lock_version, v_updated_at;

    INSERT INTO rufino_linkedin.connection_status_history (
        connection_id, previous_status, new_status, actor, reason, workflow_name, execution_id
    ) VALUES (
        p_connection_id, p_expected_current_status, p_new_status, p_actor, p_reason, p_workflow_name, p_execution_id
    );

    RETURN QUERY SELECT p_connection_id, p_new_status, v_lock_version, v_updated_at;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.transition_connection_status(
    uuid, text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 3) issue_action_token — INTERNA, NOVA (v1.5.0, Correções 2 e 3).
--    Emite um token de aprovação/entrega de 24 bytes (48 chars hex),
--    invalidando qualquer token do mesmo escopo ainda ativo para a mesma
--    conexão antes de emitir o novo. Só chamada por claim_notification_jobs
--    (o token só existe a partir do instante em que alguém vai realmente
--    usá-lo para montar a mensagem do Telegram).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.issue_action_token(
    p_connection_id       uuid,
    p_message_version_id  uuid,
    p_scope               text
)
RETURNS TABLE (
    raw_token   text,
    expires_at  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_raw_token   text;
    v_hash        text;
    v_expires_at  timestamptz;
    v_ttl         CONSTANT interval := interval '7 days';
BEGIN
    IF p_connection_id IS NULL OR p_message_version_id IS NULL OR p_scope IS NULL THEN
        RAISE EXCEPTION 'issue_action_token: parametros obrigatorios ausentes';
    END IF;

    IF p_scope NOT IN ('APPROVAL', 'DELIVERY') THEN
        RAISE EXCEPTION 'issue_action_token: scope invalido "%"', p_scope;
    END IF;

    UPDATE rufino_linkedin.action_tokens
       SET consumed_at = now()
     WHERE connection_id = p_connection_id
       AND scope = p_scope
       AND consumed_at IS NULL;

    v_raw_token := encode(extensions.gen_random_bytes(24), 'hex');
    v_hash := encode(extensions.digest(v_raw_token, 'sha256'), 'hex');
    v_expires_at := now() + v_ttl;

    INSERT INTO rufino_linkedin.action_tokens (
        connection_id, message_version_id, scope, token_hash, expires_at
    ) VALUES (
        p_connection_id, p_message_version_id, p_scope, v_hash, v_expires_at
    );

    RETURN QUERY SELECT v_raw_token, v_expires_at;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.issue_action_token(
    uuid, uuid, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 4) create_notification_job — INTERNA, NOVA (v1.5.0, Correções 5 e 7).
--    Cria (supera qualquer job ainda não entregue da mesma conexão+tipo
--    primeiro) uma linha PENDING no outbox. Nunca gera token — isso é
--    lazy, só em claim_notification_jobs.
-- =============================================================================
CREATE FUNCTION rufino_linkedin.create_notification_job(
    p_connection_id       uuid,
    p_message_version_id  uuid,
    p_job_type            text
)
RETURNS TABLE (
    notification_job_id  uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_job_id uuid;
BEGIN
    IF p_connection_id IS NULL OR p_message_version_id IS NULL OR p_job_type IS NULL THEN
        RAISE EXCEPTION 'create_notification_job: parametros obrigatorios ausentes';
    END IF;

    IF p_job_type NOT IN ('APPROVAL', 'DELIVERY') THEN
        RAISE EXCEPTION 'create_notification_job: job_type invalido "%"', p_job_type;
    END IF;

    UPDATE rufino_linkedin.notification_jobs
       SET status = 'SUPERSEDED',
           updated_at = now()
     WHERE connection_id = p_connection_id
       AND job_type = p_job_type
       AND status IN ('PENDING', 'CLAIMED');

    INSERT INTO rufino_linkedin.notification_jobs (
        job_type, connection_id, message_version_id, status
    ) VALUES (
        p_job_type, p_connection_id, p_message_version_id, 'PENDING'
    )
    RETURNING rufino_linkedin.notification_jobs.notification_job_id INTO v_job_id;

    RETURN QUERY SELECT v_job_id;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.create_notification_job(
    uuid, uuid, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 5) present_message_for_delivery — v1.5.0: passa a criar o job de
--    notificação DELIVERY (create_notification_job) na mesma transação em
--    que a mensagem entra em PRONTO_PARA_ENVIO. Não retorna mais token
--    nenhum (o token é emitido lazy, só quando claim_notification_jobs
--    reivindicar o job).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.present_message_for_delivery(
    p_connection_id        uuid,
    p_message_version_id   uuid,
    p_actor                text DEFAULT 'sistema',
    p_workflow_name        text DEFAULT 'WF-04',
    p_execution_id         text DEFAULT NULL
)
RETURNS TABLE (
    connection_id       uuid,
    status               text,
    delivery_event_id     uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_current_status      text;
    v_current_version_id  uuid;
    v_new_status          text;
    v_delivery_event_id   uuid;
BEGIN
    IF p_connection_id IS NULL OR p_message_version_id IS NULL THEN
        RAISE EXCEPTION 'present_message_for_delivery: parametros obrigatorios ausentes';
    END IF;

    SELECT c.status INTO v_current_status
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'present_message_for_delivery: connection_id % nao encontrado', p_connection_id;
    END IF;

    IF v_current_status <> 'APROVADO' THEN
        RAISE EXCEPTION 'present_message_for_delivery: status atual e "%", esperado "APROVADO"', v_current_status;
    END IF;

    SELECT mv.message_version_id INTO v_current_version_id
      FROM rufino_linkedin.message_versions mv
     WHERE mv.connection_id = p_connection_id
     ORDER BY mv.version DESC
     LIMIT 1;

    IF v_current_version_id IS DISTINCT FROM p_message_version_id THEN
        RAISE EXCEPTION 'present_message_for_delivery: message_version_id % nao e a versao vigente (%)',
            p_message_version_id, v_current_version_id;
    END IF;

    SELECT t.status INTO v_new_status
      FROM rufino_linkedin.transition_connection_status(
               p_connection_id, 'APROVADO', 'PRONTO_PARA_ENVIO', p_actor,
               'mensagem apresentada para entrega', p_workflow_name, p_execution_id
           ) t;

    INSERT INTO rufino_linkedin.delivery_events (
        connection_id, delivery_mode, event_type, event_at, actor, metadata
    ) VALUES (
        p_connection_id, 'MANUAL_ASSISTED', 'MENSAGEM_APRESENTADA', now(), p_actor,
        jsonb_build_object('message_version_id', p_message_version_id)
    )
    RETURNING rufino_linkedin.delivery_events.delivery_event_id INTO v_delivery_event_id;

    PERFORM j.notification_job_id FROM rufino_linkedin.create_notification_job(
        p_connection_id, p_message_version_id, 'DELIVERY'
    ) j;

    RETURN QUERY SELECT p_connection_id, v_new_status, v_delivery_event_id;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.present_message_for_delivery(
    uuid, uuid, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 6) claim_due_connections — v1.5.0: ordenação com desempate por
--    connection_id; limite máximo seguro explícito; cria o job de
--    notificação APPROVAL (create_notification_job) na mesma transação do
--    claim. Não retorna mais raw_pending_action_token (não existe mais
--    nesse ponto — token é emitido lazy por claim_notification_jobs).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.claim_due_connections(
    p_limit          integer,
    p_workflow_name  text DEFAULT 'WF-02',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    connection_id            uuid,
    nome                     text,
    primeiro_nome            text,
    cargo                    text,
    instituicao              text,
    cidade                   text,
    profile_url              text,
    conversation_url         text,
    status                   text,
    message_version_id       uuid,
    message_body             text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_max_limit CONSTANT integer := 500;
    v_row              record;
    v_message_version  uuid;
    v_message_body     text;
BEGIN
    IF p_limit IS NULL OR p_limit <= 0 THEN
        RAISE EXCEPTION 'claim_due_connections: p_limit deve ser positivo';
    END IF;

    IF p_limit > v_max_limit THEN
        RAISE EXCEPTION 'claim_due_connections: p_limit % excede o maximo seguro (%)', p_limit, v_max_limit;
    END IF;

    FOR v_row IN
        SELECT c.connection_id, c.nome, c.primeiro_nome, c.cargo, c.instituicao, c.cidade,
               c.profile_url, c.conversation_url
          FROM rufino_linkedin.connections c
         WHERE c.status = 'AGUARDANDO_D1'
           AND c.scheduled_at <= now()
         ORDER BY c.scheduled_at, c.connection_id
         FOR UPDATE SKIP LOCKED
         LIMIT p_limit
    LOOP
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
                   v_row.connection_id, 'AGUARDANDO_D1', 'AGUARDANDO_APROVACAO',
                   'sistema', 'reivindicado por claim_due_connections', p_workflow_name, p_execution_id
               ) t;

        SELECT mv.message_version_id, mv.message_body
          INTO v_message_version, v_message_body
          FROM rufino_linkedin.message_versions mv
         WHERE mv.connection_id = v_row.connection_id
         ORDER BY mv.version DESC
         LIMIT 1;

        PERFORM j.notification_job_id FROM rufino_linkedin.create_notification_job(
            v_row.connection_id, v_message_version, 'APPROVAL'
        ) j;

        connection_id     := v_row.connection_id;
        nome               := v_row.nome;
        primeiro_nome      := v_row.primeiro_nome;
        cargo              := v_row.cargo;
        instituicao        := v_row.instituicao;
        cidade             := v_row.cidade;
        profile_url        := v_row.profile_url;
        conversation_url   := v_row.conversation_url;
        status             := 'AGUARDANDO_APROVACAO';
        message_version_id := v_message_version;
        message_body       := v_message_body;
        RETURN NEXT;
    END LOOP;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.claim_due_connections(
    integer, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 7) approve_message — v1.5.0 (Correções 2, 3, 4): recebe apenas o
--    action_token bruto (nunca connection_id/message_version_id — ambos
--    resolvidos a partir do hash do token), a decisão, o actor e o
--    callback_query_id. Idempotência real via callback_receipts: checada
--    ANTES de tocar em qualquer token, então um retry funciona mesmo com o
--    token original já consumido.
-- =============================================================================
CREATE FUNCTION rufino_linkedin.approve_message(
    p_action_token       text,
    p_decision           text,
    p_actor              text,
    p_callback_query_id  text,
    p_workflow_name      text DEFAULT 'WF-03',
    p_execution_id       text DEFAULT NULL
)
RETURNS TABLE (
    approval_id                    uuid,
    connection_id                  uuid,
    decision                       text,
    new_status                     text,
    raw_edit_token                 text,
    raw_regeneration_token         text,
    regeneration_token_expires_at  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_token_hash              text;
    v_fingerprint             text;
    v_existing                rufino_linkedin.callback_receipts;
    v_connection_id           uuid;
    v_message_version_id      uuid;
    v_token_expires_at        timestamptz;
    v_token_consumed_at       timestamptz;
    v_current_version_id      uuid;
    v_approval_id             uuid;
    v_new_status              text;
    v_raw_edit_token          text;
    v_edit_hash               text;
    v_raw_regeneration_token  text;
    v_regeneration_hash       text;
    v_regeneration_expires    timestamptz;
    v_result                  jsonb;
BEGIN
    IF p_action_token IS NULL OR p_decision IS NULL OR p_actor IS NULL OR p_callback_query_id IS NULL THEN
        RAISE EXCEPTION 'approve_message: parametros obrigatorios ausentes';
    END IF;

    IF p_decision NOT IN ('APROVAR_E_PREPARAR', 'EDITAR', 'REFAZER', 'DESCARTAR') THEN
        RAISE EXCEPTION 'approve_message: decisao invalida "%"', p_decision;
    END IF;

    v_token_hash := encode(extensions.digest(p_action_token, 'sha256'), 'hex');
    v_fingerprint := encode(extensions.digest('approve_message:' || p_decision || ':' || v_token_hash, 'sha256'), 'hex');

    SELECT * INTO v_existing
      FROM rufino_linkedin.callback_receipts
     WHERE callback_query_id = p_callback_query_id
       FOR UPDATE;

    IF FOUND THEN
        IF v_existing.fingerprint <> v_fingerprint THEN
            RAISE EXCEPTION 'approve_message: callback_query_id % ja processado com conteudo diferente', p_callback_query_id;
        END IF;

        RETURN QUERY
        SELECT * FROM jsonb_to_record(v_existing.result) AS x(
            approval_id uuid, connection_id uuid, decision text, new_status text,
            raw_edit_token text, raw_regeneration_token text, regeneration_token_expires_at timestamptz
        );
        RETURN;
    END IF;

    SELECT at.connection_id, at.message_version_id, at.expires_at, at.consumed_at
      INTO v_connection_id, v_message_version_id, v_token_expires_at, v_token_consumed_at
      FROM rufino_linkedin.action_tokens at
     WHERE at.token_hash = v_token_hash
       AND at.scope = 'APPROVAL'
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'approve_message: action_token invalido';
    END IF;

    IF v_token_consumed_at IS NOT NULL THEN
        RAISE EXCEPTION 'approve_message: action_token ja consumido';
    END IF;

    IF v_token_expires_at < now() THEN
        RAISE EXCEPTION 'approve_message: action_token expirado';
    END IF;

    PERFORM 1 FROM rufino_linkedin.connections c WHERE c.connection_id = v_connection_id FOR UPDATE;

    SELECT mv.message_version_id INTO v_current_version_id
      FROM rufino_linkedin.message_versions mv
     WHERE mv.connection_id = v_connection_id
     ORDER BY mv.version DESC
     LIMIT 1;

    IF v_current_version_id IS DISTINCT FROM v_message_version_id THEN
        RAISE EXCEPTION 'approve_message: o token nao corresponde mais a versao vigente da mensagem';
    END IF;

    UPDATE rufino_linkedin.action_tokens SET consumed_at = now() WHERE token_hash = v_token_hash;

    INSERT INTO rufino_linkedin.approvals (
        connection_id, decision, approved_by, approved_at, message_version_id, notes, callback_query_id
    ) VALUES (
        v_connection_id, p_decision, p_actor, now(), v_message_version_id, NULL, p_callback_query_id
    )
    RETURNING rufino_linkedin.approvals.approval_id INTO v_approval_id;

    IF p_decision = 'APROVAR_E_PREPARAR' THEN
        SELECT t.status INTO v_new_status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'AGUARDANDO_APROVACAO', 'APROVADO', p_actor,
            'aprovado via Telegram', p_workflow_name, p_execution_id
        ) t;
    ELSIF p_decision = 'REFAZER' THEN
        SELECT t.status INTO v_new_status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'AGUARDANDO_APROVACAO', 'REFAZER', p_actor,
            'solicitada nova versao', p_workflow_name, p_execution_id
        ) t;

        v_raw_regeneration_token := encode(extensions.gen_random_bytes(32), 'hex');
        v_regeneration_hash := encode(extensions.digest(v_raw_regeneration_token, 'sha256'), 'hex');
        v_regeneration_expires := now() + interval '2 days';

        UPDATE rufino_linkedin.connections
           SET pending_regeneration_token_hash = v_regeneration_hash,
               pending_regeneration_token_expires_at = v_regeneration_expires,
               updated_at = now()
         WHERE rufino_linkedin.connections.connection_id = v_connection_id;
    ELSIF p_decision = 'DESCARTAR' THEN
        SELECT t.status INTO v_new_status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'AGUARDANDO_APROVACAO', 'DESCARTADO', p_actor,
            'descartado', p_workflow_name, p_execution_id
        ) t;
    ELSE -- EDITAR: não transiciona, apenas emite um edit_token novo
        v_new_status := 'AGUARDANDO_APROVACAO';
        v_raw_edit_token := encode(extensions.gen_random_bytes(32), 'hex');
        v_edit_hash := encode(extensions.digest(v_raw_edit_token, 'sha256'), 'hex');
        UPDATE rufino_linkedin.connections
           SET active_edit_token_hash = v_edit_hash,
               active_edit_token_expires_at = now() + interval '2 days',
               updated_at = now()
         WHERE rufino_linkedin.connections.connection_id = v_connection_id;
    END IF;

    v_result := jsonb_build_object(
        'approval_id', v_approval_id,
        'connection_id', v_connection_id,
        'decision', p_decision,
        'new_status', v_new_status,
        'raw_edit_token', v_raw_edit_token,
        'raw_regeneration_token', v_raw_regeneration_token,
        'regeneration_token_expires_at', v_regeneration_expires
    );

    INSERT INTO rufino_linkedin.callback_receipts (callback_query_id, operation, fingerprint, result)
    VALUES (p_callback_query_id, 'approve_message', v_fingerprint, v_result);

    RETURN QUERY
    SELECT v_approval_id, v_connection_id, p_decision, v_new_status,
           v_raw_edit_token, v_raw_regeneration_token, v_regeneration_expires;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.approve_message(
    text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 8) save_message_edit — v1.5.0: passa a criar o job de notificação
--    APPROVAL (create_notification_job) para a nova versão; não retorna
--    mais token (emitido lazy por claim_notification_jobs).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.save_message_edit(
    p_presented_edit_token  text,
    p_new_message_body      text,
    p_edited_by             text,
    p_workflow_name         text DEFAULT 'WF-03-EDIT',
    p_execution_id          text DEFAULT NULL
)
RETURNS TABLE (
    connection_id       uuid,
    message_version_id  uuid,
    version             integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_hash                 text;
    v_connection_id        uuid;
    v_next_version         integer;
    v_message_version_id   uuid;
BEGIN
    IF p_presented_edit_token IS NULL OR p_new_message_body IS NULL OR p_edited_by IS NULL THEN
        RAISE EXCEPTION 'save_message_edit: parametros obrigatorios ausentes';
    END IF;

    IF btrim(p_new_message_body) = '' THEN
        RAISE EXCEPTION 'save_message_edit: p_new_message_body nao pode ser vazio';
    END IF;

    v_hash := encode(extensions.digest(p_presented_edit_token, 'sha256'), 'hex');

    SELECT c.connection_id INTO v_connection_id
      FROM rufino_linkedin.connections c
     WHERE c.active_edit_token_hash = v_hash
       AND c.active_edit_token_expires_at > now()
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'save_message_edit: edit_token invalido, expirado ou ja consumido';
    END IF;

    UPDATE rufino_linkedin.connections
       SET active_edit_token_hash = NULL,
           active_edit_token_expires_at = NULL
     WHERE rufino_linkedin.connections.connection_id = v_connection_id;

    SELECT COALESCE(MAX(mv.version), 0) + 1 INTO v_next_version
      FROM rufino_linkedin.message_versions mv
     WHERE mv.connection_id = v_connection_id;

    INSERT INTO rufino_linkedin.message_versions (
        connection_id, version, message_body, source, edited_by
    ) VALUES (
        v_connection_id, v_next_version, p_new_message_body, 'human_edit', p_edited_by
    )
    RETURNING rufino_linkedin.message_versions.message_version_id INTO v_message_version_id;

    PERFORM t.status FROM rufino_linkedin.transition_connection_status(
               v_connection_id, 'AGUARDANDO_APROVACAO', 'AGUARDANDO_APROVACAO',
               p_edited_by, 'nova versao via WF-03-EDIT', p_workflow_name, p_execution_id
           ) t;

    PERFORM j.notification_job_id FROM rufino_linkedin.create_notification_job(
        v_connection_id, v_message_version_id, 'APPROVAL'
    ) j;

    RETURN QUERY SELECT v_connection_id, v_message_version_id, v_next_version;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.save_message_edit(
    text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 9) save_regenerated_message — v1.5.0: passa a criar o job de notificação
--    APPROVAL para a nova versão gerada pelo GPT; não retorna mais token.
-- =============================================================================
CREATE FUNCTION rufino_linkedin.save_regenerated_message(
    p_presented_regeneration_token  text,
    p_new_message_body              text,
    p_actor                         text DEFAULT 'gpt',
    p_workflow_name                 text DEFAULT 'WF-03-REGEN',
    p_execution_id                  text DEFAULT NULL
)
RETURNS TABLE (
    connection_id       uuid,
    message_version_id  uuid,
    version              integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_hash                 text;
    v_connection_id        uuid;
    v_current_status       text;
    v_next_version         integer;
    v_message_version_id   uuid;
BEGIN
    IF p_presented_regeneration_token IS NULL OR p_actor IS NULL THEN
        RAISE EXCEPTION 'save_regenerated_message: parametros obrigatorios ausentes';
    END IF;

    IF p_new_message_body IS NULL OR btrim(p_new_message_body) = '' THEN
        RAISE EXCEPTION 'save_regenerated_message: p_new_message_body nao pode ser nulo ou vazio';
    END IF;

    v_hash := encode(extensions.digest(p_presented_regeneration_token, 'sha256'), 'hex');

    SELECT c.connection_id, c.status INTO v_connection_id, v_current_status
      FROM rufino_linkedin.connections c
     WHERE c.pending_regeneration_token_hash = v_hash
       AND c.pending_regeneration_token_expires_at > now()
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'save_regenerated_message: regeneration_token invalido, expirado ou ja consumido';
    END IF;

    IF v_current_status <> 'REFAZER' THEN
        RAISE EXCEPTION 'save_regenerated_message: status atual e "%", esperado "REFAZER"', v_current_status;
    END IF;

    UPDATE rufino_linkedin.connections
       SET pending_regeneration_token_hash = NULL,
           pending_regeneration_token_expires_at = NULL
     WHERE rufino_linkedin.connections.connection_id = v_connection_id;

    SELECT COALESCE(MAX(mv.version), 0) + 1 INTO v_next_version
      FROM rufino_linkedin.message_versions mv
     WHERE mv.connection_id = v_connection_id;

    INSERT INTO rufino_linkedin.message_versions (
        connection_id, version, message_body, source, edited_by
    ) VALUES (
        v_connection_id, v_next_version, p_new_message_body, 'gpt', NULL
    )
    RETURNING rufino_linkedin.message_versions.message_version_id INTO v_message_version_id;

    PERFORM t.status FROM rufino_linkedin.transition_connection_status(
               v_connection_id, 'REFAZER', 'AGUARDANDO_APROVACAO',
               p_actor, 'nova versao gerada pelo GPT via REFAZER', p_workflow_name, p_execution_id
           ) t;

    PERFORM j.notification_job_id FROM rufino_linkedin.create_notification_job(
        v_connection_id, v_message_version_id, 'APPROVAL'
    ) j;

    RETURN QUERY SELECT v_connection_id, v_message_version_id, v_next_version;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.save_regenerated_message(
    text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 10) mark_message_sent — v1.5.0 (Correções 2, 3, 4): recebe apenas o
--     action_token bruto (nunca connection_id/message_version_id). Idem-
--     potência real via callback_receipts. VOLTAR_EDITAR cria um novo job
--     de notificação APPROVAL.
-- =============================================================================
CREATE FUNCTION rufino_linkedin.mark_message_sent(
    p_action_token        text,
    p_action              text,
    p_actor               text,
    p_callback_query_id   text,
    p_first_followup_at   timestamptz DEFAULT NULL,
    p_workflow_name       text DEFAULT 'WF-04',
    p_execution_id        text DEFAULT NULL
)
RETURNS TABLE (
    delivery_event_id  uuid,
    connection_id       uuid,
    new_status          text,
    followup_id          uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_token_hash           text;
    v_fingerprint          text;
    v_existing             rufino_linkedin.callback_receipts;
    v_connection_id        uuid;
    v_message_version_id   uuid;
    v_token_expires_at     timestamptz;
    v_token_consumed_at    timestamptz;
    v_event_type           text;
    v_new_status           text;
    v_delivery_event_id    uuid;
    v_followup_id          uuid;
    v_result               jsonb;
BEGIN
    IF p_action_token IS NULL OR p_action IS NULL OR p_actor IS NULL OR p_callback_query_id IS NULL THEN
        RAISE EXCEPTION 'mark_message_sent: parametros obrigatorios ausentes';
    END IF;

    IF p_action NOT IN ('MARCAR_ENVIADA', 'VOLTAR_EDITAR') THEN
        RAISE EXCEPTION 'mark_message_sent: acao invalida "%"', p_action;
    END IF;

    IF p_action = 'MARCAR_ENVIADA' THEN
        IF p_first_followup_at IS NULL THEN
            RAISE EXCEPTION 'mark_message_sent: p_first_followup_at obrigatorio quando p_action=MARCAR_ENVIADA';
        END IF;
        IF p_first_followup_at <= now() THEN
            RAISE EXCEPTION 'mark_message_sent: p_first_followup_at precisa ser uma data futura (recebido: %)', p_first_followup_at;
        END IF;
    END IF;

    v_token_hash := encode(extensions.digest(p_action_token, 'sha256'), 'hex');
    v_fingerprint := encode(extensions.digest(
        'mark_message_sent:' || p_action || ':' || v_token_hash || ':' || COALESCE(p_first_followup_at::text, ''),
        'sha256'
    ), 'hex');

    SELECT * INTO v_existing
      FROM rufino_linkedin.callback_receipts
     WHERE callback_query_id = p_callback_query_id
       FOR UPDATE;

    IF FOUND THEN
        IF v_existing.fingerprint <> v_fingerprint THEN
            RAISE EXCEPTION 'mark_message_sent: callback_query_id % ja processado com conteudo diferente', p_callback_query_id;
        END IF;

        RETURN QUERY
        SELECT * FROM jsonb_to_record(v_existing.result) AS x(
            delivery_event_id uuid, connection_id uuid, new_status text, followup_id uuid
        );
        RETURN;
    END IF;

    SELECT at.connection_id, at.message_version_id, at.expires_at, at.consumed_at
      INTO v_connection_id, v_message_version_id, v_token_expires_at, v_token_consumed_at
      FROM rufino_linkedin.action_tokens at
     WHERE at.token_hash = v_token_hash
       AND at.scope = 'DELIVERY'
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'mark_message_sent: action_token invalido';
    END IF;

    IF v_token_consumed_at IS NOT NULL THEN
        RAISE EXCEPTION 'mark_message_sent: action_token ja consumido';
    END IF;

    IF v_token_expires_at < now() THEN
        RAISE EXCEPTION 'mark_message_sent: action_token expirado';
    END IF;

    PERFORM 1 FROM rufino_linkedin.connections c WHERE c.connection_id = v_connection_id FOR UPDATE;

    UPDATE rufino_linkedin.action_tokens SET consumed_at = now() WHERE token_hash = v_token_hash;

    IF p_action = 'MARCAR_ENVIADA' THEN
        v_event_type := 'MARCADO_COMO_ENVIADO';
        INSERT INTO rufino_linkedin.delivery_events (
            connection_id, delivery_mode, event_type, event_at, actor, metadata, callback_query_id
        ) VALUES (
            v_connection_id, 'MANUAL_ASSISTED', v_event_type, now(), p_actor,
            jsonb_build_object('message_version_id', v_message_version_id), p_callback_query_id
        ) RETURNING rufino_linkedin.delivery_events.delivery_event_id INTO v_delivery_event_id;

        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'PRONTO_PARA_ENVIO', 'ENVIADO', p_actor,
            'confirmado envio manual', p_workflow_name, p_execution_id
        ) t;

        INSERT INTO rufino_linkedin.followups (connection_id, sequence, scheduled_for)
        VALUES (v_connection_id, 1, p_first_followup_at)
        ON CONFLICT (connection_id, sequence) DO NOTHING
        RETURNING rufino_linkedin.followups.followup_id INTO v_followup_id;

        IF v_followup_id IS NULL THEN
            SELECT f.followup_id INTO v_followup_id
              FROM rufino_linkedin.followups f
             WHERE f.connection_id = v_connection_id AND f.sequence = 1;
        END IF;

        SELECT t.status INTO v_new_status
          FROM rufino_linkedin.transition_connection_status(
                   v_connection_id, 'ENVIADO', 'FOLLOWUP_PENDENTE', p_actor,
                   'primeiro follow-up agendado', p_workflow_name, p_execution_id
               ) t;
    ELSE -- VOLTAR_EDITAR
        v_event_type := 'VOLTAR_EDITAR';
        INSERT INTO rufino_linkedin.delivery_events (
            connection_id, delivery_mode, event_type, event_at, actor, metadata, callback_query_id
        ) VALUES (
            v_connection_id, 'MANUAL_ASSISTED', v_event_type, now(), p_actor,
            jsonb_build_object('message_version_id', v_message_version_id), p_callback_query_id
        ) RETURNING rufino_linkedin.delivery_events.delivery_event_id INTO v_delivery_event_id;

        SELECT t.status INTO v_new_status
          FROM rufino_linkedin.transition_connection_status(
                   v_connection_id, 'PRONTO_PARA_ENVIO', 'AGUARDANDO_APROVACAO', p_actor,
                   'retornado para edicao a partir da entrega', p_workflow_name, p_execution_id
               ) t;

        PERFORM j.notification_job_id FROM rufino_linkedin.create_notification_job(
            v_connection_id, v_message_version_id, 'APPROVAL'
        ) j;
        -- v_followup_id permanece NULL: VOLTAR_EDITAR nunca cria follow-up.
    END IF;

    v_result := jsonb_build_object(
        'delivery_event_id', v_delivery_event_id,
        'connection_id', v_connection_id,
        'new_status', v_new_status,
        'followup_id', v_followup_id
    );

    INSERT INTO rufino_linkedin.callback_receipts (callback_query_id, operation, fingerprint, result)
    VALUES (p_callback_query_id, 'mark_message_sent', v_fingerprint, v_result);

    RETURN QUERY SELECT v_delivery_event_id, v_connection_id, v_new_status, v_followup_id;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.mark_message_sent(
    text, text, text, text, timestamptz, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 11) claim_due_followups — v1.5.0 (Correção 6): recebe workflow_name/
--     execution_id (novo); gera/rotaciona claim_token_hash de 24 bytes a
--     cada (re)claim; reivindica nunca-reivindicados (claim_expires_at
--     NULL) e claims expirados (claim_expires_at <= now()); nunca
--     executed_at preenchido; ordena por scheduled_for, followup_id.
-- =============================================================================
CREATE FUNCTION rufino_linkedin.claim_due_followups(
    p_limit          integer,
    p_workflow_name  text DEFAULT 'WF-05',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    followup_id       uuid,
    connection_id      uuid,
    sequence            integer,
    scheduled_for        timestamptz,
    raw_claim_token      text,
    claim_expires_at     timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_max_limit CONSTANT integer := 500;
    v_claim_ttl CONSTANT interval := interval '1 hour';
    v_row     record;
    v_raw     text;
    v_hash    text;
    v_expires timestamptz;
BEGIN
    IF p_limit IS NULL OR p_limit <= 0 THEN
        RAISE EXCEPTION 'claim_due_followups: p_limit deve ser positivo';
    END IF;

    IF p_limit > v_max_limit THEN
        RAISE EXCEPTION 'claim_due_followups: p_limit % excede o maximo seguro (%)', p_limit, v_max_limit;
    END IF;

    IF p_workflow_name IS NULL THEN
        RAISE EXCEPTION 'claim_due_followups: p_workflow_name obrigatorio';
    END IF;

    FOR v_row IN
        SELECT f2.followup_id, f2.connection_id, f2.sequence, f2.scheduled_for
          FROM rufino_linkedin.followups f2
         WHERE f2.scheduled_for <= now()
           AND f2.executed_at IS NULL
           AND (f2.claim_expires_at IS NULL OR f2.claim_expires_at <= now())
         ORDER BY f2.scheduled_for, f2.followup_id
         FOR UPDATE SKIP LOCKED
         LIMIT p_limit
    LOOP
        v_raw := encode(extensions.gen_random_bytes(24), 'hex');
        v_hash := encode(extensions.digest(v_raw, 'sha256'), 'hex');
        v_expires := now() + v_claim_ttl;

        UPDATE rufino_linkedin.followups
           SET claimed_at = now(),
               claim_expires_at = v_expires,
               claimed_by = p_workflow_name,
               claim_execution_id = p_execution_id,
               claim_token_hash = v_hash,
               updated_at = now()
         WHERE rufino_linkedin.followups.followup_id = v_row.followup_id;

        followup_id      := v_row.followup_id;
        connection_id     := v_row.connection_id;
        sequence          := v_row.sequence;
        scheduled_for     := v_row.scheduled_for;
        raw_claim_token   := v_raw;
        claim_expires_at  := v_expires;
        RETURN NEXT;
    END LOOP;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.claim_due_followups(
    integer, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 12) complete_followup — v1.5.0 (Correções 2, 3, 4, 6): localiza e trava
--     o follow-up pelo hash do claim_token (nunca por followup_id vindo do
--     workflow); valida posse (expiração do claim) e que não foi
--     executado; idempotência real via callback_receipts;
--     callback_query_id passa a ser obrigatório (era opcional na v1.4.2).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.complete_followup(
    p_claim_token        text,
    p_resultado          text,
    p_actor              text,
    p_callback_query_id  text,
    p_notes              text DEFAULT NULL,
    p_next_followup_at   timestamptz DEFAULT NULL,
    p_workflow_name      text DEFAULT 'WF-05',
    p_execution_id       text DEFAULT NULL
)
RETURNS TABLE (
    followup_id                    uuid,
    connection_id                  uuid,
    resultado                      text,
    new_connection_status          text,
    next_followup_id               uuid,
    next_followup_sequence         integer,
    next_followup_scheduled_for    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_token_hash         text;
    v_fingerprint        text;
    v_existing           rufino_linkedin.callback_receipts;
    v_followup_id        uuid;
    v_connection_id      uuid;
    v_claim_expires_at   timestamptz;
    v_executed_at        timestamptz;
    v_next_status        text;
    v_next_followup_id   uuid;
    v_next_sequence      integer;
    v_result             jsonb;
BEGIN
    IF p_claim_token IS NULL OR p_resultado IS NULL OR p_actor IS NULL OR p_callback_query_id IS NULL THEN
        RAISE EXCEPTION 'complete_followup: parametros obrigatorios ausentes';
    END IF;

    IF p_resultado NOT IN ('RESPONDEU', 'SEM_RESPOSTA') THEN
        RAISE EXCEPTION 'complete_followup: resultado invalido "%"', p_resultado;
    END IF;

    IF p_resultado = 'RESPONDEU' AND p_next_followup_at IS NOT NULL THEN
        RAISE EXCEPTION 'complete_followup: p_next_followup_at nao se aplica quando resultado=RESPONDEU';
    END IF;

    IF p_next_followup_at IS NOT NULL AND p_next_followup_at <= now() THEN
        RAISE EXCEPTION 'complete_followup: p_next_followup_at precisa ser uma data futura (recebido: %)', p_next_followup_at;
    END IF;

    v_token_hash := encode(extensions.digest(p_claim_token, 'sha256'), 'hex');
    v_fingerprint := encode(extensions.digest(
        'complete_followup:' || p_resultado || ':' || v_token_hash || ':' || COALESCE(p_next_followup_at::text, ''),
        'sha256'
    ), 'hex');

    SELECT * INTO v_existing
      FROM rufino_linkedin.callback_receipts
     WHERE callback_query_id = p_callback_query_id
       FOR UPDATE;

    IF FOUND THEN
        IF v_existing.fingerprint <> v_fingerprint THEN
            RAISE EXCEPTION 'complete_followup: callback_query_id % ja processado com conteudo diferente', p_callback_query_id;
        END IF;

        RETURN QUERY
        SELECT * FROM jsonb_to_record(v_existing.result) AS x(
            followup_id uuid, connection_id uuid, resultado text, new_connection_status text,
            next_followup_id uuid, next_followup_sequence integer, next_followup_scheduled_for timestamptz
        );
        RETURN;
    END IF;

    SELECT f.followup_id, f.connection_id, f.claim_expires_at, f.executed_at
      INTO v_followup_id, v_connection_id, v_claim_expires_at, v_executed_at
      FROM rufino_linkedin.followups f
     WHERE f.claim_token_hash = v_token_hash
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'complete_followup: claim_token invalido (nao encontrado ou ja rotacionado por um reclaim)';
    END IF;

    IF v_claim_expires_at IS NULL OR v_claim_expires_at < now() THEN
        RAISE EXCEPTION 'complete_followup: claim expirado -- chame claim_due_followups novamente';
    END IF;

    IF v_executed_at IS NOT NULL THEN
        RAISE EXCEPTION 'complete_followup: followup_id % ja foi executado em %', v_followup_id, v_executed_at;
    END IF;

    UPDATE rufino_linkedin.followups
       SET executed_at = now(),
           resultado = p_resultado,
           notified_actor = p_actor,
           notes = p_notes,
           callback_query_id = p_callback_query_id,
           claim_token_hash = NULL,
           claim_expires_at = NULL,
           updated_at = now()
     WHERE rufino_linkedin.followups.followup_id = v_followup_id;

    IF p_resultado = 'RESPONDEU' THEN
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'FOLLOWUP_PENDENTE', 'RESPONDEU', p_actor,
            p_notes, p_workflow_name, p_execution_id
        ) t;

        SELECT t.status INTO v_next_status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'RESPONDEU', 'ENCERRADO', p_actor,
            'jornada encerrada apos resposta', p_workflow_name, p_execution_id
        ) t;

    ELSIF p_next_followup_at IS NOT NULL THEN
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'FOLLOWUP_PENDENTE', 'SEM_RESPOSTA', p_actor,
            p_notes, p_workflow_name, p_execution_id
        ) t;

        SELECT COALESCE(MAX(f.sequence), 0) + 1 INTO v_next_sequence
          FROM rufino_linkedin.followups f
         WHERE f.connection_id = v_connection_id;

        INSERT INTO rufino_linkedin.followups (connection_id, sequence, scheduled_for)
        VALUES (v_connection_id, v_next_sequence, p_next_followup_at)
        RETURNING rufino_linkedin.followups.followup_id INTO v_next_followup_id;

        SELECT t.status INTO v_next_status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'SEM_RESPOSTA', 'FOLLOWUP_PENDENTE', p_actor,
            'proximo follow-up agendado', p_workflow_name, p_execution_id
        ) t;

    ELSE
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'FOLLOWUP_PENDENTE', 'SEM_RESPOSTA', p_actor,
            p_notes, p_workflow_name, p_execution_id
        ) t;

        SELECT t.status INTO v_next_status FROM rufino_linkedin.transition_connection_status(
            v_connection_id, 'SEM_RESPOSTA', 'ENCERRADO', p_actor,
            'jornada encerrada sem resposta e sem novo follow-up solicitado', p_workflow_name, p_execution_id
        ) t;
    END IF;

    v_result := jsonb_build_object(
        'followup_id', v_followup_id,
        'connection_id', v_connection_id,
        'resultado', p_resultado,
        'new_connection_status', v_next_status,
        'next_followup_id', v_next_followup_id,
        'next_followup_sequence', v_next_sequence,
        'next_followup_scheduled_for',
            (SELECT f.scheduled_for FROM rufino_linkedin.followups f WHERE f.followup_id = v_next_followup_id)
    );

    INSERT INTO rufino_linkedin.callback_receipts (callback_query_id, operation, fingerprint, result)
    VALUES (p_callback_query_id, 'complete_followup', v_fingerprint, v_result);

    RETURN QUERY
    SELECT v_followup_id, v_connection_id, p_resultado, v_next_status,
           v_next_followup_id, v_next_sequence,
           (SELECT f.scheduled_for FROM rufino_linkedin.followups f WHERE f.followup_id = v_next_followup_id);
END;
$fn$;

ALTER FUNCTION rufino_linkedin.complete_followup(
    text, text, text, text, text, timestamptz, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 13) record_workflow_error — v1.5.0 (Correção 8): reescrita para
--     eliminar o padrão SELECT-depois-INSERT. Serializa o cálculo de
--     retry_count por chave lógica via pg_advisory_xact_lock (não é um
--     SELECT contra workflow_errors — é um lock consultivo de transação,
--     liberado automaticamente no commit/rollback). O INSERT único usa uma
--     subquery correlacionada para o retry_count e ON CONFLICT (índice
--     UNIQUE parcial de 004) para deduplicar por execution_id quando
--     informado. Preserva a auditoria mesmo se a transição para ERRO
--     falhar (inalterado desde a v1.4.2 — bloco EXCEPTION isolado).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.record_workflow_error(
    p_connection_id              uuid,
    p_source_workflow            text,
    p_error_type                 text,
    p_error_message              text,
    p_context                    jsonb,
    p_previous_status            text,
    p_recommended_resume_status  text,
    p_retry_limit                integer DEFAULT 3,
    p_execution_id               text DEFAULT NULL
)
RETURNS TABLE (
    workflow_error_id      uuid,
    transitioned_to_erro    boolean,
    transition_error         text,
    current_status           text,
    retry_count              integer,
    retry_limit              integer,
    retry_allowed            boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_workflow_error_id  uuid;
    v_retry_count        integer;
    v_transitioned       boolean := false;
    v_transition_error   text := NULL;
    v_retry_allowed      boolean;
    v_current_status     text;
BEGIN
    IF p_source_workflow IS NULL OR p_error_type IS NULL OR p_error_message IS NULL THEN
        RAISE EXCEPTION 'record_workflow_error: parametros obrigatorios ausentes';
    END IF;

    IF p_retry_limit IS NULL OR p_retry_limit <= 0 THEN
        RAISE EXCEPTION 'record_workflow_error: p_retry_limit deve ser positivo';
    END IF;

    -- Serializacao por chave logica (connection_id, source_workflow,
    -- error_type): duas chamadas concorrentes para a MESMA chave processam
    -- em sequencia (a segunda so adquire o lock apos a primeira commitar/
    -- reverter), entao nunca calculam o mesmo retry_count.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(COALESCE(p_connection_id::text, '') || '|' || p_source_workflow || '|' || p_error_type, 0)
    );

    INSERT INTO rufino_linkedin.workflow_errors (
        connection_id, source_workflow, error_type, error_message, context,
        previous_status, recommended_resume_status, execution_id, retry_count
    )
    SELECT p_connection_id, p_source_workflow, p_error_type, p_error_message, p_context,
           p_previous_status, p_recommended_resume_status, p_execution_id,
           (SELECT count(*) FROM rufino_linkedin.workflow_errors we
             WHERE we.connection_id IS NOT DISTINCT FROM p_connection_id
               AND we.source_workflow = p_source_workflow
               AND we.error_type = p_error_type
               AND we.resolved = false)
    ON CONFLICT (connection_id, source_workflow, error_type, execution_id)
        WHERE execution_id IS NOT NULL AND resolved = false
        DO NOTHING
    RETURNING rufino_linkedin.workflow_errors.workflow_error_id, rufino_linkedin.workflow_errors.retry_count
      INTO v_workflow_error_id, v_retry_count;

    IF v_workflow_error_id IS NULL THEN
        -- Conflito: a MESMA execution_id ja registrou este erro nao
        -- resolvido -- idempotente, devolve o existente sem inserir nada
        -- novo nem tentar a transicao de novo.
        SELECT we.workflow_error_id, we.retry_count
          INTO v_workflow_error_id, v_retry_count
          FROM rufino_linkedin.workflow_errors we
         WHERE we.connection_id IS NOT DISTINCT FROM p_connection_id
           AND we.source_workflow = p_source_workflow
           AND we.error_type = p_error_type
           AND we.execution_id = p_execution_id
           AND we.resolved = false
         ORDER BY we.created_at DESC
         LIMIT 1;

        IF p_connection_id IS NOT NULL THEN
            SELECT c.status INTO v_current_status FROM rufino_linkedin.connections c
             WHERE c.connection_id = p_connection_id;
        END IF;

        RETURN QUERY
        SELECT v_workflow_error_id, (v_current_status = 'ERRO'), 'idempotente: execution_id ja registrado para este erro'::text,
               v_current_status, v_retry_count, p_retry_limit, (v_retry_count < p_retry_limit);
        RETURN;
    END IF;

    v_retry_allowed := v_retry_count < p_retry_limit;

    IF p_connection_id IS NOT NULL THEN
        SELECT c.status INTO v_current_status
          FROM rufino_linkedin.connections c
         WHERE c.connection_id = p_connection_id;
    END IF;

    IF p_connection_id IS NOT NULL AND NOT v_retry_allowed THEN
        BEGIN
            PERFORM t.status FROM rufino_linkedin.transition_connection_status(
                p_connection_id, v_current_status, 'ERRO', 'sistema',
                'retentativas esgotadas em ' || p_source_workflow, p_source_workflow, p_execution_id
            ) t;
            v_transitioned := true;
            v_current_status := 'ERRO';
        EXCEPTION WHEN OTHERS THEN
            v_transition_error := SQLERRM;
            v_transitioned := false;
        END;
    END IF;

    RETURN QUERY
    SELECT v_workflow_error_id, v_transitioned, v_transition_error, v_current_status,
           v_retry_count, p_retry_limit, v_retry_allowed;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.record_workflow_error(
    uuid, text, text, text, jsonb, text, text, integer, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 14) claim_notification_jobs — NOVA (v1.5.0, Correção 5). Reivindica jobs
--     PENDING ou CLAIMED-expirados; gera o action_token e o claim_token
--     agora (nunca antes); devolve tudo que o n8n precisa para montar e
--     enviar a mensagem no Telegram.
-- =============================================================================
CREATE FUNCTION rufino_linkedin.claim_notification_jobs(
    p_limit          integer,
    p_workflow_name  text DEFAULT 'WF-NOTIFY',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    notification_job_id      uuid,
    job_type                  text,
    connection_id              uuid,
    message_version_id         uuid,
    nome                        text,
    primeiro_nome               text,
    cargo                        text,
    instituicao                  text,
    cidade                       text,
    profile_url                  text,
    conversation_url             text,
    message_body                 text,
    raw_action_token              text,
    action_token_expires_at       timestamptz,
    raw_claim_token               text,
    claim_expires_at              timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_max_limit CONSTANT integer := 200;
    v_claim_ttl CONSTANT interval := interval '15 minutes';
    v_row              record;
    v_raw_claim        text;
    v_claim_hash       text;
    v_claim_exp        timestamptz;
    v_raw_action_token text;
    v_action_expires   timestamptz;
BEGIN
    IF p_limit IS NULL OR p_limit <= 0 THEN
        RAISE EXCEPTION 'claim_notification_jobs: p_limit deve ser positivo';
    END IF;

    IF p_limit > v_max_limit THEN
        RAISE EXCEPTION 'claim_notification_jobs: p_limit % excede o maximo seguro (%)', p_limit, v_max_limit;
    END IF;

    FOR v_row IN
        SELECT nj.notification_job_id, nj.job_type, nj.connection_id, nj.message_version_id
          FROM rufino_linkedin.notification_jobs nj
         WHERE (nj.status = 'PENDING' OR (nj.status = 'CLAIMED' AND nj.claim_expires_at <= now()))
         ORDER BY nj.created_at, nj.notification_job_id
         FOR UPDATE SKIP LOCKED
         LIMIT p_limit
    LOOP
        v_raw_claim := encode(extensions.gen_random_bytes(24), 'hex');
        v_claim_hash := encode(extensions.digest(v_raw_claim, 'sha256'), 'hex');
        v_claim_exp := now() + v_claim_ttl;

        SELECT it.raw_token, it.expires_at INTO v_raw_action_token, v_action_expires
          FROM rufino_linkedin.issue_action_token(v_row.connection_id, v_row.message_version_id, v_row.job_type) it;

        UPDATE rufino_linkedin.notification_jobs
           SET status = 'CLAIMED',
               claimed_at = now(),
               claim_expires_at = v_claim_exp,
               claimed_by = p_workflow_name,
               claim_execution_id = p_execution_id,
               claim_token_hash = v_claim_hash,
               action_token_hash = encode(extensions.digest(v_raw_action_token, 'sha256'), 'hex'),
               updated_at = now()
         WHERE rufino_linkedin.notification_jobs.notification_job_id = v_row.notification_job_id;

        SELECT c.nome, c.primeiro_nome, c.cargo, c.instituicao, c.cidade, c.profile_url, c.conversation_url
          INTO nome, primeiro_nome, cargo, instituicao, cidade, profile_url, conversation_url
          FROM rufino_linkedin.connections c
         WHERE c.connection_id = v_row.connection_id;

        SELECT mv.message_body INTO message_body
          FROM rufino_linkedin.message_versions mv
         WHERE mv.message_version_id = v_row.message_version_id;

        notification_job_id     := v_row.notification_job_id;
        job_type                := v_row.job_type;
        connection_id            := v_row.connection_id;
        message_version_id       := v_row.message_version_id;
        raw_action_token         := v_raw_action_token;
        action_token_expires_at  := v_action_expires;
        raw_claim_token          := v_raw_claim;
        claim_expires_at         := v_claim_exp;
        RETURN NEXT;
    END LOOP;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.claim_notification_jobs(
    integer, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 15) confirm_notification_delivery — NOVA (v1.5.0, Correção 5). Localiza
--     o job pelo hash do claim_token (nunca por notification_job_id vindo
--     do workflow). Idempotente: confirmar de novo com o mesmo claim_token
--     depois de já confirmado é um no-op seguro (devolve o já registrado).
-- =============================================================================
CREATE FUNCTION rufino_linkedin.confirm_notification_delivery(
    p_claim_token          text,
    p_telegram_chat_id     text,
    p_telegram_message_id  text,
    p_workflow_name        text DEFAULT 'WF-NOTIFY',
    p_execution_id         text DEFAULT NULL
)
RETURNS TABLE (
    notification_job_id  uuid,
    connection_id          uuid,
    job_type                text,
    delivered_at             timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_hash           text;
    v_job_id         uuid;
    v_connection_id  uuid;
    v_job_type       text;
    v_status         text;
    v_delivered_at   timestamptz;
BEGIN
    IF p_claim_token IS NULL OR p_telegram_chat_id IS NULL OR p_telegram_message_id IS NULL THEN
        RAISE EXCEPTION 'confirm_notification_delivery: parametros obrigatorios ausentes';
    END IF;

    v_hash := encode(extensions.digest(p_claim_token, 'sha256'), 'hex');

    SELECT nj.notification_job_id, nj.connection_id, nj.job_type, nj.status, nj.delivered_at
      INTO v_job_id, v_connection_id, v_job_type, v_status, v_delivered_at
      FROM rufino_linkedin.notification_jobs nj
     WHERE nj.claim_token_hash = v_hash
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'confirm_notification_delivery: claim_token invalido (nao encontrado ou ja rotacionado por um reclaim)';
    END IF;

    IF v_status = 'DELIVERED' THEN
        RETURN QUERY SELECT v_job_id, v_connection_id, v_job_type, v_delivered_at;
        RETURN;
    END IF;

    IF v_status <> 'CLAIMED' THEN
        RAISE EXCEPTION 'confirm_notification_delivery: job % nao esta em estado CLAIMED (status atual: %)', v_job_id, v_status;
    END IF;

    UPDATE rufino_linkedin.notification_jobs
       SET status = 'DELIVERED',
           telegram_chat_id = p_telegram_chat_id,
           telegram_message_id = p_telegram_message_id,
           delivered_at = now(),
           updated_at = now()
     WHERE rufino_linkedin.notification_jobs.notification_job_id = v_job_id
     RETURNING rufino_linkedin.notification_jobs.delivered_at INTO v_delivered_at;

    RETURN QUERY SELECT v_job_id, v_connection_id, v_job_type, v_delivered_at;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.confirm_notification_delivery(
    text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- Permissões — dentro da MESMA transação que criou as 15 funções acima.
-- =============================================================================

-- REVOKE EXECUTE FROM PUBLIC nas 15, sem exceção.
REVOKE EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.transition_connection_status(
    uuid, text, text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.issue_action_token(
    uuid, uuid, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.create_notification_job(
    uuid, uuid, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.present_message_for_delivery(
    uuid, uuid, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.claim_due_connections(
    integer, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.approve_message(
    text, text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.save_message_edit(
    text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.save_regenerated_message(
    text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.mark_message_sent(
    text, text, text, text, timestamptz, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.claim_due_followups(
    integer, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.complete_followup(
    text, text, text, text, text, timestamptz, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.record_workflow_error(
    uuid, text, text, text, jsonb, text, text, integer, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.claim_notification_jobs(
    integer, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.confirm_notification_delivery(
    text, text, text, text, text
) FROM PUBLIC;

-- GRANT EXECUTE para a role de aplicação -- 12 das 15 funções. Ausentes de
-- propósito: transition_connection_status, issue_action_token,
-- create_notification_job (as 3 internas -- só chamadas pelas outras 12,
-- que rodam como a mesma role owner).
GRANT EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.present_message_for_delivery(
    uuid, uuid, text, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.claim_due_connections(
    integer, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.approve_message(
    text, text, text, text, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.save_message_edit(
    text, text, text, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.save_regenerated_message(
    text, text, text, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.mark_message_sent(
    text, text, text, text, timestamptz, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.claim_due_followups(
    integer, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.complete_followup(
    text, text, text, text, text, timestamptz, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.record_workflow_error(
    uuid, text, text, text, jsonb, text, text, integer, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.claim_notification_jobs(
    integer, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.confirm_notification_delivery(
    text, text, text, text, text
) TO n8n_rufino_linkedin_dev;

COMMIT;
