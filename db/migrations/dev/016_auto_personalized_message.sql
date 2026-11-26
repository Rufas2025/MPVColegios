-- =============================================================================
-- 016_auto_personalized_message.sql
-- Rufino LinkedIn Intelligence: mensagem D+1 personalizada automaticamente (fase 2).
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 016_auto_personalized_message.sql
-- Rollback:    rollback/008_auto_personalized_message_rollback.sql
-- Testes:      tests/auto_personalized_message_tests.sql
--
-- Contexto (Anderson, 26/11/2026, "autorizo"): a pesquisa pública do contato roda no cadastro,
-- mas a mensagem D+1 saía do modelo fixo. O WF-06 (8h30, dias úteis) escreve a mensagem com a
-- pesquisa e grava aqui uma versão nova ANTES do WF-02 das 9h; o claim das 9h já pega a última
-- versão (ORDER BY version DESC), então o cartão de aprovação chega com o texto personalizado.
--
-- Regras da função (nunca sobrescreve trabalho humano):
--   - só em AGUARDANDO_D1 (antes do cartão existir);
--   - só se a versão vigente for a 1, gerada pelo modelo (source 'gpt', sem edited_by);
--   - texto não vazio e com no máximo 1500 caracteres;
--   - grava a versão 2 com source 'gpt' e edited_by = p_generator (ex.: 'auto-pesquisa:claude-haiku-5-5'),
--     que identifica a origem para comparar a taxa de resposta;
--   - se a condição não vale, não faz nada e devolve applied = false com o motivo (o workflow segue).
-- Não muda status, não cria cartão, não mexe em token.
-- =============================================================================

BEGIN;

-- Credencial DDL do n8n nao tem privilegio proprio: assume a owner so nesta transacao.
SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;

CREATE FUNCTION rufino_linkedin.save_auto_message(
    p_connection_id     uuid,
    p_new_message_body  text,
    p_generator         text,
    p_workflow_name     text DEFAULT 'WF-06',
    p_execution_id      text DEFAULT NULL
)
RETURNS TABLE (
    applied             boolean,
    reason              text,
    message_version_id  uuid,
    version             integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_status   text;
    v_ver      integer;
    v_source   text;
    v_by       text;
    v_id       uuid;
BEGIN
    IF p_connection_id IS NULL OR p_new_message_body IS NULL OR p_generator IS NULL THEN
        RAISE EXCEPTION 'save_auto_message: parametros obrigatorios ausentes';
    END IF;
    IF btrim(p_new_message_body) = '' OR length(p_new_message_body) > 1500 THEN
        RAISE EXCEPTION 'save_auto_message: texto vazio ou acima de 1500 caracteres';
    END IF;
    IF btrim(p_generator) = '' OR length(p_generator) > 120 THEN
        RAISE EXCEPTION 'save_auto_message: p_generator invalido';
    END IF;

    SELECT c.status INTO v_status
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'contato nao encontrado'::text, NULL::uuid, NULL::integer;
        RETURN;
    END IF;
    IF v_status <> 'AGUARDANDO_D1' THEN
        RETURN QUERY SELECT false, ('status ' || v_status)::text, NULL::uuid, NULL::integer;
        RETURN;
    END IF;

    SELECT mv.version, mv.source, mv.edited_by INTO v_ver, v_source, v_by
      FROM rufino_linkedin.message_versions mv
     WHERE mv.connection_id = p_connection_id
     ORDER BY mv.version DESC
     LIMIT 1;
    IF v_ver IS DISTINCT FROM 1 OR v_source IS DISTINCT FROM 'gpt' OR v_by IS NOT NULL THEN
        RETURN QUERY SELECT false, ('versao vigente ' || coalesce(v_ver::text, '?') || ' ' || coalesce(v_source, '?')
                                    || coalesce(' por ' || v_by, ''))::text, NULL::uuid, NULL::integer;
        RETURN;
    END IF;

    INSERT INTO rufino_linkedin.message_versions (connection_id, version, message_body, source, edited_by)
    VALUES (p_connection_id, 2, p_new_message_body, 'gpt', p_generator)
    RETURNING rufino_linkedin.message_versions.message_version_id INTO v_id;

    RETURN QUERY SELECT true, ('gravada por ' || coalesce(p_workflow_name, '?') || ' ' || coalesce(p_execution_id, ''))::text, v_id, 2;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.save_auto_message(
    uuid, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;

REVOKE EXECUTE ON FUNCTION rufino_linkedin.save_auto_message(
    uuid, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rufino_linkedin.save_auto_message(
    uuid, text, text, text, text
) TO n8n_rufino_linkedin_dev;

COMMIT;
