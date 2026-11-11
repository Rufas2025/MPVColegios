-- Ensaio REAL do CASO PILOTO 01 — Leandro — usa exatamente os dados e a
-- data de aceite CONFIRMADA VISUALMENTE por Anderson em
-- linkedin.com/mynetwork/invite-connect/connections/ (11/11/2026).
-- PostgreSQL local descartável — isto é um ENSAIO, não a aplicação real.
-- Nenhuma mensagem real é enviada; para a execução real, os mesmos
-- parâmetros abaixo seriam usados contra o banco rufino-linkedin-dev.
--
-- Propositalmente PARA depois do passo [5]: com a data real (hoje), o D+1
-- cai no futuro (12/11/2026 09:00 America/Sao_Paulo) — claim_due_connections
-- corretamente não encontra nada a reivindicar ainda. Isso é o
-- comportamento CORRETO, não uma falha. A mecânica completa do pipeline
-- (aprovação, envio, duplicidade, follow-up, interrupção) é testada à
-- parte, com dados sintéticos e uma data de teste, em
-- tests/pilot_01_mechanics_tests.sql — nunca com os dados reais do
-- Leandro, para não misturar ensaio com mecânica de teste.

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

\echo '=== [4] register_connection (WF-01) -- data REAL confirmada visualmente em linkedin.com/mynetwork (11/11/2026), origem auditavel ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_connection(
    'piloto-01-leandro', 'Leandro Henrique Ferreira da Silva', 'Leandro', 'Diretor de Unidade Escolar',
    'Rede de Ensino Colegium', 'Belo Horizonte/MG', 'https://www.linkedin.com/in/ferreiraleandro1993/', NULL,
    '2026-11-11'::date,
    'Diretor de Unidade Escolar na Rede Colegium (BH); antes, Rede Elite de Ensino; no Colegium desde abril/2024.',
    '[{"gancho":"Transicao Rede Elite -> Colegium","motivo":"trajetoria profissional confirmada"}]'::jsonb,
    'Trajetoria Rede Elite -> Colegium desde abril/2024', 'Fatos confirmados por Anderson (prints); mensagem sem proposta comercial', 0.8, false, '[]'::jsonb,
    'piloto-01-manual',
    'Fala, Leandro! Tudo bem? Que bacana termos nos conectado por aqui! Gosto muito das boas conversas e das trocas que o LinkedIn proporciona, especialmente com quem vive o dia a dia da educacao. Dei uma olhada na sua trajetoria e vi que voce passou pela Rede Elite de Ensino e hoje segue como Diretor de Unidade Escolar no Colegium, em Belo Horizonte, desde abril de 2024. Uma bonita jornada! Tambem estou no segmento educacional ha cerca de 15 anos e acredito muito no valor de trocar experiencias com quem esta a frente da gestao das escolas. Vamos mantendo contato e compartilhando ideias por aqui! Grande abraco, Rufino',
    'PILOTO-01', 'exec-pilot-4',
    'linkedin_mynetwork_confirmacao_manual', 'anderson'
);
RESET ROLE;
COMMIT;
\echo '(scheduled_at acima deve ser 12/11/2026 09:00 America/Sao_Paulo = 12:00 UTC, pelo horario operacional padrao)'

\echo '=== [5] link_prospect_to_connection -> prospect vira CONECTADO ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.link_prospect_to_connection(
    (SELECT connection_id FROM rufino_linkedin.connections WHERE idempotency_key = 'piloto-01-leandro'),
    'PILOTO-01', 'exec-pilot-5'
);
RESET ROLE;
COMMIT;
SELECT status FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/ferreiraleandro1993';

\echo '=== [6] claim_due_connections (WF-02) HOJE -- esperado 0 linhas: D+1 ainda nao chegou (12/11/2026), comportamento correto ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT count(*) AS deve_ser_0_hoje_ainda_nao_e_D1
  FROM rufino_linkedin.claim_due_connections(50, 'PILOTO-01', 'exec-pilot-6');
RESET ROLE;
COMMIT;

\echo '=== [7] Auditoria gravada: origem e confirmador da data ==='
SELECT idempotency_key, data_conexao, data_conexao_origem, data_conexao_confirmado_por, scheduled_at, status
  FROM rufino_linkedin.connections WHERE idempotency_key = 'piloto-01-leandro';

\echo '=== ENSAIO REAL DO LEANDRO CONCLUIDO -- aguardando D+1 (12/11/2026 09:00) para o pipeline seguir sozinho ==='
\echo '=== Mecanica completa do pipeline (aprovacao/envio/duplicidade/followup/interrupcao) testada separadamente em tests/pilot_01_mechanics_tests.sql ==='
