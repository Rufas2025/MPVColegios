-- =============================================================================
-- 004_constraints_and_indexes.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV)
--
-- Foreign keys, UNIQUE, CHECK e índices das 8 tabelas criadas em
-- 003_tables.sql. Nenhuma tabela fica "solta" sem estas garantias.
--
-- ATOMICIDADE (fix v1.4.1, item 5): todo o arquivo roda dentro de uma única
-- transação — uma FK ou índice que falhar não deixa metade das constraints
-- aplicadas.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- connections
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.connections
    ADD CONSTRAINT connections_idempotency_key_key UNIQUE (idempotency_key),
    ADD CONSTRAINT connections_status_check CHECK (status IN (
        'NOVO', 'AGUARDANDO_ANALISE', 'AGUARDANDO_D1', 'AGUARDANDO_APROVACAO',
        'APROVADO', 'REFAZER', 'DESCARTADO', 'PRONTO_PARA_ENVIO', 'ENVIADO',
        'RESPONDEU', 'SEM_RESPOSTA', 'FOLLOWUP_PENDENTE', 'ENCERRADO', 'ERRO'
    ));

CREATE INDEX connections_status_scheduled_at_idx
    ON rufino_linkedin.connections (status, scheduled_at);
CREATE INDEX connections_status_idx
    ON rufino_linkedin.connections (status);

-- -----------------------------------------------------------------------------
-- analyses
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.analyses
    ADD CONSTRAINT analyses_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT analyses_confianca_check CHECK (confianca >= 0 AND confianca <= 1);

CREATE INDEX analyses_connection_id_idx ON rufino_linkedin.analyses (connection_id);

-- -----------------------------------------------------------------------------
-- message_versions
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.message_versions
    ADD CONSTRAINT message_versions_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT message_versions_source_check CHECK (source IN ('gpt', 'human_edit')),
    ADD CONSTRAINT message_versions_edited_by_check CHECK (
        (source = 'human_edit' AND edited_by IS NOT NULL) OR (source <> 'human_edit')
    ),
    ADD CONSTRAINT message_versions_connection_version_key UNIQUE (connection_id, version);

CREATE INDEX message_versions_connection_id_idx ON rufino_linkedin.message_versions (connection_id);

-- -----------------------------------------------------------------------------
-- approvals
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.approvals
    ADD CONSTRAINT approvals_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT approvals_message_version_id_fkey FOREIGN KEY (message_version_id)
        REFERENCES rufino_linkedin.message_versions (message_version_id) ON DELETE SET NULL,
    ADD CONSTRAINT approvals_decision_check CHECK (decision IN (
        'APROVAR_E_PREPARAR', 'EDITAR', 'REFAZER', 'DESCARTAR'
    )),
    ADD CONSTRAINT approvals_callback_query_id_key UNIQUE (callback_query_id);

CREATE INDEX approvals_connection_id_idx ON rufino_linkedin.approvals (connection_id);
CREATE INDEX approvals_approved_at_idx ON rufino_linkedin.approvals (approved_at);

-- -----------------------------------------------------------------------------
-- delivery_events
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.delivery_events
    ADD CONSTRAINT delivery_events_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT delivery_events_delivery_mode_check CHECK (delivery_mode IN (
        'MANUAL_ASSISTED', 'LINKEDIN_MESSAGES_API_APPROVED'
    )),
    ADD CONSTRAINT delivery_events_callback_query_id_key UNIQUE (callback_query_id);

CREATE INDEX delivery_events_connection_id_idx ON rufino_linkedin.delivery_events (connection_id);
CREATE INDEX delivery_events_event_at_idx ON rufino_linkedin.delivery_events (event_at);

-- -----------------------------------------------------------------------------
-- followups
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.followups
    ADD CONSTRAINT followups_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT followups_resultado_check CHECK (
        resultado IS NULL OR resultado IN ('RESPONDEU', 'SEM_RESPOSTA')
    ),
    ADD CONSTRAINT followups_connection_sequence_key UNIQUE (connection_id, sequence);

CREATE INDEX followups_scheduled_for_pending_idx
    ON rufino_linkedin.followups (scheduled_for) WHERE claimed_at IS NULL;
CREATE INDEX followups_connection_id_idx ON rufino_linkedin.followups (connection_id);

-- -----------------------------------------------------------------------------
-- workflow_errors
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.workflow_errors
    ADD CONSTRAINT workflow_errors_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE SET NULL;

CREATE INDEX workflow_errors_source_workflow_resolved_idx
    ON rufino_linkedin.workflow_errors (source_workflow, resolved);
CREATE INDEX workflow_errors_connection_id_idx ON rufino_linkedin.workflow_errors (connection_id);

-- -----------------------------------------------------------------------------
-- connection_status_history
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.connection_status_history
    ADD CONSTRAINT connection_status_history_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE;

CREATE INDEX connection_status_history_connection_id_created_at_idx
    ON rufino_linkedin.connection_status_history (connection_id, created_at);

COMMIT;
