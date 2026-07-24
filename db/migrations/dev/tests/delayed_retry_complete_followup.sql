-- =============================================================================
-- delayed_retry_complete_followup.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.1, Correção 3
--
-- Mesmo princípio de delayed_retry_mark_message_sent.sql, agora para
-- complete_followup: primeira chamada com p_next_followup_at poucos
-- segundos no futuro, COMMIT real, espera de verdade a data passar, e
-- retry com o MESMO callback_query_id e o MESMO p_next_followup_at
-- literal — deve devolver exatamente o mesmo resultado, sem duplicar
-- follow-up/transição/histórico, e sem ser rejeitado pela checagem de
-- "data futura" (que só se aplica à primeira chamada, depois da Correção 3).
--
-- Autocommit (sem BEGIN explícito) — necessário para que o `pg_sleep`
-- realmente separe duas transações com "agora" diferentes.
--
-- NUNCA rodar contra o banco real rufino-linkedin-dev — só contra um
-- banco descartável já com a migration 001-007 aplicada.
-- =============================================================================

\set ON_ERROR_STOP on

SET ROLE n8n_rufino_linkedin_dev;

SELECT r.connection_id AS conn_id, r.message_version_id AS mv1
  FROM rufino_linkedin.register_connection(
    'delayedtest-followup-v151', 'Delayed Followup', 'Delayed', 'Diretor', 'Escola Delayed', 'Curitiba',
    'https://linkedin.com/in/delayed-followup-v151', NULL, CURRENT_DATE,
    'Resumo', '["g1"]'::jsonb, 'g1', 'Justificativa', 0.9, false, '[]'::jsonb, 'brain-test-delayed', 'Mensagem inicial delayed'
  ) r
\gset

RESET ROLE;
UPDATE rufino_linkedin.connections SET scheduled_at = now() - interval '1 minute' WHERE connection_id = :'conn_id';
SET ROLE n8n_rufino_linkedin_dev;

SELECT c.connection_id FROM rufino_linkedin.claim_due_connections(5) c WHERE c.connection_id = :'conn_id';

SELECT nj.raw_action_token AS raw_action_1
  FROM rufino_linkedin.claim_notification_jobs(5) nj
 WHERE nj.connection_id = :'conn_id' AND nj.job_type = 'APPROVAL'
\gset

SELECT r.new_status AS status_after_approve
  FROM rufino_linkedin.approve_message(:'raw_action_1', 'APROVAR_E_PREPARAR', 'telegram:anderson', 'delayedtest-cbq-approve-followup') r
\gset

SELECT r.status AS status_after_present
  FROM rufino_linkedin.present_message_for_delivery(:'conn_id'::uuid, :'mv1'::uuid) r
\gset

SELECT nj.raw_action_token AS raw_action_2, nj.raw_claim_token AS raw_claim_2
  FROM rufino_linkedin.claim_notification_jobs(5) nj
 WHERE nj.connection_id = :'conn_id' AND nj.job_type = 'DELIVERY'
\gset

SELECT r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(:'raw_claim_2', 'chat-delayed-f', 'msg-delayed-f') r;

SELECT r.followup_id AS first_followup_id
  FROM rufino_linkedin.mark_message_sent(
    :'raw_action_2', 'MARCAR_ENVIADA', 'telegram:anderson', 'delayedtest-cbq-marksent-followup',
    now() + interval '2 days'
  ) r
\gset

-- claim_due_followups só reivindica scheduled_for <= now() -- o mesmo
-- ajuste administrativo usado em 009_smoke_tests.sql para tornar o
-- follow-up "devido" imediatamente, sem esperar os 2 dias de verdade.
RESET ROLE;
UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute'
 WHERE followup_id = :'first_followup_id';
SET ROLE n8n_rufino_linkedin_dev;

SELECT f.raw_claim_token AS claim_token
  FROM rufino_linkedin.claim_due_followups(5) f
 WHERE f.followup_id = :'first_followup_id'
\gset

\echo followup reivindicado: :first_followup_id

-- Valor literal fixo, capturado uma vez e reusado ao pé da letra no
-- retry (o fingerprint depende do texto exato de p_next_followup_at).
SELECT (now() + interval '3 seconds')::text AS next_followup_at
\gset

\echo p_next_followup_at fixado em: :next_followup_at

-- Primeira chamada: SEM_RESPOSTA com proxima data marcada poucos
-- segundos no futuro.
SELECT r.followup_id AS fid1, r.connection_id AS c1, r.resultado AS res1,
       r.new_connection_status AS s1, r.next_followup_id AS nf1, r.next_followup_sequence AS nseq1
  FROM rufino_linkedin.complete_followup(
    :'claim_token', 'SEM_RESPOSTA', 'anderson', 'delayedtest-cbq-followup',
    NULL, :'next_followup_at'::timestamptz
  ) r
\gset

\echo Primeira chamada -- followup_id=:fid1 status=:s1 next_followup_id=:nf1 next_seq=:nseq1

SELECT pg_sleep(4);

SELECT now() > :'next_followup_at'::timestamptz AS data_ja_passou;

-- Retry: mesmo callback_query_id, mesmo claim_token (já invalidado pela
-- primeira chamada), mesmo p_next_followup_at literal -- agora no
-- passado de verdade. Antes da Correção 3, seria rejeitado por
-- "p_next_followup_at precisa ser uma data futura" antes de checar
-- callback_receipts.
SELECT r.followup_id AS fid2, r.connection_id AS c2, r.resultado AS res2,
       r.new_connection_status AS s2, r.next_followup_id AS nf2, r.next_followup_sequence AS nseq2
  FROM rufino_linkedin.complete_followup(
    :'claim_token', 'SEM_RESPOSTA', 'anderson', 'delayedtest-cbq-followup',
    NULL, :'next_followup_at'::timestamptz
  ) r
\gset

\echo Retry atrasado -- followup_id=:fid2 status=:s2 next_followup_id=:nf2 next_seq=:nseq2

SELECT count(*) AS total_followups FROM rufino_linkedin.followups WHERE connection_id = :'conn_id' \gset
-- Esperado: 2 (sequence=1 encerrado, sequence=2 criado uma unica vez).

-- Asserções via SQL puro (não DO $$...$$): psql NÃO interpola variáveis
-- :'var' dentro de blocos delimitados por dólar. Cada assert é uma SELECT
-- top-level; o ramo THEN só é avaliado (e só então força um erro real de
-- divisão por zero) quando a condição de falha é verdadeira.
SELECT CASE WHEN (:'fid1' <> :'fid2' OR :'s1' <> :'s2' OR :'nf1' <> :'nf2' OR :'nseq1' <> :'nseq2')
            THEN (SELECT 1/0) END AS assert_mesmo_resultado;

SELECT CASE WHEN :'total_followups' <> '2'
            THEN (SELECT 1/0) END AS assert_nao_duplicou_followups;

\echo OK: retry atrasado de complete_followup e idempotente mesmo apos p_next_followup_at ja ter passado de verdade -- followup_id=:fid1 next_followup_id=:nf1 status=:s1

RESET ROLE;

-- Limpeza (autocommit -- estes dados foram commitados de verdade).
DELETE FROM rufino_linkedin.followups WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.delivery_events WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.callback_receipts WHERE callback_query_id IN ('delayedtest-cbq-approve-followup', 'delayedtest-cbq-marksent-followup', 'delayedtest-cbq-followup');
DELETE FROM rufino_linkedin.approvals WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.action_tokens WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.notification_jobs WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.connection_status_history WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.message_versions WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.analyses WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.connections WHERE connection_id = :'conn_id';
