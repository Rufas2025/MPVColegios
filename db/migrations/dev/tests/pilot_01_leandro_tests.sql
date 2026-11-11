-- Teste do CASO PILOTO 01 — Leandro — ciclo completo com dados reais do
-- Leandro e uma data de aceite de TESTE (NÃO confirmada por Anderson).
-- PostgreSQL local descartável — NUNCA contra o banco real. Nenhuma
-- mensagem real é enviada; "Telegram"/"LinkedIn" são só nomes de etapa,
-- simulados pela própria chamada de função.

\set ON_ERROR_STOP on
\pset format aligned

\echo '=== [1] register_prospect (Leandro) -> IDENTIFICADO ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/ferreiraleandro1993/',
    'Leandro Henrique Ferreira da Silva', 'Leandro', 'Diretor de Unidade Escolar', 'Belo Horizonte/MG',
    'Rede de Ensino Colegium', NULL, NULL, 'icp_reference_manual_piloto01', 'PILOTO-01', 'exec-pilot-1'
);
RESET ROLE;
COMMIT;

\echo '=== [2] register_prospect chamado 2x (mesma URL) -> idempotente, nao duplica ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/ferreiraleandro1993/',
    'Leandro Henrique Ferreira da Silva', 'Leandro', 'Diretor de Unidade Escolar', 'Belo Horizonte/MG',
    'Rede de Ensino Colegium', NULL, NULL, 'icp_reference_manual_piloto01', 'PILOTO-01', 'exec-pilot-2'
);
RESET ROLE;
COMMIT;
SELECT count(*) AS deve_ser_1 FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/ferreiraleandro1993';

\echo '=== [3] qualify_prospect -> QUALIFICADO, P2 (sujeito a validacao) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT rufino_linkedin.qualify_prospect(
    prospect_id, 'P2', 'Diretor de Unidade Escolar, Rede Colegium', 'piloto 01 - classificacao sujeita a validacao', 'anderson', 'PILOTO-01', 'exec-pilot-3'
) FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/ferreiraleandro1993';
RESET ROLE;
COMMIT;

\echo '=== [4] register_connection (WF-01) -- data de aceite de TESTE (5 dias atras, NAO CONFIRMADA por Anderson) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_connection(
    'piloto-01-leandro-TESTE', 'Leandro Henrique Ferreira da Silva', 'Leandro', 'Diretor de Unidade Escolar',
    'Rede de Ensino Colegium', 'Belo Horizonte/MG', 'https://www.linkedin.com/in/ferreiraleandro1993/', NULL,
    (CURRENT_DATE - INTERVAL '5 days')::date,
    'Diretor de Unidade Escolar na Rede Colegium (BH); antes, Rede Elite de Ensino; no Colegium desde abril/2024.',
    '[{"gancho":"Transicao Rede Elite -> Colegium","motivo":"trajetoria profissional confirmada"}]'::jsonb,
    'Trajetoria Rede Elite -> Colegium desde abril/2024', 'Fatos confirmados por Anderson (prints); mensagem sem proposta comercial', 0.8, false, '[]'::jsonb,
    'piloto-01-manual',
    'Fala, Leandro! Tudo bem? Que bacana termos nos conectado por aqui! Gosto muito das boas conversas e das trocas que o LinkedIn proporciona, especialmente com quem vive o dia a dia da educacao. Dei uma olhada na sua trajetoria e vi que voce passou pela Rede Elite de Ensino e hoje segue como Diretor de Unidade Escolar no Colegium, em Belo Horizonte, desde abril de 2024. Uma bonita jornada! Tambem estou no segmento educacional ha cerca de 15 anos e acredito muito no valor de trocar experiencias com quem esta a frente da gestao das escolas. Vamos mantendo contato e compartilhando ideias por aqui! Grande abraco, Rufino',
    'PILOTO-01', 'exec-pilot-4'
);
RESET ROLE;
COMMIT;

\echo '=== [5] link_prospect_to_connection -> prospect vira CONECTADO ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.link_prospect_to_connection(
    (SELECT connection_id FROM rufino_linkedin.connections WHERE idempotency_key = 'piloto-01-leandro-TESTE'),
    'PILOTO-01', 'exec-pilot-5'
);
RESET ROLE;
COMMIT;
SELECT status FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/ferreiraleandro1993';

\echo '=== [6] claim_due_connections (WF-02) -> D+1 ja passou (data de teste): reivindica e cria job APPROVAL no outbox ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.claim_due_connections(50, 'PILOTO-01', 'exec-pilot-6');
RESET ROLE;
COMMIT;

\echo '=== [7] claim_notification_jobs (WF-NOTIFY) -> reivindica o job APPROVAL, gera o action_token ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT raw_action_token AS approval_action_token, raw_claim_token AS approval_claim_token,
       notification_job_id AS approval_job_id, connection_id AS leandro_connection_id
  FROM rufino_linkedin.claim_notification_jobs(20, 'PILOTO-01', 'exec-pilot-7')
 WHERE job_type = 'APPROVAL' \gset
RESET ROLE;
COMMIT;
\echo 'approval_action_token capturado, approval_claim_token capturado'

\echo '=== [8] confirm_notification_delivery -> confirma que a notificacao de aprovacao "chegou" no Telegram (sem chamada real) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.confirm_notification_delivery(
    :'approval_claim_token', '999999999', '1001', 'PILOTO-01', 'exec-pilot-8'
);
RESET ROLE;
COMMIT;

\echo '=== [9] approve_message -> aprovacao humana (Aprovar e preparar) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT connection_id AS leandro_connection_id_2, new_status AS status_apos_aprovacao
  FROM rufino_linkedin.approve_message(
    :'approval_action_token', 'APROVAR_E_PREPARAR', 'telegram:anderson', 'cbq-pilot-1', 'PILOTO-01', 'exec-pilot-9'
  ) \gset
RESET ROLE;
COMMIT;
\echo 'status apos aprovacao:'
\echo :status_apos_aprovacao

\echo '=== [10] Resolve a versao vigente da mensagem (mesmo padrao do WF-03 real) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT message_version_id AS leandro_message_version_id
  FROM rufino_linkedin.message_versions
 WHERE connection_id = :'leandro_connection_id_2'
 ORDER BY version DESC LIMIT 1 \gset
RESET ROLE;
COMMIT;

\echo '=== [11] present_message_for_delivery -> PRONTO_PARA_ENVIO, cria job DELIVERY no outbox ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.present_message_for_delivery(
    :'leandro_connection_id_2', :'leandro_message_version_id', 'sistema', 'PILOTO-01', 'exec-pilot-11'
);
RESET ROLE;
COMMIT;

\echo '=== [12] claim_notification_jobs -> reivindica o job DELIVERY (mensagem pronta para Anderson copiar e enviar) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT raw_action_token AS delivery_action_token, raw_claim_token AS delivery_claim_token
  FROM rufino_linkedin.claim_notification_jobs(20, 'PILOTO-01', 'exec-pilot-12')
 WHERE job_type = 'DELIVERY' \gset
RESET ROLE;
COMMIT;

\echo '=== [13] confirm_notification_delivery -> confirma que a notificacao de entrega "chegou" no Telegram ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.confirm_notification_delivery(
    :'delivery_claim_token', '999999999', '1002', 'PILOTO-01', 'exec-pilot-13'
);
RESET ROLE;
COMMIT;

\echo '=== [14] mark_message_sent -> Anderson confirma que enviou MANUALMENTE no LinkedIn (nenhum envio real ocorreu aqui) ==='
-- p_first_followup_at precisa ser futuro no momento da chamada (regra de
-- negocio real, nao um bug) -- usamos poucos segundos no futuro e esperamos
-- a passagem real de tempo de parede antes de reivindicar o follow-up,
-- mesmo padrao ja usado nos testes de retry atrasado da v1.5.1.
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT followup_id AS leandro_followup_id, new_status AS status_apos_envio
  FROM rufino_linkedin.mark_message_sent(
    :'delivery_action_token', 'MARCAR_ENVIADA', 'telegram:anderson', 'cbq-pilot-2',
    (now() + INTERVAL '2 seconds'), 'PILOTO-01', 'exec-pilot-14'
  ) \gset
RESET ROLE;
COMMIT;
\echo 'status apos marcar enviada:'
\echo :status_apos_envio

\echo '=== [14b] aguardando a passagem real de tempo (3s) para o follow-up ficar vencido ==='
SELECT pg_sleep(3);

\echo '=== [15] PREVENCAO DE ENVIO DUPLICADO: reivindicar notification_jobs de novo -> 0 linhas (nada pendente para esta conexao) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT count(*) AS deve_ser_0
  FROM rufino_linkedin.claim_notification_jobs(20, 'PILOTO-01', 'exec-pilot-15')
 WHERE connection_id = :'leandro_connection_id_2';
RESET ROLE;
COMMIT;

\echo '=== [15b] PREVENCAO DE ENVIO DUPLICADO: reusar o mesmo action_token de entrega -> deve dar ERRO (token ja consumido) ==='
\set ON_ERROR_STOP off
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.mark_message_sent(
    :'delivery_action_token', 'MARCAR_ENVIADA', 'telegram:anderson', 'cbq-pilot-2-outro',
    now() + interval '1 day', 'PILOTO-01', 'exec-pilot-15b'
);
ROLLBACK;
\set ON_ERROR_STOP on
\echo '(o ERRO acima e o resultado esperado -- confirma que o token consumido nao pode ser reutilizado)'

\echo '=== [16] claim_due_followups (WF-05) -> follow-up ja vencido (data de teste), reivindica ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT raw_claim_token AS followup_claim_token
  FROM rufino_linkedin.claim_due_followups(50, 'PILOTO-01', 'exec-pilot-16')
 WHERE connection_id = :'leandro_connection_id_2' \gset
RESET ROLE;
COMMIT;

\echo '=== [17] complete_followup(RESPONDEU) -> ENCERRADO (INTERRUPCAO apos resposta) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT new_connection_status AS status_final
  FROM rufino_linkedin.complete_followup(
    :'followup_claim_token', 'RESPONDEU', 'anderson', 'cbq-pilot-3', NULL, NULL, 'PILOTO-01', 'exec-pilot-17'
  ) \gset
RESET ROLE;
COMMIT;
\echo 'status final da conexao:'
\echo :status_final

\echo '=== [18] Confirma INTERRUPCAO real: nenhum novo follow-up fica vencido/reivindicavel apos RESPONDEU ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT count(*) AS deve_ser_0_followups_pendentes
  FROM rufino_linkedin.claim_due_followups(50, 'PILOTO-01', 'exec-pilot-18')
 WHERE connection_id = :'leandro_connection_id_2';
RESET ROLE;
COMMIT;

\echo '=== [19] Status final na tabela connections ==='
SELECT status FROM rufino_linkedin.connections WHERE idempotency_key = 'piloto-01-leandro-TESTE';

\echo '=== CICLO COMPLETO DO PILOTO 01 (LEANDRO) PASSOU, INCLUINDO DUPLICIDADE E INTERRUPCAO ==='
