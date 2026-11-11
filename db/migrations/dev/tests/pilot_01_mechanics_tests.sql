-- Teste de MECÂNICA do pipeline pós-aceite (aprovação, envio, prevenção de
-- duplicidade, follow-up, interrupção) — dados SINTÉTICOS, não o Leandro,
-- com uma data de conexão de TESTE no passado para que D+1 já tenha
-- "chegado" sem precisar esperar dias reais. PostgreSQL local descartável.

\set ON_ERROR_STOP on
\pset format aligned

\echo '=== [1] register_connection (contato sintetico de teste, data de aceite ha 5 dias) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT connection_id AS synth_connection_id, status, scheduled_at
  FROM rufino_linkedin.register_connection(
    'mecanica-pipeline-teste-01', 'Fulano Sintetico de Teste', 'Fulano', 'Cargo Teste',
    'Instituicao Teste', 'Cidade Teste', 'https://www.linkedin.com/in/fulano-sintetico-teste/', NULL,
    (CURRENT_DATE - INTERVAL '5 days')::date,
    'resumo de teste', '[]'::jsonb, 'gancho de teste', 'justificativa de teste', 0.8, false, '[]'::jsonb,
    'mecanica-teste', 'Mensagem de teste, sem dado real, so para exercitar o pipeline.',
    'MECANICA-TESTE', 'exec-mec-1',
    'linkedin_mynetwork_confirmacao_manual', 'anderson-teste'
  ) \gset
RESET ROLE;
COMMIT;

\echo '=== [2] claim_due_connections -> D+1 (data de teste) ja passou, reivindica ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.claim_due_connections(50, 'MECANICA-TESTE', 'exec-mec-2');
RESET ROLE;
COMMIT;

\echo '=== [3] claim_notification_jobs -> reivindica job APPROVAL ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT raw_action_token AS approval_action_token, raw_claim_token AS approval_claim_token
  FROM rufino_linkedin.claim_notification_jobs(20, 'MECANICA-TESTE', 'exec-mec-3')
 WHERE job_type = 'APPROVAL' \gset
RESET ROLE;
COMMIT;

\echo '=== [4] confirm_notification_delivery (APPROVAL) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.confirm_notification_delivery(:'approval_claim_token', '999999999', '2001', 'MECANICA-TESTE', 'exec-mec-4');
RESET ROLE;
COMMIT;

\echo '=== [5] approve_message (Aprovar e preparar) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT connection_id AS synth_connection_id_2, new_status AS status_apos_aprovacao
  FROM rufino_linkedin.approve_message(:'approval_action_token', 'APROVAR_E_PREPARAR', 'telegram:anderson', 'cbq-mec-1', 'MECANICA-TESTE', 'exec-mec-5') \gset
RESET ROLE;
COMMIT;
\echo :status_apos_aprovacao

\echo '=== [6] resolve a versao vigente da mensagem ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT message_version_id AS synth_message_version_id
  FROM rufino_linkedin.message_versions WHERE connection_id = :'synth_connection_id_2'
 ORDER BY version DESC LIMIT 1 \gset
RESET ROLE;
COMMIT;

\echo '=== [7] present_message_for_delivery -> PRONTO_PARA_ENVIO, cria job DELIVERY ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.present_message_for_delivery(:'synth_connection_id_2', :'synth_message_version_id', 'sistema', 'MECANICA-TESTE', 'exec-mec-7');
RESET ROLE;
COMMIT;

\echo '=== [8] claim_notification_jobs -> reivindica job DELIVERY ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT raw_action_token AS delivery_action_token, raw_claim_token AS delivery_claim_token
  FROM rufino_linkedin.claim_notification_jobs(20, 'MECANICA-TESTE', 'exec-mec-8')
 WHERE job_type = 'DELIVERY' \gset
RESET ROLE;
COMMIT;

\echo '=== [9] confirm_notification_delivery (DELIVERY) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.confirm_notification_delivery(:'delivery_claim_token', '999999999', '2002', 'MECANICA-TESTE', 'exec-mec-9');
RESET ROLE;
COMMIT;

\echo '=== [10] mark_message_sent -> Anderson confirma envio MANUAL (nenhum envio real) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT followup_id AS synth_followup_id, new_status AS status_apos_envio
  FROM rufino_linkedin.mark_message_sent(:'delivery_action_token', 'MARCAR_ENVIADA', 'telegram:anderson', 'cbq-mec-2', (now() + INTERVAL '2 seconds'), 'MECANICA-TESTE', 'exec-mec-10') \gset
RESET ROLE;
COMMIT;
\echo :status_apos_envio

\echo '=== [10b] aguardando 3s para o follow-up ficar vencido ==='
SELECT pg_sleep(3);

\echo '=== [11] PREVENCAO DE DUPLICIDADE: nada mais pendente para esta conexao ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT count(*) AS deve_ser_0
  FROM rufino_linkedin.claim_notification_jobs(20, 'MECANICA-TESTE', 'exec-mec-11')
 WHERE connection_id = :'synth_connection_id_2';
RESET ROLE;
COMMIT;

\echo '=== [11b] PREVENCAO DE DUPLICIDADE: token de entrega reusado -> ERRO esperado ==='
\set ON_ERROR_STOP off
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.mark_message_sent(:'delivery_action_token', 'MARCAR_ENVIADA', 'telegram:anderson', 'cbq-mec-2-outro', now() + interval '1 day', 'MECANICA-TESTE', 'exec-mec-11b');
ROLLBACK;
\set ON_ERROR_STOP on
\echo '(ERRO acima esperado: token ja consumido)'

\echo '=== [12] claim_due_followups -> follow-up vencido, reivindica ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT raw_claim_token AS followup_claim_token
  FROM rufino_linkedin.claim_due_followups(50, 'MECANICA-TESTE', 'exec-mec-12')
 WHERE connection_id = :'synth_connection_id_2' \gset
RESET ROLE;
COMMIT;

\echo '=== [13] complete_followup(RESPONDEU) -> ENCERRADO (INTERRUPCAO apos resposta) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT new_connection_status AS status_final
  FROM rufino_linkedin.complete_followup(:'followup_claim_token', 'RESPONDEU', 'anderson', 'cbq-mec-3', NULL, NULL, 'MECANICA-TESTE', 'exec-mec-13') \gset
RESET ROLE;
COMMIT;
\echo :status_final

\echo '=== [14] confirma INTERRUPCAO real: nenhum followup novo fica reivindicavel ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT count(*) AS deve_ser_0
  FROM rufino_linkedin.claim_due_followups(50, 'MECANICA-TESTE', 'exec-mec-14')
 WHERE connection_id = :'synth_connection_id_2';
RESET ROLE;
COMMIT;

\echo '=== MECANICA COMPLETA DO PIPELINE CONFIRMADA (dados sinteticos, nao o Leandro) ==='
