-- Operação pontual (autorizada por Anderson em 24/11/2026): encerrar a cadência de follow-up de 3 contatos
-- já enviados, usando as MESMAS funções dos botões do lembrete (claim_due_followups + complete_followup),
-- para o histórico ficar igual ao de um toque normal.
--   Raphael Louro            -> RESPONDEU (respondeu em 23/11)            -> ENCERRADO
--   Marcela Ribeiro Antunes  -> SEM_RESPOSTA sem próximo follow-up        -> ENCERRADO (Elite / Grupo Salta)
--   Franciane Aguiar         -> SEM_RESPOSTA sem próximo follow-up        -> ENCERRADO (rede Adventista)
-- Rodar com a credencial DDL do DEV (precisa do UPDATE em followups). Tudo ou nada.
BEGIN;
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;

DO $op$
DECLARE
    v_alvos   text[] := ARRAY['Raphael Louro', 'Marcela Ribeiro Antunes', 'Franciane Aguiar'];
    v_n       integer;
    v_row     record;
    v_res     record;
BEGIN
    -- Trava 1: nenhum outro follow-up pode estar vencido e livre (o claim abaixo pegaria ele também).
    SELECT count(*) INTO v_n FROM rufino_linkedin.followups f
     WHERE f.executed_at IS NULL AND f.scheduled_for <= now()
       AND (f.claim_expires_at IS NULL OR f.claim_expires_at <= now());
    IF v_n > 0 THEN RAISE EXCEPTION 'abortado: % follow-up(s) de outros contatos vencidos e livres', v_n; END IF;

    -- Trava 2: exatamente 1 follow-up aberto, não reivindicado, por alvo, em FOLLOWUP_PENDENTE.
    SELECT count(*) INTO v_n FROM rufino_linkedin.followups f
      JOIN rufino_linkedin.connections c ON c.connection_id = f.connection_id
     WHERE c.nome = ANY (v_alvos) AND c.status = 'FOLLOWUP_PENDENTE'
       AND f.executed_at IS NULL AND f.claimed_at IS NULL;
    IF v_n <> array_length(v_alvos, 1) THEN RAISE EXCEPTION 'abortado: esperava % follow-ups abertos, achou %', array_length(v_alvos, 1), v_n; END IF;

    -- Antecipa o vencimento só desses 3 e reivindica (gera o token como o WF-05 faria).
    UPDATE rufino_linkedin.followups f SET scheduled_for = now() - interval '1 second'
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = f.connection_id AND c.nome = ANY (v_alvos)
       AND f.executed_at IS NULL AND f.claimed_at IS NULL;

    v_n := 0;
    FOR v_row IN
        SELECT d.raw_claim_token, c.nome
          FROM rufino_linkedin.claim_due_followups(10, 'MANUAL-ENCERRAR-FOLLOWUP') d
          JOIN rufino_linkedin.connections c ON c.connection_id = d.connection_id
    LOOP
        IF NOT (v_row.nome = ANY (v_alvos)) THEN RAISE EXCEPTION 'abortado: claim pegou contato fora da lista (%)', v_row.nome; END IF;
        SELECT * INTO v_res FROM rufino_linkedin.complete_followup(
            v_row.raw_claim_token,
            CASE WHEN v_row.nome = 'Raphael Louro' THEN 'RESPONDEU' ELSE 'SEM_RESPOSTA' END,
            'anderson (via Claude, 24/11)',
            'manual-encerrar-' || md5(v_row.nome || '-2026-11-24'),
            CASE WHEN v_row.nome = 'Raphael Louro' THEN 'Respondeu em 23/11 (está no mercado); cadência encerrada'
                 ELSE 'Rede com contrato Eduinfo (Grupo Salta / Adventista); cadência encerrada a pedido' END,
            NULL, 'MANUAL-ENCERRAR-FOLLOWUP', NULL);
        v_n := v_n + 1;
        RAISE NOTICE '% -> %', v_row.nome, v_res.new_connection_status;
    END LOOP;
    IF v_n <> array_length(v_alvos, 1) THEN RAISE EXCEPTION 'abortado: encerrou % de %', v_n, array_length(v_alvos, 1); END IF;
END
$op$;

SELECT c.nome, c.status,
       (SELECT count(*) FROM rufino_linkedin.followups f WHERE f.connection_id = c.connection_id AND f.executed_at IS NULL) AS followups_abertos
  FROM rufino_linkedin.connections c
 WHERE c.nome IN ('Raphael Louro', 'Marcela Ribeiro Antunes', 'Franciane Aguiar')
 ORDER BY c.nome;
COMMIT;
