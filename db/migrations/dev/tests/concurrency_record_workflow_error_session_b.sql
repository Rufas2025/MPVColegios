-- Sessão B do teste de concorrência de record_workflow_error. Inicia ~1s
-- depois da Sessão A (ver script de orquestração em 010_concurrency_tests.md)
-- para garantir que a Sessão A já esteja com a transação aberta e o
-- advisory lock adquirido quando a Sessão B tentar a mesma chave lógica.
\set ON_ERROR_STOP on
SELECT pg_sleep(1);
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
-- Se a serialização por pg_advisory_xact_lock estiver funcionando, esta
-- chamada BLOQUEIA aqui até a Sessão A commitar (linha 1 acima), e só então
-- calcula retry_count -- que deve dar 1 (nunca 0, nunca colidir com a
-- Sessão A). Ver TEST-REPORT.md para o resultado real desta rodada.
SELECT workflow_error_id, retry_count, transitioned_to_erro
  FROM rufino_linkedin.record_workflow_error(
    NULL, 'WF-CONCURRENCY-TEST', 'erro_concorrente_v150', 'sessao B', '{}'::jsonb, NULL, NULL, 5, 'concurrency-test-exec-B'
  );
COMMIT;
-- Limpeza: como este teste usa COMMIT (para provar a serialização de
-- verdade através de duas transações reais, não ROLLBACK), o script de
-- orquestração remove as linhas de teste ao final -- ver
-- 010_concurrency_tests.md.
