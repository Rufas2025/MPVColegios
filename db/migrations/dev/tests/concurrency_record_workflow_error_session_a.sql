-- Sessão A do teste de concorrência de record_workflow_error (ver
-- ../010_concurrency_tests.md). Roda como um processo psql independente,
-- concorrente com concurrency_record_workflow_error_session_b.sql contra o
-- MESMO banco descartável. Nunca contra o banco real.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT workflow_error_id, retry_count, transitioned_to_erro
  FROM rufino_linkedin.record_workflow_error(
    NULL, 'WF-CONCURRENCY-TEST', 'erro_concorrente_v150', 'sessao A', '{}'::jsonb, NULL, NULL, 5, 'concurrency-test-exec-A'
  );
-- Segura a transação aberta por alguns segundos para forçar a Sessão B a
-- esperar no pg_advisory_xact_lock antes de calcular seu próprio
-- retry_count -- é exatamente essa espera que prova a serialização.
SELECT pg_sleep(3);
COMMIT;
