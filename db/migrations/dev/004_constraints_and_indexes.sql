-- =============================================================================
-- 004_constraints_and_indexes.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.1
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 004_constraints_and_indexes.sql
--
-- Foreign keys, UNIQUE, CHECK e índices das 11 tabelas criadas em
-- 003_tables.sql. Nenhuma tabela fica "solta" sem estas garantias.
--
-- ATOMICIDADE: todo o arquivo roda dentro de uma única transação.
--
-- v1.5.0: índices/constraints das 3 tabelas novas (action_tokens,
-- callback_receipts, notification_jobs); posse de claim em followups
-- (claim_token_hash UNIQUE); índice UNIQUE parcial de idempotência por
-- execution_id em workflow_errors (Correção 8 — substitui o par
-- SELECT-depois-INSERT por INSERT...ON CONFLICT em 006_functions.sql).
-- Removido o índice que não existe mais (pending_action_token_hash saiu de
-- connections, ver 003_tables.sql).
--
-- v1.5.1 (Correção 2): notification_jobs_active_per_connection_type_key
-- (UNIQUE (connection_id, job_type, status)) substituída por um índice
-- UNIQUE parcial (connection_id, job_type) WHERE status IN ('PENDING',
-- 'CLAIMED') — a constraint antiga bloqueava indevidamente uma segunda
-- linha DELIVERED ou SUPERSEDED histórica para a mesma conexão/tipo.
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

-- Ordenação determinística de claim_due_connections: (status, scheduled_at)
-- cobre o filtro e a ordenação primária; connection_id como desempate final
-- não precisa de índice próprio (poucas linhas empatam no mesmo instante).
CREATE INDEX connections_status_scheduled_at_idx
    ON rufino_linkedin.connections (status, scheduled_at);
CREATE INDEX connections_status_idx
    ON rufino_linkedin.connections (status);

-- Lookups por hash de token, usados por save_message_edit e
-- save_regenerated_message (connection_id ainda não é conhecido nesses
-- pontos — é resolvido a partir de qual linha tem o hash). Parciais porque
-- a maioria das linhas tem esses campos NULL na maior parte do tempo.
CREATE INDEX connections_active_edit_token_hash_idx
    ON rufino_linkedin.connections (active_edit_token_hash) WHERE active_edit_token_hash IS NOT NULL;
CREATE INDEX connections_pending_regeneration_token_hash_idx
    ON rufino_linkedin.connections (pending_regeneration_token_hash) WHERE pending_regeneration_token_hash IS NOT NULL;

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
        'MANUAL_ASSISTED'
        -- v1.5.0 (Correção 9): LINKEDIN_MESSAGES_API_APPROVED removido do
        -- CHECK enquanto o adaptador não estiver de fato implementado — ver
        -- references/linkedin-api-readiness.md. Reintroduzir aqui é o
        -- próprio ato de habilitar o adaptador futuro, não antes.
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
    ADD CONSTRAINT followups_connection_sequence_key UNIQUE (connection_id, sequence),
    ADD CONSTRAINT followups_callback_query_id_key UNIQUE (callback_query_id),
    -- v1.5.0 (Correção 6): posse de claim por hash — no máximo uma linha
    -- pode ter um dado claim_token_hash vivo por vez (rotacionado a cada
    -- claim/reclaim, nulo entre reivindicações).
    ADD CONSTRAINT followups_claim_token_hash_key UNIQUE (claim_token_hash);

-- O índice parcial permanece sobre executed_at IS NULL — claim_due_followups
-- reivindica tanto linhas nunca reivindicadas quanto claims expirados
-- (claim_expires_at no passado); o filtro comum aos dois ramos é sempre
-- executed_at IS NULL.
CREATE INDEX followups_scheduled_for_pending_idx
    ON rufino_linkedin.followups (scheduled_for) WHERE executed_at IS NULL;
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

-- v1.5.0 (Correção 8): chave de idempotência real — uma única linha não
-- resolvida por (connection_id, source_workflow, error_type, execution_id)
-- quando execution_id é informado. NULLS NOT DISTINCT (PostgreSQL 15+)
-- trata connection_id NULL de forma consistente (erros não amarrados a
-- conexão também deduplicam por execution_id). record_workflow_error usa
-- este índice via INSERT...ON CONFLICT — nunca mais SELECT seguido de
-- INSERT para decidir se já existe.
CREATE UNIQUE INDEX workflow_errors_execution_dedupe_key
    ON rufino_linkedin.workflow_errors (connection_id, source_workflow, error_type, execution_id)
    NULLS NOT DISTINCT
    WHERE execution_id IS NOT NULL AND resolved = false;

-- -----------------------------------------------------------------------------
-- connection_status_history
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.connection_status_history
    ADD CONSTRAINT connection_status_history_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE;

CREATE INDEX connection_status_history_connection_id_created_at_idx
    ON rufino_linkedin.connection_status_history (connection_id, created_at);

-- -----------------------------------------------------------------------------
-- action_tokens (v1.5.0)
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.action_tokens
    ADD CONSTRAINT action_tokens_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT action_tokens_message_version_id_fkey FOREIGN KEY (message_version_id)
        REFERENCES rufino_linkedin.message_versions (message_version_id) ON DELETE CASCADE,
    ADD CONSTRAINT action_tokens_scope_check CHECK (scope IN ('APPROVAL', 'DELIVERY')),
    ADD CONSTRAINT action_tokens_token_hash_key UNIQUE (token_hash);

-- Usado por issue_action_token para invalidar tokens anteriores ainda
-- ativos da mesma conexão+scope antes de emitir um novo.
CREATE INDEX action_tokens_connection_scope_active_idx
    ON rufino_linkedin.action_tokens (connection_id, scope) WHERE consumed_at IS NULL;

-- -----------------------------------------------------------------------------
-- callback_receipts (v1.5.0)
-- -----------------------------------------------------------------------------
-- callback_query_id já é PK (003_tables.sql) — nenhuma constraint adicional
-- necessária. Índice por operação, útil para auditoria/depuração manual.
CREATE INDEX callback_receipts_operation_idx ON rufino_linkedin.callback_receipts (operation);

-- -----------------------------------------------------------------------------
-- notification_jobs (v1.5.0)
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.notification_jobs
    ADD CONSTRAINT notification_jobs_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE CASCADE,
    ADD CONSTRAINT notification_jobs_message_version_id_fkey FOREIGN KEY (message_version_id)
        REFERENCES rufino_linkedin.message_versions (message_version_id) ON DELETE CASCADE,
    ADD CONSTRAINT notification_jobs_job_type_check CHECK (job_type IN ('APPROVAL', 'DELIVERY')),
    ADD CONSTRAINT notification_jobs_status_check CHECK (status IN (
        'PENDING', 'CLAIMED', 'DELIVERED', 'SUPERSEDED'
    )),
    -- Rotacionado a cada claim/reclaim — no máximo uma linha pode ter um
    -- dado claim_token_hash vivo por vez.
    ADD CONSTRAINT notification_jobs_claim_token_hash_key UNIQUE (claim_token_hash);

-- [v1.5.1, Correção 2] Backstop estrutural: no máximo um job *ativo*
-- (PENDING ou CLAIMED) por conexão/tipo — nunca dois jobs simultâneos
-- disputando o mesmo par connection_id+job_type. Um índice UNIQUE parcial,
-- não uma constraint UNIQUE cobrindo a coluna status inteira: a versão
-- anterior (`notification_jobs_active_per_connection_type_key UNIQUE
-- (connection_id, job_type, status)`) impedia, incorretamente, uma
-- segunda linha DELIVERED ou uma segunda linha SUPERSEDED para a mesma
-- conexão+tipo — o que quebra o fluxo real de "apresentar, editar/refazer,
-- apresentar de novo", que gera múltiplas notificações APPROVAL/DELIVERY
-- históricas para a mesma conexão ao longo do tempo. Quantidade de linhas
-- DELIVERED e SUPERSEDED por conexão/tipo é sempre ilimitada; só o job
-- ativo (ainda não entregue) precisa ser único.
CREATE UNIQUE INDEX notification_jobs_one_active_per_connection_type_idx
    ON rufino_linkedin.notification_jobs (connection_id, job_type)
    WHERE status IN ('PENDING', 'CLAIMED');

-- Consulta central de claim_notification_jobs: jobs pendentes ou com claim
-- expirado, nunca DELIVERED nem SUPERSEDED.
CREATE INDEX notification_jobs_claimable_idx
    ON rufino_linkedin.notification_jobs (status, claim_expires_at)
    WHERE status IN ('PENDING', 'CLAIMED');
CREATE INDEX notification_jobs_connection_id_idx ON rufino_linkedin.notification_jobs (connection_id);

COMMIT;
