-- =============================================================================
-- 012_d1_rule_update_incremental.sql
-- Rufino LinkedIn Intelligence — Atualização da regra D+1 (origem auditável
-- da data de conexão + horário operacional configurável)
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 012_d1_rule_update_incremental.sql
--
-- Pedido do usuário (2026-11-11): usar a data de conexão exibida em
-- https://www.linkedin.com/mynetwork/invite-connect/connections/ como
-- referência de D+1 — nunca a data de importação nem a de confirmação
-- manual como substitutas — com a origem dessa data registrada de forma
-- auditável. Como o LinkedIn mostra só a data (sem horário), o horário em
-- que a mensagem é preparada no D+1 passa a ser configurável (não mais
-- hardcoded '09:00 America/Sao_Paulo' dentro da função).
--
-- PRÉ-REQUISITO ANTES DE APLICAR EM rufino-linkedin-dev (preflight real):
-- confirmar quantas linhas existem hoje em connections. O preflight de
-- 2026-11-11 confirmou que o schema/tabela já existem (base v1.5.1), mas
-- NÃO confirmou a contagem de linhas de connections especificamente — se
-- houver linhas reais, revisar o backfill abaixo antes de aplicar.
--
-- Objetos novos:
--   - rufino_linkedin.operational_config (tabela singleton; horario_d1,
--     timezone) — lida pela register_connection, nunca pela role de
--     aplicação diretamente.
--   - rufino_linkedin.connections.data_conexao_origem (NOT NULL, CHECK)
--   - rufino_linkedin.connections.data_conexao_confirmado_por (NOT NULL)
--
-- Mudança de contrato (DROP + CREATE, mesma técnica das outras funções):
--   - register_connection ganha 2 novos parâmetros no final da lista,
--     ambos obrigatórios EM TEMPO DE EXECUÇÃO (DEFAULT NULL só para
--     satisfazer a regra de sintaxe do Postgres — a função rejeita NULL
--     com RAISE EXCEPTION, nunca aceita silenciosamente):
--       p_data_conexao_origem         text  -- 'linkedin_mynetwork_confirmacao_manual' | 'outro_confirmado_manualmente'
--       p_data_conexao_confirmado_por text  -- quem confirmou visualmente (ex.: 'anderson')
--   - O corpo passa a ler horario_d1/timezone de operational_config em vez
--     de hardcoded '09:00'/'America/Sao_Paulo'. Nenhuma outra linha de
--     lógica mudou (mesmo cálculo de dia útil, mesma idempotência por
--     idempotency_key).
--
-- Reafirmado (sem mudança): nenhuma leitura automatizada da página do
-- LinkedIn foi implementada nem é permitida por esta função — a data e a
-- origem continuam dependendo de confirmação visual humana, informada
-- pelo chamador (workflow/operador), nunca obtida por scraping.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- operational_config — singleton (uma única linha, sempre).
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.operational_config (
    config_id    boolean      PRIMARY KEY DEFAULT true,
    horario_d1   time         NOT NULL DEFAULT '09:00:00',
    timezone     text         NOT NULL DEFAULT 'America/Sao_Paulo',
    updated_by   text,
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT operational_config_singleton_check CHECK (config_id)
);

ALTER TABLE rufino_linkedin.operational_config OWNER TO n8n_rufino_linkedin_owner_dev;
ALTER TABLE rufino_linkedin.operational_config ENABLE ROW LEVEL SECURITY;
-- Nenhuma policy para a role de aplicação, de propósito — só register_connection
-- (rodando como a role owner) lê este valor. Mudar o horário é ação
-- administrativa direta (UPDATE por quem tem acesso owner/psql), não uma
-- operação exposta ao n8n nesta rodada.

COMMENT ON TABLE rufino_linkedin.operational_config IS
    'Singleton (sempre 1 linha) — horário operacional em que o D+1 é agendado (horario_d1) e o timezone (timezone). Lido por register_connection no lugar do antigo hardcoded 09:00/America/Sao_Paulo. Alterar exige acesso direto (psql), não é uma função exposta ao n8n.';

INSERT INTO rufino_linkedin.operational_config (config_id, horario_d1, timezone, updated_by)
VALUES (true, '09:00:00', 'America/Sao_Paulo', 'migracao-012-valor-padrao-preservado');

-- -----------------------------------------------------------------------------
-- connections — origem auditável da data de conexão.
--
-- Backfill defensivo: se por acaso já existirem linhas (o preflight não
-- confirmou contagem — só a existência da tabela), elas recebem um marcador
-- honesto de "legado sem origem registrada" em vez de uma origem inventada.
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.connections
    ADD COLUMN data_conexao_origem         text,
    ADD COLUMN data_conexao_confirmado_por text;

UPDATE rufino_linkedin.connections
   SET data_conexao_origem = 'legado_sem_origem_registrada',
       data_conexao_confirmado_por = 'legado_sem_confirmacao_registrada'
 WHERE data_conexao_origem IS NULL;

ALTER TABLE rufino_linkedin.connections
    ALTER COLUMN data_conexao_origem SET NOT NULL,
    ALTER COLUMN data_conexao_confirmado_por SET NOT NULL,
    ADD CONSTRAINT connections_data_conexao_origem_check CHECK (data_conexao_origem IN (
        'linkedin_mynetwork_confirmacao_manual', 'outro_confirmado_manualmente', 'legado_sem_origem_registrada'
    ));

COMMENT ON COLUMN rufino_linkedin.connections.data_conexao_origem IS
    'Origem auditável de data_conexao. "linkedin_mynetwork_confirmacao_manual" = data exibida em linkedin.com/mynetwork/invite-connect/connections/, confirmada visualmente por um humano (nunca por scraping/automação). Nunca a data de importação nem a de confirmação manual do envio como substitutas.';
COMMENT ON COLUMN rufino_linkedin.connections.data_conexao_confirmado_por IS
    'Quem confirmou visualmente a data de conexão (ex.: "anderson") — auditoria humana, não inferida.';

-- -----------------------------------------------------------------------------
-- register_connection — DROP + CREATE com os 2 novos parâmetros.
-- -----------------------------------------------------------------------------
DROP FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text, text
);

CREATE FUNCTION rufino_linkedin.register_connection(
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

    -- NOVO (012): origem auditável obrigatória da data de conexão — nunca
    -- aceita em branco, nunca inferida. Regra do usuário: a data de
    -- conexão vem de linkedin.com/mynetwork/.../connections/, confirmada
    -- visualmente por um humano; nunca a data de importação nem a de
    -- confirmação de envio como substitutas.
    IF p_data_conexao_origem IS NULL OR p_data_conexao_origem NOT IN (
        'linkedin_mynetwork_confirmacao_manual', 'outro_confirmado_manualmente'
    ) THEN
        RAISE EXCEPTION 'register_connection: p_data_conexao_origem obrigatorio e deve ser linkedin_mynetwork_confirmacao_manual ou outro_confirmado_manualmente (recebido: %)', p_data_conexao_origem;
    END IF;
    IF p_data_conexao_confirmado_por IS NULL OR btrim(p_data_conexao_confirmado_por) = '' THEN
        RAISE EXCEPTION 'register_connection: p_data_conexao_confirmado_por obrigatorio (quem confirmou visualmente a data)';
    END IF;

    -- NOVO (012): horário operacional configurável (antes, hardcoded).
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
