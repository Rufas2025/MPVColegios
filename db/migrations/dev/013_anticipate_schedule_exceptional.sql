-- =============================================================================
-- 013_anticipate_schedule_exceptional.sql
-- Rufino LinkedIn Intelligence — exceção pontual e auditável ao D+1
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 013_anticipate_schedule_exceptional.sql
--
-- Pedido do usuário (2026-11-11): testar o fluxo completo do piloto Leandro
-- HOJE, sem alterar a regra global de D+1 (que continua 09h America/Sao_Paulo
-- para todos os demais contatos, via rufino_linkedin.operational_config).
--
-- Esta função resolve isso com uma única regra: antecipa o scheduled_at de
-- UMA conexão específica (identificada por connection_id), nunca a regra
-- global. Não é chamada por nenhum workflow automaticamente — é uma
-- ferramenta de exceção manual, invocada por um operador humano através de
-- um node Postgres avulso (nunca dentro de WF-01/02/03/04/05), e usada nesta
-- rodada exclusivamente para a connection_id real do Leandro
-- (0d315743-ff4f-43f9-8da7-7404f7a2585f em rufino-linkedin-dev).
--
-- Salvaguardas:
--   - p_motivo e p_actor obrigatórios (nunca em branco) — sem eles, rejeita.
--   - Só aceita ANTECIPAR (novo scheduled_at estritamente antes do atual) —
--     nunca adia, nunca move para qualquer data arbitrária.
--   - Só opera sobre uma conexão em AGUARDANDO_D1 — não pode ser usada para
--     "voltar no tempo" uma conexão já aprovada/enviada/encerrada.
--   - Nunca faz UPDATE direto — é a única porta de escrita (SECURITY
--     DEFINER), e todo workflow continua proibido de rodar um Postgres node
--     com UPDATE direto em connections.
--   - Reaproveita connection_status_history (sem tabela nova): grava o
--     evento com previous_status = new_status (o status real não muda, só
--     o agendamento), e o motivo/ator/scheduled_at antigo e novo ficam no
--     campo `reason`, de forma legível e auditável.
--   - Não altera rufino_linkedin.operational_config nem qualquer outra
--     conexão — a regra padrão 09h America/Sao_Paulo permanece intacta para
--     todos os demais contatos.
-- =============================================================================

BEGIN;

CREATE FUNCTION rufino_linkedin.anticipate_connection_schedule(
    p_connection_id      uuid,
    p_new_scheduled_at   timestamptz,
    p_motivo             text,
    p_actor              text,
    p_workflow_name      text DEFAULT 'EXCECAO-MANUAL',
    p_execution_id       text DEFAULT NULL
)
RETURNS TABLE (
    connection_id            uuid,
    previous_scheduled_at    timestamptz,
    new_scheduled_at         timestamptz,
    status                   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_current_status       text;
    v_current_scheduled_at  timestamptz;
BEGIN
    IF p_connection_id IS NULL THEN
        RAISE EXCEPTION 'anticipate_connection_schedule: p_connection_id obrigatorio';
    END IF;
    IF p_new_scheduled_at IS NULL THEN
        RAISE EXCEPTION 'anticipate_connection_schedule: p_new_scheduled_at obrigatorio';
    END IF;
    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'anticipate_connection_schedule: p_motivo obrigatorio (excecoes precisam de justificativa registrada)';
    END IF;
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION 'anticipate_connection_schedule: p_actor obrigatorio (quem autorizou a excecao)';
    END IF;

    SELECT c.status, c.scheduled_at INTO v_current_status, v_current_scheduled_at
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id
     FOR UPDATE;

    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'anticipate_connection_schedule: connection_id % nao encontrado', p_connection_id;
    END IF;

    IF v_current_status <> 'AGUARDANDO_D1' THEN
        RAISE EXCEPTION 'anticipate_connection_schedule: connection % esta em % (esperado AGUARDANDO_D1) -- nao pode antecipar uma conexao que ja saiu desse estado', p_connection_id, v_current_status;
    END IF;

    IF p_new_scheduled_at >= v_current_scheduled_at THEN
        RAISE EXCEPTION 'anticipate_connection_schedule: esta funcao so permite ANTECIPAR -- novo scheduled_at (%) precisa ser antes do atual (%)', p_new_scheduled_at, v_current_scheduled_at;
    END IF;

    UPDATE rufino_linkedin.connections
       SET scheduled_at = p_new_scheduled_at,
           lock_version = lock_version + 1,
           updated_at = now()
     WHERE rufino_linkedin.connections.connection_id = p_connection_id;

    INSERT INTO rufino_linkedin.connection_status_history (
        connection_id, previous_status, new_status, actor, reason, workflow_name, execution_id
    ) VALUES (
        p_connection_id, v_current_status, v_current_status, p_actor,
        format(
            'EXCECAO MANUAL: D+1 antecipado. Motivo: %s. scheduled_at anterior: %s -> novo: %s. Regra global (operational_config) nao foi alterada; aplica-se somente a esta conexao.',
            p_motivo, v_current_scheduled_at, p_new_scheduled_at
        ),
        p_workflow_name, p_execution_id
    );

    RETURN QUERY
    SELECT p_connection_id, v_current_scheduled_at, p_new_scheduled_at, v_current_status;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.anticipate_connection_schedule(
    uuid, timestamptz, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.anticipate_connection_schedule(
    uuid, timestamptz, text, text, text, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION rufino_linkedin.anticipate_connection_schedule(
    uuid, timestamptz, text, text, text, text
) TO n8n_rufino_linkedin_dev;

COMMIT;
