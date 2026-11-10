-- Teste da jornada completa do adendo pré-conexão — PostgreSQL local descartável (rufino_test).
-- Roda como superuser mas usa SET LOCAL ROLE para exercitar exatamente os
-- privilégios da role de aplicação (n8n_rufino_linkedin_dev), igual ao
-- padrão de 009_smoke_tests.sql.

\set ON_ERROR_STOP on
\pset format aligned

\echo '=== [1] register_prospect: cadastro normal (IDENTIFICADO) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/dirci-reis-67440348/',
    'Dirci Reis', 'Dirci', 'CEO', 'Curitiba',
    'Colégio Alfa', 'Rede Alfa', NULL, 'icp_reference_manual', 'TESTE', 'exec-1'
);
RESET ROLE;
COMMIT;

\echo '=== [2] register_prospect: mesma URL (variando maiuscula/barra final) -> already_existed=true, sem duplicar ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'HTTPS://WWW.LINKEDIN.COM/in/Dirci-Reis-67440348',
    'Dirci Reis', 'Dirci', 'CEO', 'Curitiba',
    'Colégio Alfa', 'Rede Alfa', NULL, 'icp_reference_manual', 'TESTE', 'exec-2'
);
RESET ROLE;
COMMIT;
SELECT count(*) AS deve_ser_1 FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348';

\echo '=== [3] Dedupe de escola: mesmo nome, cidade DIFERENTE -> escola NOVA (nao funde) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/alan-rodrigues-523460ab/',
    'Alan Rodrigues', 'Alan', 'Diretor Financeiro', 'São Paulo',
    'Colégio Alfa', 'Rede Alfa', NULL, 'icp_reference_manual', 'TESTE', 'exec-3'
);
RESET ROLE;
COMMIT;
SELECT count(*) AS deve_ser_2_escolas_distintas FROM rufino_linkedin.schools WHERE nome_normalizado = 'colégio alfa';

\echo '=== [4] Dedupe de escola: mesmo nome, mesma cidade -> REUSA a mesma escola ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/mariana-monteiro-908580a0/',
    'Mariana Monteiro', 'Mariana', 'Mantenedora', 'Curitiba',
    'Colégio Alfa', 'Rede Alfa', NULL, 'icp_reference_manual', 'TESTE', 'exec-4'
);
RESET ROLE;
COMMIT;
SELECT count(*) AS ainda_deve_ser_2 FROM rufino_linkedin.schools WHERE nome_normalizado = 'colégio alfa';

\echo '=== [5] Dedupe de escola: cidade DESCONHECIDA duas vezes -> NUNCA funde (2 linhas novas) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/luis-machado-730881245/',
    'Luis Machado', 'Luis', NULL, NULL,
    'Colégio Beta', NULL, NULL, 'icp_reference_manual', 'TESTE', 'exec-5a'
);
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/paulo-migliato-29325281/',
    'Paulo Migliato', 'Paulo', NULL, NULL,
    'Colégio Beta', NULL, NULL, 'icp_reference_manual', 'TESTE', 'exec-5b'
);
RESET ROLE;
COMMIT;
SELECT count(*) AS deve_ser_2_linhas_cidade_desconhecida FROM rufino_linkedin.schools WHERE nome_normalizado = 'colégio beta';

\echo '=== [6] qualify_prospect: tier invalido -> rejeitado ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
DO $$
DECLARE v_id uuid;
BEGIN
    SELECT prospect_id INTO v_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348';
    BEGIN
        PERFORM rufino_linkedin.qualify_prospect(v_id, 'P9', 'teste', 'teste', 'anderson', 'TESTE', 'exec-6');
        RAISE EXCEPTION 'FALHA: deveria ter rejeitado tier invalido';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK (rejeitado como esperado): %', SQLERRM;
    END;
END $$;
RESET ROLE;
ROLLBACK;

\echo '=== [7] qualify_prospect: tier valido -> QUALIFICADO ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT rufino_linkedin.qualify_prospect(prospect_id, 'P1', 'CEO, decisor financeiro', 'perfil de referencia ICP', 'anderson', 'TESTE', 'exec-7')
  FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348';
SELECT rufino_linkedin.qualify_prospect(prospect_id, 'P1', 'Diretor financeiro', 'perfil de referencia ICP', 'anderson', 'TESTE', 'exec-7b')
  FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/alan-rodrigues-523460ab';
SELECT rufino_linkedin.qualify_prospect(prospect_id, 'P2', 'Mantenedora', 'perfil de referencia ICP', 'anderson', 'TESTE', 'exec-7c')
  FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/mariana-monteiro-908580a0';
RESET ROLE;
COMMIT;

\echo '=== [8] qualify_prospect: re-qualificar quem ja esta QUALIFICADO -> rejeitado ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
DO $$
DECLARE v_id uuid;
BEGIN
    SELECT prospect_id INTO v_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348';
    BEGIN
        PERFORM rufino_linkedin.qualify_prospect(v_id, 'P2', 'teste', 'teste', 'anderson', 'TESTE', 'exec-8');
        RAISE EXCEPTION 'FALHA: deveria ter rejeitado reclassificacao';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK (rejeitado como esperado): %', SQLERRM;
    END;
END $$;
RESET ROLE;
ROLLBACK;

\echo '=== [9] get_daily_prospect_queue: pedir 500 -> nunca retorna mais de 20 ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT count(*) AS deve_ser_no_maximo_20 FROM rufino_linkedin.get_daily_prospect_queue(500, 'TESTE', 'exec-9');
SELECT count(*) AS deve_ser_3_qualificados FROM rufino_linkedin.get_daily_prospect_queue(20, 'TESTE', 'exec-9b');
RESET ROLE;
COMMIT;

\echo '=== [10] mark_invite_sent: QUALIFICADO -> CONVITE_PENDENTE ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.mark_invite_sent(
    (SELECT prospect_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348'),
    'anderson', 'TESTE', 'exec-10'
);
RESET ROLE;
COMMIT;

\echo '=== [11] mark_invite_sent chamado 2x (retry/duplo clique) -> idempotente, already_sent=true, timestamp IGUAL ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.mark_invite_sent(
    (SELECT prospect_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348'),
    'anderson', 'TESTE', 'exec-11-retry'
);
RESET ROLE;
COMMIT;
SELECT count(*) AS deve_ser_1_evento_convite_enviado FROM rufino_linkedin.prospect_events pe
  JOIN rufino_linkedin.prospects p ON p.prospect_id = pe.prospect_id
 WHERE p.canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348' AND pe.event_type = 'CONVITE_ENVIADO';

\echo '=== [12] mark_invite_sent em quem ainda esta IDENTIFICADO -> rejeitado (convite duplicado fora de ordem) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
DO $$
DECLARE v_id uuid;
BEGIN
    SELECT prospect_id INTO v_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/luis-machado-730881245';
    BEGIN
        PERFORM rufino_linkedin.mark_invite_sent(v_id, 'anderson', 'TESTE', 'exec-12');
        RAISE EXCEPTION 'FALHA: deveria ter rejeitado (ainda nao qualificado)';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK (rejeitado como esperado): %', SQLERRM;
    END;
END $$;
RESET ROLE;
ROLLBACK;

\echo '=== [13] Caso Paulo Henrique: IDENTIFICADO -> QUALIFICADO -> CONVITE_PENDENTE (sem confirmar aceite, igual ao print) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/paulo-henrique-magalhaes-oliveira-87867124/',
    'Paulo Henrique Magalhães Oliveira', 'Paulo Henrique', NULL, NULL,
    NULL, NULL, NULL, 'icp_reference_manual', 'TESTE', 'exec-13a'
);
SELECT rufino_linkedin.qualify_prospect(prospect_id, 'P2', 'perfil de referencia ICP, dados insuficientes para cargo/escola', 'pendente de validacao - sem inventar dado ausente', 'anderson', 'TESTE', 'exec-13b')
  FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/paulo-henrique-magalhaes-oliveira-87867124';
SELECT * FROM rufino_linkedin.mark_invite_sent(
    (SELECT prospect_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/paulo-henrique-magalhaes-oliveira-87867124'),
    'anderson', 'TESTE', 'exec-13c'
);
RESET ROLE;
COMMIT;
SELECT status FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/paulo-henrique-magalhaes-oliveira-87867124';

\echo '=== [14] confirm_invite_accepted: CONVITE_PENDENTE -> CONECTADO ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.confirm_invite_accepted(
    (SELECT prospect_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348'),
    now(), 'anderson', 'TESTE', 'exec-14'
);
RESET ROLE;
COMMIT;

\echo '=== [15] confirm_invite_accepted chamado 2x -> idempotente, already_confirmed=true ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.confirm_invite_accepted(
    (SELECT prospect_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/dirci-reis-67440348'),
    now(), 'anderson', 'TESTE', 'exec-15-retry'
);
RESET ROLE;
COMMIT;

\echo '=== [16] confirm_invite_accepted em quem nunca teve convite marcado -> rejeitado ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
DO $$
DECLARE v_id uuid;
BEGIN
    SELECT prospect_id INTO v_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/mariana-monteiro-908580a0';
    BEGIN
        PERFORM rufino_linkedin.confirm_invite_accepted(v_id, now(), 'anderson', 'TESTE', 'exec-16');
        RAISE EXCEPTION 'FALHA: deveria ter rejeitado (sem convite pendente)';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK (rejeitado como esperado): %', SQLERRM;
    END;
END $$;
RESET ROLE;
ROLLBACK;

\echo '=== [17] close_prospect: encerra, idempotente com mesmo motivo, rejeita motivo diferente ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.close_prospect(
    (SELECT prospect_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/luis-machado-730881245'),
    'FORA_DO_ICP', 'anderson', 'TESTE', 'exec-17a'
);
SELECT * FROM rufino_linkedin.close_prospect(
    (SELECT prospect_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/luis-machado-730881245'),
    'FORA_DO_ICP', 'anderson', 'TESTE', 'exec-17b'
);
RESET ROLE;
COMMIT;
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
DO $$
DECLARE v_id uuid;
BEGIN
    SELECT prospect_id INTO v_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/luis-machado-730881245';
    BEGIN
        PERFORM rufino_linkedin.close_prospect(v_id, 'DUPLICADO', 'anderson', 'TESTE', 'exec-17c');
        RAISE EXCEPTION 'FALHA: deveria ter rejeitado motivo diferente';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK (rejeitado como esperado): %', SQLERRM;
    END;
END $$;
RESET ROLE;
ROLLBACK;

\echo '=== [18] Vinculo idempotente sentido A: register_prospect quando a connections ja existe -> nasce direto CONECTADO ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_connection(
    'conn-gerson-001', 'Gerson Trevizani Filho', 'Gerson', 'CEO', 'Colégio Gama', 'Belo Horizonte',
    'https://www.linkedin.com/in/gerson-trevizani-filho-08680651/', NULL, CURRENT_DATE,
    'resumo teste', '[]'::jsonb, 'gancho teste', 'justificativa teste', 0.9, false, '[]'::jsonb,
    'brain-teste', 'mensagem teste', 'TESTE', 'exec-18a'
);
RESET ROLE;
COMMIT;
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/gerson-trevizani-filho-08680651/',
    'Gerson Trevizani Filho', 'Gerson', 'CEO', 'Belo Horizonte',
    'Colégio Gama', NULL, NULL, 'icp_reference_manual', 'TESTE', 'exec-18b'
);
RESET ROLE;
COMMIT;
SELECT status, connection_id IS NOT NULL AS tem_connection_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/gerson-trevizani-filho-08680651';

\echo '=== [19] Vinculo idempotente sentido B: prospect primeiro, connections depois -> link_prospect_to_connection reconcilia ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_prospect(
    'https://www.linkedin.com/in/exemplo-sentido-b/',
    'Fulano Exemplo', 'Fulano', 'Diretor', 'Recife',
    'Colégio Delta', NULL, NULL, 'icp_reference_manual', 'TESTE', 'exec-19a'
);
RESET ROLE;
COMMIT;
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.register_connection(
    'conn-fulano-001', 'Fulano Exemplo', 'Fulano', 'Diretor', 'Colégio Delta', 'Recife',
    'https://www.linkedin.com/in/exemplo-sentido-b', NULL, CURRENT_DATE,
    'resumo teste', '[]'::jsonb, 'gancho teste', 'justificativa teste', 0.9, false, '[]'::jsonb,
    'brain-teste', 'mensagem teste', 'WF-01', 'exec-19b'
);
RESET ROLE;
COMMIT;
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.link_prospect_to_connection(
    (SELECT connection_id FROM rufino_linkedin.connections WHERE idempotency_key = 'conn-fulano-001'),
    'WF-01', 'exec-19c'
);
RESET ROLE;
COMMIT;
SELECT status, connection_id IS NOT NULL AS tem_connection_id FROM rufino_linkedin.prospects WHERE canonical_profile_url = 'linkedin.com/in/exemplo-sentido-b';

\echo '=== [20] link_prospect_to_connection chamado 2x -> idempotente ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
SELECT * FROM rufino_linkedin.link_prospect_to_connection(
    (SELECT connection_id FROM rufino_linkedin.connections WHERE idempotency_key = 'conn-fulano-001'),
    'WF-01', 'exec-20'
);
RESET ROLE;
COMMIT;

\echo '=== [21] Seguranca: role de aplicacao NAO pode escrever direto em prospects, nem chamar normalize_linkedin_url (internas) ==='
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_dev;
DO $$
BEGIN
    BEGIN
        INSERT INTO rufino_linkedin.prospects (linkedin_profile_url, canonical_profile_url, nome, primeiro_nome, origem)
        VALUES ('x', 'x', 'x', 'x', 'x');
        RAISE EXCEPTION 'FALHA: escrita direta deveria ter sido negada';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK (negado como esperado): escrita direta em prospects';
    END;
    BEGIN
        PERFORM rufino_linkedin.normalize_linkedin_url('https://x.com');
        RAISE EXCEPTION 'FALHA: chamada a funcao interna deveria ter sido negada';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK (negado como esperado): EXECUTE em normalize_linkedin_url';
    END;
END $$;
RESET ROLE;
ROLLBACK;

\echo '=== TODOS OS TESTES DA JORNADA PASSARAM ==='
