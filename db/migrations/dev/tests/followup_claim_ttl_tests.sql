-- =============================================================================
-- tests/followup_claim_ttl_tests.sql
-- Testes da 015 (claim de follow-up com validade de 7 dias), só em banco
-- local descartável. Roda dentro de BEGIN ... ROLLBACK: não deixa dados.
--
--   psql -v ON_ERROR_STOP=1 -p 55432 -d rufino-linkedin-dev -f tests/followup_claim_ttl_tests.sql
-- =============================================================================

BEGIN;

DO $t$
DECLARE
    v_conn        uuid;
    v_fu1         uuid;
    v_tok1        text;
    v_tok1b       text;
    v_exp         timestamptz;
    v_n           integer;
    v_r           record;
    v_r2          record;
    v_tok2        text;
    v_status      text;
    v_err         text;
BEGIN
    -- Conexão sintética já em FOLLOWUP_PENDENTE com um follow-up vencido.
    SELECT r.connection_id INTO v_conn FROM rufino_linkedin.register_connection(
        'teste-015-followup', 'Pessoa Teste 015', 'Pessoa', 'Diretora', 'Colégio Teste', NULL,
        'https://www.linkedin.com/in/teste-015/', NULL, current_date - 10, 'resumo', '[]'::jsonb,
        'gancho', 'just', 0.6, false, '[]'::jsonb, 'teste', 'mensagem teste', 'TESTE-015', NULL,
        'linkedin_email_notificacao_aceite', 'sistema:teste') r;
    UPDATE rufino_linkedin.connections SET status = 'FOLLOWUP_PENDENTE' WHERE connection_id = v_conn;
    INSERT INTO rufino_linkedin.followups (connection_id, sequence, scheduled_for)
    VALUES (v_conn, 1, now() - interval '1 minute') RETURNING followup_id INTO v_fu1;

    -- [1] Claim gera token de 48 hex com validade de ~7 dias.
    SELECT f.raw_claim_token, f.claim_expires_at INTO v_tok1, v_exp
      FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.followup_id = v_fu1;
    IF v_tok1 IS NULL OR length(v_tok1) <> 48 THEN RAISE EXCEPTION 'FALHOU [1]: token ausente/invalido'; END IF;
    IF v_exp < now() + interval '6 days 23 hours' OR v_exp > now() + interval '7 days 1 minute' THEN
        RAISE EXCEPTION 'FALHOU [1]: validade % nao e ~7 dias', v_exp;
    END IF;
    RAISE NOTICE 'OK [1] claim com validade de 7 dias';

    -- [2] Nova execução do WF-05 logo depois NÃO reivindica de novo (sem lembrete duplicado).
    SELECT count(*) INTO v_n FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.followup_id = v_fu1;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FALHOU [2]: follow-up reivindicado de novo (duplicata)'; END IF;

    -- [3] Simula "2 horas depois" (antes era o ponto em que o claim expirava): ainda não reivindica.
    UPDATE rufino_linkedin.followups SET claimed_at = claimed_at - interval '2 hours' WHERE followup_id = v_fu1;
    SELECT count(*) INTO v_n FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.followup_id = v_fu1;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FALHOU [3]: reclaim apos 2h (duplicata)'; END IF;
    RAISE NOTICE 'OK [2][3] sem lembrete duplicado enquanto o botao esta valido';

    -- [4] "Sem resposta" funciona (o botão ainda vale) e agenda o próximo follow-up.
    SELECT * INTO v_r FROM rufino_linkedin.complete_followup(
        v_tok1, 'SEM_RESPOSTA', 'anderson', 'cbq-015-a', NULL, now() + interval '3 days', 'TESTE-015', NULL);
    IF v_r.new_connection_status <> 'FOLLOWUP_PENDENTE' OR v_r.next_followup_sequence <> 2 THEN
        RAISE EXCEPTION 'FALHOU [4]: resultado inesperado %', row_to_json(v_r);
    END IF;
    RAISE NOTICE 'OK [4] Sem resposta: proximo follow-up seq 2 em %', v_r.next_followup_scheduled_for;

    -- [5] Toque repetido no mesmo botão (mesmo callback): mesmo resultado, nada novo criado.
    SELECT * INTO v_r2 FROM rufino_linkedin.complete_followup(
        v_tok1, 'SEM_RESPOSTA', 'anderson', 'cbq-015-a', NULL, now() + interval '3 days', 'TESTE-015', NULL);
    SELECT count(*) INTO v_n FROM rufino_linkedin.followups WHERE connection_id = v_conn;
    IF v_r2.next_followup_id <> v_r.next_followup_id OR v_n <> 2 THEN
        RAISE EXCEPTION 'FALHOU [5]: repeticao criou duplicata (followups=%)', v_n;
    END IF;
    RAISE NOTICE 'OK [5] toque repetido e idempotente';

    -- [6] Outro toque (callback novo) no botão já usado é recusado.
    BEGIN
        PERFORM * FROM rufino_linkedin.complete_followup(v_tok1, 'RESPONDEU', 'anderson', 'cbq-015-b', NULL, NULL, 'TESTE-015', NULL);
        RAISE EXCEPTION 'FALHOU [6]: botao usado foi aceito de novo';
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
        IF v_err LIKE 'FALHOU%' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'OK [6] botao ja usado recusado (%)', v_err;

    -- [7] Próximo follow-up ainda não venceu: não é reivindicado.
    SELECT count(*) INTO v_n FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.connection_id = v_conn;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FALHOU [7]: follow-up futuro reivindicado'; END IF;
    RAISE NOTICE 'OK [7] follow-up futuro nao sai antes da hora';

    -- [8] Vence o seq 2, claim, e "Respondeu" encerra a jornada.
    UPDATE rufino_linkedin.followups SET scheduled_for = now() - interval '1 minute' WHERE followup_id = v_r.next_followup_id;
    SELECT f.raw_claim_token INTO v_tok2 FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.connection_id = v_conn;
    SELECT * INTO v_r FROM rufino_linkedin.complete_followup(v_tok2, 'RESPONDEU', 'anderson', 'cbq-015-c', NULL, NULL, 'TESTE-015', NULL);
    SELECT status INTO v_status FROM rufino_linkedin.connections WHERE connection_id = v_conn;
    IF v_status <> 'ENCERRADO' THEN RAISE EXCEPTION 'FALHOU [8]: status % (esperado ENCERRADO)', v_status; END IF;
    SELECT count(*) INTO v_n FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.connection_id = v_conn;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FALHOU [8]: follow-up apos encerrar'; END IF;
    RAISE NOTICE 'OK [8] Respondeu encerra a jornada e nao gera mais lembretes';

    -- [9] Claim abandonado por mais de 7 dias volta a ser reivindicado com token NOVO; o antigo falha.
    INSERT INTO rufino_linkedin.followups (connection_id, sequence, scheduled_for)
    VALUES (v_conn, 3, now() - interval '1 minute') RETURNING followup_id INTO v_fu1;
    SELECT f.raw_claim_token INTO v_tok1 FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.followup_id = v_fu1;
    UPDATE rufino_linkedin.followups SET claim_expires_at = now() - interval '1 minute' WHERE followup_id = v_fu1;
    SELECT f.raw_claim_token INTO v_tok1b FROM rufino_linkedin.claim_due_followups(50, 'TESTE-015') f WHERE f.followup_id = v_fu1;
    IF v_tok1b IS NULL OR v_tok1b = v_tok1 THEN RAISE EXCEPTION 'FALHOU [9]: reclaim nao rotacionou token'; END IF;
    BEGIN
        PERFORM * FROM rufino_linkedin.complete_followup(v_tok1, 'RESPONDEU', 'anderson', 'cbq-015-d', NULL, NULL, 'TESTE-015', NULL);
        RAISE EXCEPTION 'FALHOU [9]: token antigo aceito';
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
        IF v_err LIKE 'FALHOU%' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'OK [9] apos 7 dias sem resposta: novo lembrete com token novo; botao antigo recusado';
END
$t$;

ROLLBACK;
