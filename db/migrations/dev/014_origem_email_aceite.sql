-- =============================================================================
-- 014_origem_email_aceite.sql
-- Rufino LinkedIn Intelligence — nova origem auditável da data de conexão:
-- e-mail de aceite enviado pelo próprio LinkedIn.
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 014_origem_email_aceite.sql
-- Rollback:    rollback/006_origem_email_aceite_rollback.sql
--
-- Autorizado por Anderson em 2026-11-20. Contexto: o LinkedIn envia para
-- bado14@gmail.com um e-mail "Fulano aceitou seu convite" (remetente
-- invitations@linkedin.com) com nome, cargo e link do perfil. A entrada
-- automática lê esse e-mail (leitura da caixa do próprio usuário, sem
-- acessar o LinkedIn nem automatizar a conta).
--
-- O que muda:
--   - connections_data_conexao_origem_check passa a aceitar
--     'linkedin_email_notificacao_aceite'.
--   - register_connection passa a aceitar essa origem. Nenhuma outra linha
--     de lógica muda (mesma assinatura, mesmo cálculo de D+1, mesma
--     idempotência).
--
-- Semântica da nova origem: data_conexao = data em que o e-mail de aceite
-- chegou (America/Sao_Paulo). O LinkedIn entrega esses e-mails com atraso
-- de algumas horas, então a data pode ser 1 dia depois do aceite real —
-- nunca antes. data_conexao_confirmado_por deve identificar o processo
-- (ex.: 'sistema:email-linkedin'), nunca uma pessoa que não confirmou.
-- =============================================================================

BEGIN;

ALTER TABLE rufino_linkedin.connections
    DROP CONSTRAINT connections_data_conexao_origem_check,
    ADD CONSTRAINT connections_data_conexao_origem_check CHECK (data_conexao_origem IN (
        'linkedin_mynetwork_confirmacao_manual', 'outro_confirmado_manualmente', 'legado_sem_origem_registrada',
        'linkedin_email_notificacao_aceite'
    ));

COMMENT ON COLUMN rufino_linkedin.connections.data_conexao_origem IS
    'Origem auditável de data_conexao. "linkedin_mynetwork_confirmacao_manual" = data exibida em linkedin.com/mynetwork/invite-connect/connections/, confirmada visualmente por um humano. "linkedin_email_notificacao_aceite" = data de chegada do e-mail "aceitou seu convite" enviado pelo LinkedIn (pode ser 1 dia após o aceite real, nunca antes). Nunca scraping nem automação da conta do LinkedIn.';

CREATE OR REPLACE FUNCTION rufino_linkedin.register_connection(
    p_idempotency_key             text,
    p_nome                        text,
    p_primeiro_nome               text,
    p_cargo                       text,
    p_instituicao                 text,
    p_cidade                      text,
    p_profile_url                 text,
    p_conversation_url            text,
    p_data_conexao                date,
    p_resumo                      text,
    p_ganchos                     jsonb,
    p_melhor_gancho               text,
    p_justificativa               text,
    p_confianca                   numeric,
    p_sensivel                    boolean,
    p_alertas                     jsonb,
    p_brain_version               text,
    p_mensagem                    text,
    p_workflow_name               text DEFAULT 'WF-01',
    p_execution_id                text DEFAULT NULL,
    p_data_conexao_origem         text DEFAULT NULL,
    p_data_conexao_confirmado_por text DEFAULT NULL
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
    v_horario_d1          time;
    v_timezone            text;
BEGIN
    IF p_idempotency_key IS NULL OR p_nome IS NULL OR p_primeiro_nome IS NULL
       OR p_profile_url IS NULL OR p_data_conexao IS NULL THEN
        RAISE EXCEPTION 'register_connection: parametros obrigatorios ausentes';
    END IF;

    IF p_mensagem IS NULL OR btrim(p_mensagem) = '' THEN
        RAISE EXCEPTION 'register_connection: p_mensagem obrigatoria (nao pode ser nula ou vazia)';
    END IF;

    -- 012: origem auditável obrigatória. 014: + linkedin_email_notificacao_aceite.
    IF p_data_conexao_origem IS NULL OR p_data_conexao_origem NOT IN (
        'linkedin_mynetwork_confirmacao_manual', 'outro_confirmado_manualmente', 'linkedin_email_notificacao_aceite'
    ) THEN
        RAISE EXCEPTION 'register_connection: p_data_conexao_origem obrigatorio e deve ser linkedin_mynetwork_confirmacao_manual, outro_confirmado_manualmente ou linkedin_email_notificacao_aceite (recebido: %)', p_data_conexao_origem;
    END IF;
    IF p_data_conexao_confirmado_por IS NULL OR btrim(p_data_conexao_confirmado_por) = '' THEN
        RAISE EXCEPTION 'register_connection: p_data_conexao_confirmado_por obrigatorio (quem confirmou visualmente a data)';
    END IF;

    SELECT oc.horario_d1, oc.timezone INTO v_horario_d1, v_timezone
      FROM rufino_linkedin.operational_config oc
     LIMIT 1;
    v_horario_d1 := COALESCE(v_horario_d1, '09:00:00'::time);
    v_timezone := COALESCE(v_timezone, 'America/Sao_Paulo');

    v_dow := EXTRACT(ISODOW FROM p_data_conexao + INTERVAL '1 day')::integer;
    v_days_to_add := CASE
        WHEN v_dow = 6 THEN 2
        WHEN v_dow = 7 THEN 1
        ELSE 0
    END;
    v_target_date := p_data_conexao + INTERVAL '1 day' + (v_days_to_add || ' days')::interval;
    v_scheduled_at := (v_target_date::text || ' ' || v_horario_d1::text)::timestamp AT TIME ZONE v_timezone;

    INSERT INTO rufino_linkedin.connections (
        connection_id, idempotency_key, nome, primeiro_nome, cargo, instituicao, cidade,
        profile_url, conversation_url, data_conexao, data_conexao_origem, data_conexao_confirmado_por,
        scheduled_at, status, lock_version
    ) VALUES (
        gen_random_uuid(), p_idempotency_key, p_nome, p_primeiro_nome, p_cargo, p_instituicao, p_cidade,
        p_profile_url, p_conversation_url, p_data_conexao, p_data_conexao_origem, p_data_conexao_confirmado_por,
        v_scheduled_at, 'NOVO', 0
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
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text, text, text
) TO n8n_rufino_linkedin_dev;

COMMIT;
