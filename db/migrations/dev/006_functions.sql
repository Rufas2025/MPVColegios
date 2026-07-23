-- =============================================================================
-- 006_functions.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV)
--
-- As 9 funções PostgreSQL SECURITY DEFINER canônicas:
--   1. register_connection
--   2. transition_connection_status
--   3. present_message_for_delivery
--   4. claim_due_connections
--   5. approve_message
--   6. save_message_edit
--   7. mark_message_sent
--   8. claim_due_followups
--   9. record_workflow_error
--
-- Hardening aplicado a todas, sem exceção:
--   - SECURITY DEFINER, owner n8n_rufino_linkedin_owner_dev (NOLOGIN).
--   - search_path fixado explicitamente (rufino_linkedin, extensions,
--     pg_temp) — nunca inclui public implicitamente, nunca herda o
--     search_path de quem chama.
--   - Toda referência a objeto é totalmente qualificada
--     (rufino_linkedin.connections, extensions.digest, etc.).
--   - extensions.digest / extensions.gen_random_bytes — pgcrypto confirmada
--     no schema "extensions" (versão 1.3, confirmado por consulta real em
--     pg_extension no preflight desta migration).
--   - Nenhuma delas usa SQL dinâmico (EXECUTE format(...)).
--   - REVOKE EXECUTE FROM PUBLIC e GRANT EXECUTE só para a role de aplicação
--     acontecem em 007_function_permissions.sql, não aqui.
--   - Atômicas: cada chamada é uma única invocação de função, executada
--     dentro da transação implícita da chamada — qualquer exceção reverte
--     integralmente os efeitos daquela chamada (nenhuma escrita parcial).
--   - action_token/edit_token: apenas o hash SHA-256 é persistido; o valor
--     bruto existe só de passagem (retornado uma única vez ao chamador,
--     nunca relido do banco); todo token tem expiração e é invalidado no
--     primeiro uso válido.
-- =============================================================================

-- =============================================================================
-- 1) register_connection
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
    p_workflow_name     text DEFAULT 'WF-01',
    p_execution_id      text DEFAULT NULL
)
RETURNS TABLE (
    connection_id   uuid,
    status          text,
    scheduled_at    timestamptz,
    already_existed boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_connection_id   uuid;
    v_scheduled_at    timestamptz;
    v_existing_id     uuid;
    v_dow             integer;
    v_days_to_add     integer;
    v_target_date     date;
BEGIN
    IF p_idempotency_key IS NULL OR p_nome IS NULL OR p_primeiro_nome IS NULL
       OR p_profile_url IS NULL OR p_data_conexao IS NULL THEN
        RAISE EXCEPTION 'register_connection: parametros obrigatorios ausentes';
    END IF;

    -- Idempotência: se já existir, retorna o registro existente sem gravar nada novo.
    SELECT c.connection_id INTO v_existing_id
      FROM rufino_linkedin.connections c
     WHERE c.idempotency_key = p_idempotency_key;

    IF FOUND THEN
        RETURN QUERY
        SELECT c.connection_id, c.status, c.scheduled_at, true
          FROM rufino_linkedin.connections c
         WHERE c.connection_id = v_existing_id;
        RETURN;
    END IF;

    -- D+1: próximo dia útil às 09:00 America/Sao_Paulo (sem calendário de
    -- feriados no MVP — decisão explícita, fora do escopo desta função).
    v_dow := EXTRACT(ISODOW FROM p_data_conexao + INTERVAL '1 day')::integer; -- 6=sabado, 7=domingo
    v_days_to_add := CASE
        WHEN v_dow = 6 THEN 2
        WHEN v_dow = 7 THEN 1
        ELSE 0
    END;
    v_target_date := p_data_conexao + INTERVAL '1 day' + (v_days_to_add || ' days')::interval;
    v_scheduled_at := (v_target_date::text || ' 09:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';

    v_connection_id := gen_random_uuid();

    -- Transacional: connections + analyses gravadas juntas; se qualquer uma
    -- falhar, a chamada inteira reverte (nenhuma conexão presa sem análise).
    INSERT INTO rufino_linkedin.connections (
        connection_id, idempotency_key, nome, primeiro_nome, cargo, instituicao, cidade,
        profile_url, conversation_url, data_conexao, scheduled_at, status, lock_version
    ) VALUES (
        v_connection_id, p_idempotency_key, p_nome, p_primeiro_nome, p_cargo, p_instituicao, p_cidade,
        p_profile_url, p_conversation_url, p_data_conexao, v_scheduled_at, 'NOVO', 0
    );

    INSERT INTO rufino_linkedin.analyses (
        connection_id, resumo, ganchos, melhor_gancho, justificativa, confianca, sensivel, alertas, brain_version
    ) VALUES (
        v_connection_id, p_resumo, p_ganchos, p_melhor_gancho, p_justificativa, p_confianca,
        COALESCE(p_sensivel, false), COALESCE(p_alertas, '[]'::jsonb), p_brain_version
    );

    -- Primeira linha de histórico (previous_status=NULL).
    INSERT INTO rufino_linkedin.connection_status_history (
        connection_id, previous_status, new_status, actor, reason, workflow_name, execution_id
    ) VALUES (
        v_connection_id, NULL, 'NOVO', 'sistema', 'registro inicial via register_connection', p_workflow_name, p_execution_id
    );

    -- A análise já veio junto no mesmo payload (contrato desta função exige
    -- todos os campos de analyses) — statuses.md permite pular direto para
    -- AGUARDANDO_D1 nesse caso. Registrado como uma segunda transição, na
    -- mesma chamada atômica, para manter o histórico legível
    -- (NOVO -> AGUARDANDO_D1) sem um segundo Execute Query no WF-01.
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
    SELECT v_connection_id, 'AGUARDANDO_D1'::text, v_scheduled_at, false;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 2) transition_connection_status
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
    connection_id           uuid,
    status                  text,
    lock_version            integer,
    updated_at              timestamptz,
    raw_pending_action_token text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_current_status  text;
    v_valid_edge      boolean;
    v_raw_token       text;
    v_token_hash      text;
    v_token_ttl       interval := interval '7 days'; -- TTL de referência — ver MANUAL-STEPS.md / riscos residuais
BEGIN
    IF p_connection_id IS NULL OR p_expected_current_status IS NULL OR p_new_status IS NULL
       OR p_actor IS NULL OR p_workflow_name IS NULL THEN
        RAISE EXCEPTION 'transition_connection_status: parametros obrigatorios ausentes';
    END IF;

    -- Trava a linha (concorrência otimista + pessimista combinadas: o lock
    -- de linha evita corrida entre duas chamadas concorrentes; a comparação
    -- de status abaixo é a checagem de "expected_current_status" que
    -- protege contra decisão tomada com dado desatualizado).
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

    -- Validação da aresta de transição (statuses.md). Qualquer estado pode
    -- ir para ERRO (falha não tratada); a saída de ERRO é sempre confirmação
    -- manual e aceita qualquer estado de destino válido do domínio (a
    -- CHECK constraint de connections.status garante que não é um valor
    -- arbitrário).
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
                ('APROVADO', 'PRONTO_PARA_ENVIO'),
                ('PRONTO_PARA_ENVIO', 'ENVIADO'),
                ('PRONTO_PARA_ENVIO', 'AGUARDANDO_APROVACAO'),
                ('ENVIADO', 'RESPONDEU'),
                ('ENVIADO', 'SEM_RESPOSTA'),
                ('RESPONDEU', 'FOLLOWUP_PENDENTE'),
                ('SEM_RESPOSTA', 'FOLLOWUP_PENDENTE'),
                ('FOLLOWUP_PENDENTE', 'ENCERRADO')
            ) AS edges(from_status, to_status)
            WHERE edges.from_status = p_expected_current_status
              AND edges.to_status = p_new_status
        );
    END IF;

    IF NOT v_valid_edge THEN
        RAISE EXCEPTION 'transition_connection_status: transicao invalida de "%" para "%"',
            p_expected_current_status, p_new_status;
    END IF;

    -- Gestão automática de pending_action_token: gera um novo token opaco ao
    -- entrar em um estado "aguardando clique de botão"; limpa em qualquer
    -- outro destino — nunca fica um token válido pendurado fora desses dois
    -- estados.
    IF p_new_status IN ('AGUARDANDO_APROVACAO', 'PRONTO_PARA_ENVIO') THEN
        v_raw_token := encode(extensions.gen_random_bytes(32), 'hex');
        v_token_hash := encode(extensions.digest(v_raw_token, 'sha256'), 'hex');
    ELSE
        v_raw_token := NULL;
        v_token_hash := NULL;
    END IF;

    UPDATE rufino_linkedin.connections
       SET status = p_new_status,
           lock_version = lock_version + 1,
           updated_at = now(),
           pending_action_token_hash = v_token_hash,
           pending_action_token_expires_at = CASE WHEN v_token_hash IS NOT NULL THEN now() + v_token_ttl ELSE NULL END
     WHERE rufino_linkedin.connections.connection_id = p_connection_id;

    INSERT INTO rufino_linkedin.connection_status_history (
        connection_id, previous_status, new_status, actor, reason, workflow_name, execution_id
    ) VALUES (
        p_connection_id, v_current_status, p_new_status, p_actor, p_reason, p_workflow_name, p_execution_id
    );

    RETURN QUERY
    SELECT c.connection_id, c.status, c.lock_version, c.updated_at, v_raw_token
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.transition_connection_status(
    uuid, text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 3) present_message_for_delivery
-- =============================================================================
CREATE FUNCTION rufino_linkedin.present_message_for_delivery(
    p_connection_id        uuid,
    p_message_version_id   uuid,
    p_actor                text DEFAULT 'sistema',
    p_workflow_name        text DEFAULT 'WF-04',
    p_execution_id         text DEFAULT NULL
)
RETURNS TABLE (
    connection_id            uuid,
    status                   text,
    raw_pending_action_token text,
    delivery_event_id        uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_current_status      text;
    v_current_version_id  uuid;
    v_new_status          text;
    v_token               text;
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

    -- Protege contra apresentar uma versão obsoleta em caso de corrida: só
    -- avança se a versão informada for de fato a vigente.
    SELECT mv.message_version_id INTO v_current_version_id
      FROM rufino_linkedin.message_versions mv
     WHERE mv.connection_id = p_connection_id
     ORDER BY mv.version DESC
     LIMIT 1;

    IF v_current_version_id IS DISTINCT FROM p_message_version_id THEN
        RAISE EXCEPTION 'present_message_for_delivery: message_version_id % nao e a versao vigente (%)',
            p_message_version_id, v_current_version_id;
    END IF;

    SELECT t.status, t.raw_pending_action_token INTO v_new_status, v_token
      FROM rufino_linkedin.transition_connection_status(
               p_connection_id, 'APROVADO', 'PRONTO_PARA_ENVIO', p_actor,
               'mensagem apresentada para entrega', p_workflow_name, p_execution_id
           ) t;

    INSERT INTO rufino_linkedin.delivery_events (
        connection_id, delivery_mode, event_type, event_at, actor
    ) VALUES (
        p_connection_id, 'MANUAL_ASSISTED', 'MENSAGEM_APRESENTADA', now(), p_actor
    )
    RETURNING rufino_linkedin.delivery_events.delivery_event_id INTO v_delivery_event_id;

    RETURN QUERY SELECT p_connection_id, v_new_status, v_token, v_delivery_event_id;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.present_message_for_delivery(
    uuid, uuid, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 4) claim_due_connections
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
    raw_pending_action_token text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_row    record;
    v_token  text;
BEGIN
    IF p_limit IS NULL OR p_limit <= 0 THEN
        RAISE EXCEPTION 'claim_due_connections: p_limit deve ser positivo';
    END IF;

    -- FOR UPDATE SKIP LOCKED: duas execuções concorrentes do WF-02 nunca
    -- reivindicam a mesma conexão. Seleção e transição de estado acontecem
    -- na mesma transação (cada iteração chama transition_connection_status).
    FOR v_row IN
        SELECT c.connection_id, c.nome, c.primeiro_nome, c.cargo, c.instituicao, c.cidade,
               c.profile_url, c.conversation_url
          FROM rufino_linkedin.connections c
         WHERE c.status = 'AGUARDANDO_D1'
           AND c.scheduled_at <= now()
         ORDER BY c.scheduled_at
         FOR UPDATE SKIP LOCKED
         LIMIT p_limit
    LOOP
        SELECT t.raw_pending_action_token INTO v_token
          FROM rufino_linkedin.transition_connection_status(
                   v_row.connection_id, 'AGUARDANDO_D1', 'AGUARDANDO_APROVACAO',
                   'sistema', 'reivindicado por claim_due_connections', p_workflow_name, p_execution_id
               ) t;

        connection_id     := v_row.connection_id;
        nome               := v_row.nome;
        primeiro_nome      := v_row.primeiro_nome;
        cargo              := v_row.cargo;
        instituicao        := v_row.instituicao;
        cidade             := v_row.cidade;
        profile_url        := v_row.profile_url;
        conversation_url   := v_row.conversation_url;
        status             := 'AGUARDANDO_APROVACAO';
        raw_pending_action_token := v_token;
        RETURN NEXT;
    END LOOP;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.claim_due_connections(
    integer, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 5) approve_message
-- =============================================================================
CREATE FUNCTION rufino_linkedin.approve_message(
    p_connection_id           uuid,
    p_message_version_id      uuid,
    p_decision                text,
    p_approved_by             text,
    p_notes                   text,
    p_callback_query_id       text,
    p_presented_action_token  text,
    p_workflow_name           text DEFAULT 'WF-03',
    p_execution_id            text DEFAULT NULL
)
RETURNS TABLE (
    approval_id     uuid,
    connection_id   uuid,
    decision        text,
    new_status      text,
    raw_edit_token  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_hash             text;
    v_pending_hash     text;
    v_pending_expires  timestamptz;
    v_approval_id      uuid;
    v_new_status       text;
    v_raw_edit_token   text;
    v_edit_hash        text;
BEGIN
    IF p_connection_id IS NULL OR p_decision IS NULL OR p_approved_by IS NULL
       OR p_presented_action_token IS NULL THEN
        RAISE EXCEPTION 'approve_message: parametros obrigatorios ausentes';
    END IF;

    IF p_decision NOT IN ('APROVAR_E_PREPARAR', 'EDITAR', 'REFAZER', 'DESCARTAR') THEN
        RAISE EXCEPTION 'approve_message: decisao invalida "%"', p_decision;
    END IF;

    -- Dedupe de defesa em profundidade por callback_query_id (a defesa
    -- principal é a validação de hash do token, logo abaixo).
    IF p_callback_query_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM rufino_linkedin.approvals a WHERE a.callback_query_id = p_callback_query_id
    ) THEN
        RAISE EXCEPTION 'approve_message: callback_query_id % ja processado', p_callback_query_id;
    END IF;

    SELECT c.pending_action_token_hash, c.pending_action_token_expires_at
      INTO v_pending_hash, v_pending_expires
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'approve_message: connection_id % nao encontrado', p_connection_id;
    END IF;

    IF v_pending_hash IS NULL THEN
        RAISE EXCEPTION 'approve_message: nenhum token pendente para esta conexao (ja consumido ou nunca emitido)';
    END IF;

    IF v_pending_expires IS NULL OR v_pending_expires < now() THEN
        RAISE EXCEPTION 'approve_message: token pendente expirado';
    END IF;

    v_hash := encode(extensions.digest(p_presented_action_token, 'sha256'), 'hex');
    IF v_hash IS DISTINCT FROM v_pending_hash THEN
        RAISE EXCEPTION 'approve_message: token apresentado nao confere';
    END IF;

    -- Invalidação de uso único, antes de qualquer outro efeito: os outros
    -- botões da mesma mensagem morrem junto (uma decisão já foi tomada).
    UPDATE rufino_linkedin.connections
       SET pending_action_token_hash = NULL,
           pending_action_token_expires_at = NULL
     WHERE rufino_linkedin.connections.connection_id = p_connection_id;

    INSERT INTO rufino_linkedin.approvals (
        connection_id, decision, approved_by, approved_at, message_version_id, notes, callback_query_id
    ) VALUES (
        p_connection_id, p_decision, p_approved_by, now(), p_message_version_id, p_notes, p_callback_query_id
    )
    RETURNING rufino_linkedin.approvals.approval_id INTO v_approval_id;

    IF p_decision = 'APROVAR_E_PREPARAR' THEN
        SELECT t.status INTO v_new_status FROM rufino_linkedin.transition_connection_status(
            p_connection_id, 'AGUARDANDO_APROVACAO', 'APROVADO', p_approved_by,
            'aprovado via Telegram', p_workflow_name, p_execution_id
        ) t;
    ELSIF p_decision = 'REFAZER' THEN
        SELECT t.status INTO v_new_status FROM rufino_linkedin.transition_connection_status(
            p_connection_id, 'AGUARDANDO_APROVACAO', 'REFAZER', p_approved_by,
            COALESCE(p_notes, 'solicitada nova versao'), p_workflow_name, p_execution_id
        ) t;
    ELSIF p_decision = 'DESCARTAR' THEN
        SELECT t.status INTO v_new_status FROM rufino_linkedin.transition_connection_status(
            p_connection_id, 'AGUARDANDO_APROVACAO', 'DESCARTADO', p_approved_by,
            COALESCE(p_notes, 'descartado'), p_workflow_name, p_execution_id
        ) t;
    ELSE -- EDITAR: não transiciona, apenas emite um edit_token novo
        v_new_status := 'AGUARDANDO_APROVACAO';
        v_raw_edit_token := encode(extensions.gen_random_bytes(32), 'hex');
        v_edit_hash := encode(extensions.digest(v_raw_edit_token, 'sha256'), 'hex');
        UPDATE rufino_linkedin.connections
           SET active_edit_token_hash = v_edit_hash,
               active_edit_token_expires_at = now() + interval '2 days',
               updated_at = now()
         WHERE rufino_linkedin.connections.connection_id = p_connection_id;
    END IF;

    RETURN QUERY
    SELECT v_approval_id, p_connection_id, p_decision, v_new_status, v_raw_edit_token;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.approve_message(
    uuid, uuid, text, text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 6) save_message_edit
-- =============================================================================
CREATE FUNCTION rufino_linkedin.save_message_edit(
    p_presented_edit_token  text,
    p_new_message_body      text,
    p_edited_by             text,
    p_workflow_name         text DEFAULT 'WF-03-EDIT',
    p_execution_id          text DEFAULT NULL
)
RETURNS TABLE (
    connection_id             uuid,
    message_version_id        uuid,
    version                   integer,
    raw_pending_action_token  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_hash                 text;
    v_connection_id        uuid;
    v_next_version         integer;
    v_message_version_id   uuid;
    v_token                text;
BEGIN
    IF p_presented_edit_token IS NULL OR p_new_message_body IS NULL OR p_edited_by IS NULL THEN
        RAISE EXCEPTION 'save_message_edit: parametros obrigatorios ausentes';
    END IF;

    v_hash := encode(extensions.digest(p_presented_edit_token, 'sha256'), 'hex');

    -- connection_id é resolvido a partir de qual linha tem esse hash — o
    -- connection_id nunca aparece em claro na URL do Form.
    SELECT c.connection_id INTO v_connection_id
      FROM rufino_linkedin.connections c
     WHERE c.active_edit_token_hash = v_hash
       AND c.active_edit_token_expires_at > now()
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'save_message_edit: edit_token invalido, expirado ou ja consumido';
    END IF;

    -- Invalidação de uso único.
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

    -- Self-loop AGUARDANDO_APROVACAO -> AGUARDANDO_APROVACAO: decisão
    -- anterior invalidada, novo pending_action_token emitido para a
    -- próxima rodada de botões no Telegram.
    SELECT t.raw_pending_action_token INTO v_token
      FROM rufino_linkedin.transition_connection_status(
               v_connection_id, 'AGUARDANDO_APROVACAO', 'AGUARDANDO_APROVACAO',
               p_edited_by, 'nova versao via WF-03-EDIT', p_workflow_name, p_execution_id
           ) t;

    RETURN QUERY SELECT v_connection_id, v_message_version_id, v_next_version, v_token;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.save_message_edit(
    text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 7) mark_message_sent
-- =============================================================================
CREATE FUNCTION rufino_linkedin.mark_message_sent(
    p_connection_id           uuid,
    p_message_version_id      uuid,
    p_actor                   text,
    p_callback_query_id       text,
    p_presented_action_token  text,
    p_action                  text,
    p_workflow_name           text DEFAULT 'WF-04',
    p_execution_id            text DEFAULT NULL
)
RETURNS TABLE (
    delivery_event_id         uuid,
    connection_id             uuid,
    new_status                text,
    raw_pending_action_token  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_pending_hash     text;
    v_pending_expires  timestamptz;
    v_hash             text;
    v_event_type       text;
    v_new_status       text;
    v_token            text;
    v_delivery_event_id uuid;
BEGIN
    IF p_connection_id IS NULL OR p_actor IS NULL OR p_presented_action_token IS NULL
       OR p_action IS NULL THEN
        RAISE EXCEPTION 'mark_message_sent: parametros obrigatorios ausentes';
    END IF;

    IF p_action NOT IN ('MARCAR_ENVIADA', 'VOLTAR_EDITAR') THEN
        RAISE EXCEPTION 'mark_message_sent: acao invalida "%"', p_action;
    END IF;

    IF p_callback_query_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM rufino_linkedin.delivery_events de WHERE de.callback_query_id = p_callback_query_id
    ) THEN
        RAISE EXCEPTION 'mark_message_sent: callback_query_id % ja processado', p_callback_query_id;
    END IF;

    SELECT c.pending_action_token_hash, c.pending_action_token_expires_at
      INTO v_pending_hash, v_pending_expires
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'mark_message_sent: connection_id % nao encontrado', p_connection_id;
    END IF;

    IF v_pending_hash IS NULL THEN
        RAISE EXCEPTION 'mark_message_sent: nenhum token pendente para esta conexao';
    END IF;

    IF v_pending_expires IS NULL OR v_pending_expires < now() THEN
        RAISE EXCEPTION 'mark_message_sent: token pendente expirado';
    END IF;

    v_hash := encode(extensions.digest(p_presented_action_token, 'sha256'), 'hex');
    IF v_hash IS DISTINCT FROM v_pending_hash THEN
        RAISE EXCEPTION 'mark_message_sent: token apresentado nao confere';
    END IF;

    UPDATE rufino_linkedin.connections
       SET pending_action_token_hash = NULL,
           pending_action_token_expires_at = NULL
     WHERE rufino_linkedin.connections.connection_id = p_connection_id;

    IF p_action = 'MARCAR_ENVIADA' THEN
        v_event_type := 'MARCADO_COMO_ENVIADO';
        INSERT INTO rufino_linkedin.delivery_events (
            connection_id, delivery_mode, event_type, event_at, actor, metadata, callback_query_id
        ) VALUES (
            p_connection_id, 'MANUAL_ASSISTED', v_event_type, now(), p_actor,
            jsonb_build_object('message_version_id', p_message_version_id), p_callback_query_id
        ) RETURNING rufino_linkedin.delivery_events.delivery_event_id INTO v_delivery_event_id;

        SELECT t.status, t.raw_pending_action_token INTO v_new_status, v_token
          FROM rufino_linkedin.transition_connection_status(
                   p_connection_id, 'PRONTO_PARA_ENVIO', 'ENVIADO', p_actor,
                   'confirmado envio manual', p_workflow_name, p_execution_id
               ) t;
    ELSE -- VOLTAR_EDITAR
        v_event_type := 'VOLTAR_EDITAR';
        INSERT INTO rufino_linkedin.delivery_events (
            connection_id, delivery_mode, event_type, event_at, actor, metadata, callback_query_id
        ) VALUES (
            p_connection_id, 'MANUAL_ASSISTED', v_event_type, now(), p_actor,
            jsonb_build_object('message_version_id', p_message_version_id), p_callback_query_id
        ) RETURNING rufino_linkedin.delivery_events.delivery_event_id INTO v_delivery_event_id;

        SELECT t.status, t.raw_pending_action_token INTO v_new_status, v_token
          FROM rufino_linkedin.transition_connection_status(
                   p_connection_id, 'PRONTO_PARA_ENVIO', 'AGUARDANDO_APROVACAO', p_actor,
                   'retornado para edicao a partir da entrega', p_workflow_name, p_execution_id
               ) t;
    END IF;

    RETURN QUERY SELECT v_delivery_event_id, p_connection_id, v_new_status, v_token;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.mark_message_sent(
    uuid, uuid, text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 8) claim_due_followups
-- =============================================================================
CREATE FUNCTION rufino_linkedin.claim_due_followups(
    p_limit integer
)
RETURNS TABLE (
    followup_id    uuid,
    connection_id  uuid,
    sequence       integer,
    scheduled_for  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
BEGIN
    IF p_limit IS NULL OR p_limit <= 0 THEN
        RAISE EXCEPTION 'claim_due_followups: p_limit deve ser positivo';
    END IF;

    -- SELECT ... FOR UPDATE SKIP LOCKED + marcação de claimed_at na mesma
    -- transação (subselect com o lock, UPDATE aplica no resultado já
    -- travado) — mesmo padrão de concorrência de claim_due_connections.
    RETURN QUERY
    UPDATE rufino_linkedin.followups f
       SET claimed_at = now()
      FROM (
               SELECT f2.followup_id
                 FROM rufino_linkedin.followups f2
                WHERE f2.claimed_at IS NULL
                  AND f2.scheduled_for <= now()
                ORDER BY f2.scheduled_for
                FOR UPDATE SKIP LOCKED
                LIMIT p_limit
           ) claimed
     WHERE f.followup_id = claimed.followup_id
     RETURNING f.followup_id, f.connection_id, f.sequence, f.scheduled_for;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.claim_due_followups(
    integer
) OWNER TO n8n_rufino_linkedin_owner_dev;


-- =============================================================================
-- 9) record_workflow_error
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
    retry_count            integer,
    transitioned_to_erro   boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
DECLARE
    v_workflow_error_id  uuid;
    v_retry_count        integer;
    v_transitioned       boolean := false;
BEGIN
    IF p_source_workflow IS NULL OR p_error_type IS NULL OR p_error_message IS NULL THEN
        RAISE EXCEPTION 'record_workflow_error: parametros obrigatorios ausentes';
    END IF;

    SELECT count(*) INTO v_retry_count
      FROM rufino_linkedin.workflow_errors we
     WHERE we.connection_id IS NOT DISTINCT FROM p_connection_id
       AND we.source_workflow = p_source_workflow
       AND we.error_type = p_error_type
       AND we.resolved = false;

    INSERT INTO rufino_linkedin.workflow_errors (
        connection_id, source_workflow, error_type, error_message, context,
        previous_status, recommended_resume_status, retry_count
    ) VALUES (
        p_connection_id, p_source_workflow, p_error_type, p_error_message, p_context,
        p_previous_status, p_recommended_resume_status, v_retry_count
    ) RETURNING rufino_linkedin.workflow_errors.workflow_error_id INTO v_workflow_error_id;

    -- Nunca decide sozinha o status de retorno: só transiciona para ERRO
    -- quando as tentativas se esgotam, e recommended_resume_status
    -- permanece só como sugestão para a confirmação humana futura.
    IF p_connection_id IS NOT NULL AND p_previous_status IS NOT NULL AND v_retry_count >= p_retry_limit THEN
        PERFORM t.status FROM rufino_linkedin.transition_connection_status(
            p_connection_id, p_previous_status, 'ERRO', 'sistema',
            'retentativas esgotadas em ' || p_source_workflow, p_source_workflow, p_execution_id
        ) t;
        v_transitioned := true;
    END IF;

    RETURN QUERY SELECT v_workflow_error_id, v_retry_count, v_transitioned;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.record_workflow_error(
    uuid, text, text, text, jsonb, text, text, integer, text
) OWNER TO n8n_rufino_linkedin_owner_dev;
