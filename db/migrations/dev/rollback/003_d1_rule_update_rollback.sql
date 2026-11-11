-- =============================================================================
-- rollback/003_d1_rule_update_rollback.sql
-- Rufino LinkedIn Intelligence — rollback da ATUALIZAÇÃO DA REGRA D+1 (012)
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f rollback/003_d1_rule_update_rollback.sql
--
-- Desfaz SOMENTE o que 012_d1_rule_update_incremental.sql adicionou:
-- restaura register_connection à assinatura/corpo exatos de antes (20
-- parâmetros, horário hardcoded 09:00/America/Sao_Paulo), remove as 2
-- colunas novas de connections e a tabela operational_config. Nunca toca
-- em nenhum outro objeto (nem a base v1.5.1, nem o adendo pré-conexão).
--
-- ATENÇÃO: se já existirem linhas reais em connections com
-- data_conexao_origem/data_conexao_confirmado_por preenchidos, essa
-- informação de auditoria é perdida ao remover as colunas — confirme que
-- não há dado que importe, ou tire backup antes.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) register_connection — volta à assinatura/corpo de antes de 012.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text, text, text
);

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

REVOKE EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text
) TO n8n_rufino_linkedin_dev;

-- -----------------------------------------------------------------------------
-- 2) connections — remove as 2 colunas novas e o CHECK associado.
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.connections
    DROP CONSTRAINT IF EXISTS connections_data_conexao_origem_check,
    DROP COLUMN IF EXISTS data_conexao_origem,
    DROP COLUMN IF EXISTS data_conexao_confirmado_por;

-- -----------------------------------------------------------------------------
-- 3) operational_config — remove a tabela inteira.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS rufino_linkedin.operational_config;
