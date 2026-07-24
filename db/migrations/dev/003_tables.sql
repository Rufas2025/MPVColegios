-- =============================================================================
-- 003_tables.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.0
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 003_tables.sql
--
-- As 11 tabelas canônicas do modelo operacional, no schema privado
-- rufino_linkedin. Apenas colunas, tipos, defaults, PK e NOT NULL — foreign
-- keys, UNIQUE, CHECK e índices ficam em 004_constraints_and_indexes.sql.
--
-- v1.5.0 — estabilização da camada PostgreSQL (ver CHANGELOG.md):
--   - connections perde pending_action_token_hash/_expires_at — o token de
--     aprovação/entrega deixou de ser um par de colunas genérico na própria
--     conexão e virou uma linha própria em action_tokens, com scope
--     (APPROVAL/DELIVERY) e message_version_id associados explicitamente.
--   - followups ganha posse explícita de claim (claim_token_hash,
--     claim_expires_at, claimed_by, claim_execution_id), substituindo o
--     timeout implícito de 1h calculado em cima de claimed_at.
--   - 3 tabelas novas: action_tokens, callback_receipts, notification_jobs.
--
-- PK sempre uuid gerado pelo banco (gen_random_uuid()). Todas as tabelas têm
-- created_at/updated_at (exceto connection_status_history, append-only de
-- propósito). Nenhuma tabela guarda segredo, cookie, token de sessão do
-- LinkedIn ou valor bruto de token de qualquer tipo — apenas hashes SHA-256
-- (ver 006_functions.sql).
--
-- ATOMICIDADE: todo o arquivo roda dentro de uma única transação — se
-- qualquer CREATE TABLE falhar, nenhuma das 11 fica criada pela metade.
-- =============================================================================

BEGIN;

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
    active_edit_token_hash                   text,
    active_edit_token_expires_at             timestamptz,
    pending_regeneration_token_hash          text,
    pending_regeneration_token_expires_at    timestamptz,
    created_at                       timestamptz NOT NULL DEFAULT now(),
    updated_at                       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.connections OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.connections IS
    'Uma linha por conexão do LinkedIn acompanhada pela jornada. status muda só via transition_connection_status.';
COMMENT ON COLUMN rufino_linkedin.connections.active_edit_token_hash IS
    'SHA-256 (hex) do link de edição ativo (WF-03-EDIT). Nunca o valor bruto.';
COMMENT ON COLUMN rufino_linkedin.connections.pending_regeneration_token_hash IS
    'SHA-256 (hex) do token de uso único emitido por approve_message (decisão REFAZER) e consumido por save_regenerated_message. Nunca o valor bruto.';

-- Nota v1.5.0: pending_action_token_hash/_expires_at (existentes até a
-- v1.4.2) foram removidas daqui. O token de aprovação/entrega passou a viver
-- em rufino_linkedin.action_tokens, com scope (APPROVAL/DELIVERY) e
-- message_version_id associados na própria linha do token — ver comentário
-- daquela tabela abaixo e references/postgres-functions.md da skill.

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
    'Nenhuma coluna de action_token bruto aqui, de propósito — só callback_query_id (auditoria/defesa em profundidade; a idempotência real de approve_message é callback_receipts). Validação do token é por hash em action_tokens, dentro de approve_message.';

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
    followup_id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id       uuid        NOT NULL,
    sequence            integer     NOT NULL,
    scheduled_for       timestamptz NOT NULL,
    claimed_at          timestamptz,
    executed_at         timestamptz,
    resultado           text,
    notified_actor      text,
    notes               text,
    callback_query_id   text,
    claim_token_hash    text,
    claim_expires_at    timestamptz,
    claimed_by          text,
    claim_execution_id  text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.followups OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON COLUMN rufino_linkedin.followups.callback_query_id IS
    'Id do callback_query do Telegram para a resposta RESPONDEU/SEM_RESPOSTA — auditoria/defesa em profundidade; a idempotência real de complete_followup é callback_receipts.';
COMMENT ON COLUMN rufino_linkedin.followups.claim_token_hash IS
    'v1.5.0 — SHA-256 (hex) do token de posse de claim, gerado por claim_due_followups e rotacionado a cada (re)claim. complete_followup localiza e trava a linha por este hash, nunca por followup_id vindo do workflow. Nunca o valor bruto.';
COMMENT ON COLUMN rufino_linkedin.followups.claim_expires_at IS
    'v1.5.0 — expiração explícita do claim atual. Substitui o timeout implícito de 1h calculado sobre claimed_at nas versões anteriores.';

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
    execution_id               text,
    resolved                   boolean     NOT NULL DEFAULT false,
    resolved_at                timestamptz,
    resolved_by                text,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    updated_at                 timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.workflow_errors OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.workflow_errors IS
    'v1.5.0: dedupe por execution_id via índice UNIQUE parcial (004) + INSERT...ON CONFLICT (006, record_workflow_error) — nunca mais SELECT seguido de INSERT.';
COMMENT ON COLUMN rufino_linkedin.workflow_errors.context IS
    'jsonb livre para contexto do erro — nunca deve conter segredo, token bruto ou credencial.';
COMMENT ON COLUMN rufino_linkedin.workflow_errors.execution_id IS
    'Execution id do n8n — participa da chave de deduplicação (índice UNIQUE parcial em 004) quando não nulo e o erro ainda não foi resolvido.';

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

-- -----------------------------------------------------------------------------
-- action_tokens — NOVA (v1.5.0, Correções 2 e 3)
--
-- Substitui as colunas genéricas connections.pending_action_token_hash/
-- _expires_at. Cada linha é um token de uso único, escopado (APPROVAL ou
-- DELIVERY) e amarrado à message_version_id vigente no momento da emissão —
-- approve_message/mark_message_sent resolvem connection_id e
-- message_version_id inteiramente a partir do hash do token apresentado,
-- nunca de um uuid enviado pelo workflow. Tokens são gerados com 24 bytes
-- aleatórios (48 caracteres hex), para caber com folga nos 64 bytes do
-- callback_data do Telegram junto com o prefixo curto (ex.: "a:A:<48 chars>"
-- = 52 bytes) — ver references/n8n-standards.md.
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.action_tokens (
    action_token_id      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id        uuid        NOT NULL,
    message_version_id   uuid        NOT NULL,
    scope                text        NOT NULL,
    token_hash           text        NOT NULL,
    expires_at           timestamptz NOT NULL,
    consumed_at          timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.action_tokens OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.action_tokens IS
    'v1.5.0 — token de uso único para os callbacks de aprovação (scope=APPROVAL, consumido por approve_message) e de entrega (scope=DELIVERY, consumido por mark_message_sent). Só o hash SHA-256 é persistido; o valor bruto existe apenas de passagem, devolvido uma única vez a quem emitiu (claim_notification_jobs). Emitido/invalidado por issue_action_token (interna).';
COMMENT ON COLUMN rufino_linkedin.action_tokens.token_hash IS
    'SHA-256 (hex, 64 chars) do token bruto de 24 bytes (48 chars hex). Nunca o valor bruto.';

-- -----------------------------------------------------------------------------
-- callback_receipts — NOVA (v1.5.0, Correção 4)
--
-- Idempotência real dos callbacks do Telegram para approve_message,
-- mark_message_sent e complete_followup. callback_query_id é PK (único por
-- definição do próprio Telegram). fingerprint identifica o CONTEÚDO da
-- operação (não só o id) — reapresentar o mesmo callback_query_id com o
-- mesmo conteúdo devolve o resultado já persistido em `result`; com
-- conteúdo diferente, falha claramente (não é a mesma decisão, é um
-- conflito). O retry funciona mesmo depois de o token original já ter sido
-- consumido, porque a checagem contra este recibo acontece ANTES de tocar
-- em qualquer token.
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.callback_receipts (
    callback_query_id  text        PRIMARY KEY,
    operation           text        NOT NULL,
    fingerprint         text        NOT NULL,
    result              jsonb       NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.callback_receipts OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.callback_receipts IS
    'v1.5.0 — um recibo por callback_query_id do Telegram já processado por approve_message/mark_message_sent/complete_followup. `result` é o retorno completo daquela chamada, persistido para replay idempotente exato em caso de retry.';
COMMENT ON COLUMN rufino_linkedin.callback_receipts.fingerprint IS
    'SHA-256 (hex) do conteúdo relevante da operação (decisão/ação/resultado + hash do token apresentado) — não do token bruto. Um mesmo callback_query_id com fingerprint diferente é rejeitado como conflito, nunca silenciosamente sobrescrito.';

-- -----------------------------------------------------------------------------
-- notification_jobs — NOVA (v1.5.0, Correções 5 e 7)
--
-- Outbox durável: a intenção de notificar o Telegram (aprovação ou entrega)
-- é persistida aqui ANTES de qualquer chamada externa ao Telegram — se o
-- worker cair entre reivindicar a conexão/mensagem e efetivamente enviar,
-- o job continua aqui, reivindicável de novo por claim_notification_jobs.
-- O PostgreSQL nunca garante exactly-once para o envio em si (o Telegram
-- pode ter recebido a mensagem mesmo que o n8n tenha caído antes de
-- confirmar) — o que este desenho garante é que a intenção nunca se perde
-- e que a confirmação, uma vez feita, nunca é reprocessada. Ver
-- references/postgres-functions.md, seção de claim_notification_jobs/
-- confirm_notification_delivery, para a explicação completa.
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.notification_jobs (
    notification_job_id  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type              text        NOT NULL,
    connection_id         uuid        NOT NULL,
    message_version_id    uuid        NOT NULL,
    status                text        NOT NULL DEFAULT 'PENDING',
    claimed_at            timestamptz,
    claim_expires_at      timestamptz,
    claimed_by            text,
    claim_execution_id    text,
    claim_token_hash      text,
    action_token_hash     text,
    telegram_chat_id      text,
    telegram_message_id   text,
    delivered_at          timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.notification_jobs OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.notification_jobs IS
    'v1.5.0 — outbox durável de notificações Telegram (APPROVAL/DELIVERY). Criado por claim_due_connections (APPROVAL) e present_message_for_delivery (DELIVERY) via create_notification_job (interna). Reivindicado por claim_notification_jobs (gera/rotaciona o action_token correspondente na hora, nunca antes) e confirmado por confirm_notification_delivery. Job com status=DELIVERED nunca mais é reivindicado.';
COMMENT ON COLUMN rufino_linkedin.notification_jobs.claim_token_hash IS
    'SHA-256 (hex) do token de posse do claim atual — rotacionado a cada (re)claim, nunca o valor bruto. confirm_notification_delivery localiza e trava a linha por este hash.';
COMMENT ON COLUMN rufino_linkedin.notification_jobs.action_token_hash IS
    'Cópia do token_hash da linha de action_tokens gerada no claim mais recente deste job — nunca o valor bruto, só para rastreabilidade/auditoria (junta com action_tokens quando necessário).';

COMMIT;
