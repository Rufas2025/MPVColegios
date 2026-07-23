-- =============================================================================
-- 003_tables.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV)
--
-- As 8 tabelas canônicas do modelo operacional, no schema privado
-- rufino_linkedin. Apenas colunas, tipos, defaults, PK e NOT NULL — foreign
-- keys, UNIQUE, CHECK e índices ficam em 004_constraints_and_indexes.sql
-- para manter cada arquivo com uma responsabilidade única.
--
-- PK sempre uuid gerado pelo banco (gen_random_uuid(), função nativa do
-- PostgreSQL 13+ em pg_catalog — não depende de pgcrypto). Todas as tabelas
-- têm created_at/updated_at. Nenhuma tabela guarda segredo, cookie, token de
-- sessão do LinkedIn ou valor bruto de action_token/edit_token — apenas
-- hashes SHA-256 (ver 006_functions.sql).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- connections
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.connections (
    connection_id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key                  text        NOT NULL,
    nome                             text        NOT NULL,
    primeiro_nome                    text        NOT NULL,
    cargo                            text,
    instituicao                      text,
    cidade                           text,
    profile_url                      text        NOT NULL,
    conversation_url                 text,
    data_conexao                     date        NOT NULL,
    scheduled_at                     timestamptz NOT NULL,
    status                           text        NOT NULL,
    lock_version                     integer     NOT NULL DEFAULT 0,
    pending_action_token_hash        text,
    pending_action_token_expires_at  timestamptz,
    active_edit_token_hash           text,
    active_edit_token_expires_at     timestamptz,
    created_at                       timestamptz NOT NULL DEFAULT now(),
    updated_at                       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.connections OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.connections IS
    'Uma linha por conexão do LinkedIn acompanhada pela jornada. status muda só via transition_connection_status.';
COMMENT ON COLUMN rufino_linkedin.connections.pending_action_token_hash IS
    'SHA-256 (hex) do token de uso único para a próxima decisão por botão do Telegram (WF-03/WF-04). Nunca o valor bruto.';
COMMENT ON COLUMN rufino_linkedin.connections.active_edit_token_hash IS
    'SHA-256 (hex) do link de edição ativo (WF-03-EDIT). Nunca o valor bruto.';

-- -----------------------------------------------------------------------------
-- analyses
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.analyses (
    analysis_id     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id   uuid        NOT NULL,
    resumo          text        NOT NULL,
    ganchos         jsonb       NOT NULL,
    melhor_gancho   text        NOT NULL,
    justificativa   text        NOT NULL,
    confianca       numeric(3,2) NOT NULL,
    sensivel        boolean     NOT NULL DEFAULT false,
    alertas         jsonb       NOT NULL DEFAULT '[]'::jsonb,
    brain_version   text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.analyses OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- message_versions
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.message_versions (
    message_version_id uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id       uuid        NOT NULL,
    version             integer     NOT NULL,
    message_body        text        NOT NULL,
    source              text        NOT NULL,
    edited_by           text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.message_versions OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- approvals
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.approvals (
    approval_id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id       uuid        NOT NULL,
    decision            text        NOT NULL,
    approved_by         text        NOT NULL,
    approved_at         timestamptz NOT NULL,
    message_version_id  uuid,
    notes               text,
    callback_query_id   text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.approvals OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.approvals IS
    'Nenhuma coluna de action_token bruto aqui, de propósito — só callback_query_id (dedupe de defesa em profundidade). Validação do token é por hash em connections.pending_action_token_hash, dentro de approve_message.';

-- -----------------------------------------------------------------------------
-- delivery_events
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.delivery_events (
    delivery_event_id  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id      uuid        NOT NULL,
    delivery_mode      text        NOT NULL,
    event_type         text        NOT NULL,
    event_at           timestamptz NOT NULL,
    actor              text        NOT NULL,
    metadata           jsonb,
    callback_query_id  text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.delivery_events OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- followups
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.followups (
    followup_id      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id    uuid        NOT NULL,
    sequence         integer     NOT NULL,
    scheduled_for    timestamptz NOT NULL,
    claimed_at       timestamptz,
    executed_at      timestamptz,
    resultado        text,
    notified_actor   text,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.followups OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- workflow_errors
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.workflow_errors (
    workflow_error_id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id              uuid,
    source_workflow            text        NOT NULL,
    error_type                 text        NOT NULL,
    error_message              text        NOT NULL,
    context                    jsonb,
    previous_status            text,
    recommended_resume_status  text,
    retry_count                integer     NOT NULL DEFAULT 0,
    resolved                   boolean     NOT NULL DEFAULT false,
    resolved_at                timestamptz,
    resolved_by                text,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    updated_at                 timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.workflow_errors OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON COLUMN rufino_linkedin.workflow_errors.context IS
    'jsonb livre para contexto do erro — nunca deve conter segredo, token bruto ou credencial.';

-- -----------------------------------------------------------------------------
-- connection_status_history (append-only)
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.connection_status_history (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id    uuid        NOT NULL,
    previous_status  text,
    new_status       text        NOT NULL,
    actor            text        NOT NULL,
    reason           text,
    workflow_name    text        NOT NULL,
    execution_id     text,
    created_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.connection_status_history OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.connection_status_history IS
    'Append-only — sem updated_at de propósito. Escrita exclusiva por transition_connection_status. Nenhuma exclusão de registro de auditoria no caminho operacional.';
