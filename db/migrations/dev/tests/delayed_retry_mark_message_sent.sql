-- =============================================================================
-- delayed_retry_mark_message_sent.sql
-- Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.1, Correção 3
--
-- Prova, com passagem REAL de tempo de parede (não `now()` estável dentro
-- de uma única transação), que um retry atrasado de mark_message_sent
-- (mesmo callback_query_id, mesmos parâmetros, inclusive o mesmo
-- p_first_followup_at literal) continua idempotente mesmo depois que a
-- data agendada já passou de verdade.
--
-- Roda em modo autocommit (psql padrão, sem BEGIN explícito): cada
-- instrução commita sozinha, para que o `pg_sleep` no meio realmente
-- separe duas transações com "agora" diferentes — testar isso dentro de
-- uma transação única seria inútil, porque `now()` não muda até o commit.
--
-- NUNCA rodar contra o banco real rufino-linkedin-dev — só contra um
-- banco descartável já com a migration 001-007 aplicada.
-- =============================================================================

\set ON_ERROR_STOP on

SET ROLE n8n_rufino_linkedin_dev;

SELECT r.connection_id AS conn_id, r.message_version_id AS mv1
  FROM rufino_linkedin.register_connection(
    'delayedtest-marksent-v151', 'Delayed MarkSent', 'Delayed', 'Diretor', 'Escola Delayed', 'Curitiba',
    'https://linkedin.com/in/delayed-mark-sent-v151', NULL, CURRENT_DATE,
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
  FROM rufino_linkedin.approve_message(:'raw_action_1', 'APROVAR_E_PREPARAR', 'telegram:anderson', 'delayedtest-cbq-approve-marksent') r
\gset

\echo status apos aprovar: :status_after_approve

SELECT r.status AS status_after_present
  FROM rufino_linkedin.present_message_for_delivery(:'conn_id'::uuid, :'mv1'::uuid) r
\gset

\echo status apos apresentar: :status_after_present

SELECT nj.raw_action_token AS raw_action_2, nj.raw_claim_token AS raw_claim_2
  FROM rufino_linkedin.claim_notification_jobs(5) nj
 WHERE nj.connection_id = :'conn_id' AND nj.job_type = 'DELIVERY'
\gset

SELECT r.notification_job_id FROM rufino_linkedin.confirm_notification_delivery(:'raw_claim_2', 'chat-delayed', 'msg-delayed') r;

-- Valor literal fixo do primeiro follow-up -- CAPTURADO UMA VEZ e reusado
-- ao pé da letra no retry. Um `now() + interval '3 seconds'` recalculado
-- na segunda chamada teria um valor textual diferente, mudaria o
-- fingerprint, e seria (corretamente) tratado como conflito -- não é isso
-- que este teste quer provar. Um retry real do n8n reenviaria o mesmo
-- valor de data que calculou e enviou da primeira vez.
SELECT (now() + interval '3 seconds')::text AS first_followup_at
\gset

\echo p_first_followup_at fixado em: :first_followup_at

-- Primeira chamada.
SELECT r.delivery_event_id AS de1, r.connection_id AS c1, r.new_status AS s1, r.followup_id AS f1
  FROM rufino_linkedin.mark_message_sent(
    :'raw_action_2', 'MARCAR_ENVIADA', 'telegram:anderson', 'delayedtest-cbq-marksent',
    :'first_followup_at'::timestamptz
  ) r
\gset

\echo Primeira chamada -- delivery_event_id=:de1 connection_id=:c1 new_status=:s1 followup_id=:f1

-- Aguarda a data agendada passar DE VERDADE (commit real, tempo de parede
-- real -- não simulável dentro de uma transação).
SELECT pg_sleep(4);

SELECT now() > :'first_followup_at'::timestamptz AS data_ja_passou;

-- Retry: mesmo callback_query_id, mesmo action_token (já consumido pela
-- primeira chamada), mesmo p_first_followup_at literal -- agora no
-- passado de verdade. Antes da Correção 3, isso seria rejeitado por
-- "p_first_followup_at precisa ser uma data futura" antes mesmo de
-- checar callback_receipts.
SELECT r.delivery_event_id AS de2, r.connection_id AS c2, r.new_status AS s2, r.followup_id AS f2
  FROM rufino_linkedin.mark_message_sent(
    :'raw_action_2', 'MARCAR_ENVIADA', 'telegram:anderson', 'delayedtest-cbq-marksent',
    :'first_followup_at'::timestamptz
  ) r
\gset

\echo Retry atrasado -- delivery_event_id=:de2 connection_id=:c2 new_status=:s2 followup_id=:f2

-- event_type='MARCADO_COMO_ENVIADO' e o especifico de mark_message_sent
-- (present_message_for_delivery ja grava um outro evento,
-- MENSAGEM_APRESENTADA, para a mesma conexao -- contar todos os
-- delivery_events sem filtrar por tipo daria 2 de forma legitima, mesmo
-- sem nenhuma duplicacao pelo retry).
SELECT count(*) AS total_delivery_events FROM rufino_linkedin.delivery_events
 WHERE connection_id = :'conn_id' AND event_type = 'MARCADO_COMO_ENVIADO' \gset
SELECT count(*) AS total_followups FROM rufino_linkedin.followups WHERE connection_id = :'conn_id' \gset

-- Asserções via SQL puro (não DO $$...$$): psql NÃO interpola variáveis
-- :'var' dentro de blocos delimitados por dólar -- o texto seria enviado
-- literalmente ao servidor e falharia com "syntax error at or near :".
-- Cada assert é uma SELECT top-level; se a condição de falha for
-- verdadeira, o ramo THEN força um erro real (divisão por zero), que
-- interrompe o script sob \set ON_ERROR_STOP on. O ramo THEN só é avaliado
-- quando a condição é verdadeira (avaliação preguiçosa de CASE no
-- PostgreSQL), então o SELECT nunca falha quando a asserção passa.
SELECT CASE WHEN (:'de1' <> :'de2' OR :'c1' <> :'c2' OR :'s1' <> :'s2' OR :'f1' <> :'f2')
            THEN (SELECT 1/0) END AS assert_mesmo_resultado;

SELECT CASE WHEN :'total_delivery_events' <> '1'
            THEN (SELECT 1/0) END AS assert_nao_duplicou_delivery_events;

SELECT CASE WHEN :'total_followups' <> '1'
            THEN (SELECT 1/0) END AS assert_nao_duplicou_followups;

\echo OK: retry atrasado de mark_message_sent e idempotente mesmo apos p_first_followup_at ja ter passado de verdade -- delivery_event_id=:de1 followup_id=:f1 status=:s1

RESET ROLE;

-- Limpeza (autocommit -- estes dados foram commitados de verdade).
DELETE FROM rufino_linkedin.followups WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.delivery_events WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.callback_receipts WHERE callback_query_id IN ('delayedtest-cbq-approve-marksent', 'delayedtest-cbq-marksent');
DELETE FROM rufino_linkedin.approvals WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.action_tokens WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.notification_jobs WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.connection_status_history WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.message_versions WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.analyses WHERE connection_id = :'conn_id';
DELETE FROM rufino_linkedin.connections WHERE connection_id = :'conn_id';
