-- Sessão de claim concorrente (rodada duas vezes ao mesmo tempo, ver
-- ../010_concurrency_tests.md). Cada execução tenta reivindicar os 2 jobs
-- criados pelo setup com FOR UPDATE SKIP LOCKED -- se a exclusão mútua
-- estiver correta, as duas sessões nunca devolvem o mesmo
-- notification_job_id.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT notification_job_id, connection_id
  FROM rufino_linkedin.claim_notification_jobs(2)
 WHERE connection_id IN (
        SELECT connection_id FROM rufino_linkedin.connections
         WHERE idempotency_key IN ('concurrency-test-v150-conn-1', 'concurrency-test-v150-conn-2')
       );
COMMIT;
