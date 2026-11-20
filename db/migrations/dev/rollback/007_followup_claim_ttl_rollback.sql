-- =============================================================================
-- rollback/007_followup_claim_ttl_rollback.sql
-- Desfaz 015_followup_claim_ttl.sql: volta claim_due_followups ao corpo
-- original de 006_functions.sql (claim de 1 hora). Claims já emitidos com
-- validade de 7 dias continuam válidos até expirar; nada é apagado.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION rufino_linkedin.claim_due_followups(
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

REVOKE EXECUTE ON FUNCTION rufino_linkedin.claim_due_followups(
    integer, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rufino_linkedin.claim_due_followups(
    integer, text, text
) TO n8n_rufino_linkedin_dev;

COMMIT;
