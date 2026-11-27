-- =============================================================================
-- 017_register_reply.sql
-- Rufino LinkedIn Intelligence: registrar a resposta do contato na hora (/respondeu).
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 017_register_reply.sql
-- Rollback:    rollback/009_register_reply_rollback.sql
-- Testes:      tests/register_reply_tests.sql
--
-- Contexto (Anderson, 27/11/2026, "autorizo"): toda segunda-feira o Anderson quer olhar quem
-- respondeu e refletir sobre a abordagem. Até aqui a resposta só era registrada quando chegava
-- o lembrete de follow-up (D+5, botão "Respondeu"); quem respondia antes não aparecia nos números.
-- O comando /respondeu <nome> no Telegram (WF-ROUTER) chama esta função e registra na hora.
--
-- Regras:
--   - procura pelo nome (sem acento, sem diferença de maiúsculas), por trecho; busca com pelo
--     menos 3 letras;
--   - só registra quem está em FOLLOWUP_PENDENTE (mensagem marcada como enviada);
--   - mais de um contato elegível com o trecho: não registra nada e devolve os nomes (se um deles
--     tiver o nome exatamente igual à busca, é esse);
--   - registra igual ao botão "Respondeu" do lembrete: follow-ups em aberto do contato ficam
--     executados com resultado RESPONDEU e o contato vai FOLLOWUP_PENDENTE → RESPONDEU → ENCERRADO
--     (o histórico de status guarda o momento da resposta);
--   - nada encontrado ou status errado: não faz nada e devolve applied = false com o motivo.
-- =============================================================================

BEGIN;

-- Credencial DDL do n8n nao tem privilegio proprio: assume a owner so nesta transacao.
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;

CREATE FUNCTION rufino_linkedin.register_reply(
    p_busca          text,
    p_actor          text DEFAULT 'telegram:anderson',
    p_workflow_name  text DEFAULT 'WF-ROUTER',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    applied        boolean,
    reason         text,
    connection_id  uuid,
    nome           text,
    candidatos     text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_de     constant text := 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    v_para   constant text := 'aaaaaeeeeiiiiooooouuuucn';
    v_busca  text;
    v_n            integer;
    v_n_exato      integer;
    v_total        integer;
    v_id           uuid;
    v_nome         text;
    v_id_exato     uuid;
    v_nome_exato   text;
    v_lista_elig   text;
    v_lista_todos  text;
    v_reason constant text := 'resposta registrada pelo comando /respondeu';
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' OR p_workflow_name IS NULL THEN
        RAISE EXCEPTION 'register_reply: parametros obrigatorios ausentes';
    END IF;

    v_busca := regexp_replace(translate(lower(btrim(coalesce(p_busca, ''))), v_de, v_para), '\s+', ' ', 'g');
    IF length(v_busca) < 3 OR length(v_busca) > 120 THEN
        RETURN QUERY SELECT false, 'busca precisa de 3 a 120 letras'::text, NULL::uuid, NULL::text, NULL::text;
        RETURN;
    END IF;

    -- Se algum nome bate por inteiro, só os nomes exatos contam: "Ana" não pega a "Anabela"
    -- (nem depois que a Ana já foi registrada).
    WITH todos AS (
        SELECT c.connection_id, c.nome, c.status,
               c.status = 'FOLLOWUP_PENDENTE' AS elig,
               regexp_replace(translate(lower(c.nome), v_de, v_para), '\s+', ' ', 'g') = v_busca AS exato
          FROM rufino_linkedin.connections c
         WHERE strpos(regexp_replace(translate(lower(c.nome), v_de, v_para), '\s+', ' ', 'g'), v_busca) > 0
    ), cand AS (
        SELECT * FROM todos t WHERE t.exato OR NOT EXISTS (SELECT 1 FROM todos x WHERE x.exato)
    )
    SELECT count(*) FILTER (WHERE elig),
           count(*) FILTER (WHERE elig AND exato),
           (array_agg(connection_id) FILTER (WHERE elig))[1],
           (array_agg(nome) FILTER (WHERE elig))[1],
           (array_agg(connection_id) FILTER (WHERE elig AND exato))[1],
           (array_agg(nome) FILTER (WHERE elig AND exato))[1],
           left(string_agg(nome, ', ' ORDER BY nome) FILTER (WHERE elig), 500),
           left(string_agg(nome || ' (' || status || ')', ', ' ORDER BY nome), 500),
           count(*)
      INTO v_n, v_n_exato, v_id, v_nome, v_id_exato, v_nome_exato, v_lista_elig, v_lista_todos, v_total
      FROM cand;

    IF v_n > 1 THEN
        IF v_n_exato <> 1 THEN
            RETURN QUERY SELECT false, 'mais de um contato com esse nome'::text, NULL::uuid, NULL::text, v_lista_elig;
            RETURN;
        END IF;
        v_id := v_id_exato;
        v_nome := v_nome_exato;
    ELSIF v_n = 0 THEN
        IF v_total = 0 THEN
            RETURN QUERY SELECT false, 'nenhum contato com esse nome'::text, NULL::uuid, NULL::text, NULL::text;
        ELSE
            RETURN QUERY SELECT false, 'nenhum desses aguarda resposta'::text, NULL::uuid, NULL::text, v_lista_todos;
        END IF;
        RETURN;
    END IF;

    -- trava o contato e confere o status de novo (concorrência com o botão do lembrete)
    PERFORM 1 FROM rufino_linkedin.connections c
     WHERE c.connection_id = v_id AND c.status = 'FOLLOWUP_PENDENTE'
       FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'status mudou durante o registro, tente de novo'::text, NULL::uuid, v_nome, NULL::text;
        RETURN;
    END IF;

    UPDATE rufino_linkedin.followups f
       SET executed_at = now(),
           resultado = 'RESPONDEU',
           notified_actor = p_actor,
           notes = v_reason,
           claim_token_hash = NULL,
           claim_expires_at = NULL,
           updated_at = now()
     WHERE f.connection_id = v_id
       AND f.executed_at IS NULL;

    PERFORM t.status FROM rufino_linkedin.transition_connection_status(
        v_id, 'FOLLOWUP_PENDENTE', 'RESPONDEU', p_actor, v_reason, p_workflow_name, p_execution_id
    ) t;
    PERFORM t.status FROM rufino_linkedin.transition_connection_status(
        v_id, 'RESPONDEU', 'ENCERRADO', p_actor, 'jornada encerrada apos resposta', p_workflow_name, p_execution_id
    ) t;

    RETURN QUERY SELECT true, v_reason, v_id, v_nome, NULL::text;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.register_reply(text, text, text, text) OWNER TO n8n_rufino_linkedin_owner_dev;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.register_reply(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rufino_linkedin.register_reply(text, text, text, text) TO n8n_rufino_linkedin_dev;

COMMIT;
