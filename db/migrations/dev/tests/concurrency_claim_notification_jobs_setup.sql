-- Setup do teste de concorrência de claim_notification_jobs (ver
-- ../010_concurrency_tests.md). Cria 2 conexões de teste, cada uma já
-- reivindicada e com seu job de notificação APPROVAL pendente, prontas
-- para serem disputadas por duas sessões concorrentes.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;

DO $$
DECLARE
    v_conn_1 uuid;
    v_conn_2 uuid;
BEGIN
    SELECT r.connection_id INTO v_conn_1
      FROM rufino_linkedin.register_connection(
        'concurrency-test-v150-conn-1', 'Concorrencia Um', 'Um', 'Diretor', 'Escola Concorrencia', 'SP',
        'https://linkedin.com/in/concorrencia-1', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-concurrency-test', 'Mensagem inicial concorrencia 1'
      ) r;
    SELECT r.connection_id INTO v_conn_2
      FROM rufino_linkedin.register_connection(
        'concurrency-test-v150-conn-2', 'Concorrencia Dois', 'Dois', 'Diretor', 'Escola Concorrencia', 'SP',
        'https://linkedin.com/in/concorrencia-2', NULL, CURRENT_DATE,
        'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-concurrency-test', 'Mensagem inicial concorrencia 2'
      ) r;
END;
$$;

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute'
 WHERE idempotency_key IN ('concurrency-test-v150-conn-1', 'concurrency-test-v150-conn-2');
SET LOCAL ROLE n8n_rufino_linkedin_dev;

-- Ambas entram em AGUARDANDO_APROVACAO com um job APPROVAL PENDING cada.
SELECT connection_id FROM rufino_linkedin.claim_due_connections(2);

COMMIT;
