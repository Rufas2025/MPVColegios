-- =============================================================================
-- 007_function_permissions.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV)
--
-- PostgreSQL concede EXECUTE a PUBLIC por padrão em funções novas — sem a
-- revogação explícita abaixo, qualquer role com acesso ao banco poderia
-- chamar as 9 funções. GRANT EXECUTE é concedido só à role de aplicação
-- (n8n_rufino_linkedin_dev), nunca a PUBLIC, nunca a outra role.
-- =============================================================================

REVOKE EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.transition_connection_status(
    uuid, text, text, text, text, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.present_message_for_delivery(
    uuid, uuid, text, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.claim_due_connections(
    integer, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.approve_message(
    uuid, uuid, text, text, text, text, text, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.save_message_edit(
    text, text, text, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.mark_message_sent(
    uuid, uuid, text, text, text, text, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.claim_due_followups(
    integer
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.record_workflow_error(
    uuid, text, text, text, jsonb, text, text, integer, text
) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- GRANT EXECUTE apenas para a role de aplicação do n8n (DEV).
-- -----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION rufino_linkedin.register_connection(
    text, text, text, text, text, text, text, text, date, text, jsonb, text, text, numeric, boolean, jsonb, text, text, text
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.transition_connection_status(
    uuid, text, text, text, text, text, text
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.present_message_for_delivery(
    uuid, uuid, text, text, text
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.claim_due_connections(
    integer, text, text
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.approve_message(
    uuid, uuid, text, text, text, text, text, text, text
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.save_message_edit(
    text, text, text, text, text
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.mark_message_sent(
    uuid, uuid, text, text, text, text, text, text
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.claim_due_followups(
    integer
) TO n8n_rufino_linkedin_dev;

GRANT EXECUTE ON FUNCTION rufino_linkedin.record_workflow_error(
    uuid, text, text, text, jsonb, text, text, integer, text
) TO n8n_rufino_linkedin_dev;
