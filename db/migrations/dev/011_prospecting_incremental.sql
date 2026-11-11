-- =============================================================================
-- 011_prospecting_incremental.sql
-- Rufino LinkedIn Intelligence — Adendo pré-conexão — APLICAÇÃO INCREMENTAL
--
-- Gerado por extração automática dos blocos 'Adendo pré-conexão' já revisados
-- e testados em 003_tables.sql/004_constraints_and_indexes.sql/
-- 005_rls_and_grants.sql/006_functions.sql (commit 2fb4253) — não reescreve
-- nada, só isola o que é NOVO para aplicar sobre um banco que já tem a
-- base v1.5.1 (11 tabelas, 15 funções, 2 roles — confirmado por preflight
-- real em rufino-linkedin-dev, 2026-11-11).
--
-- Aplicar com: psql -v ON_ERROR_STOP=1 -f 011_prospecting_incremental.sql
-- NUNCA aplicar 001-007 do zero sobre este banco — schema/roles/tabelas
-- pós-aceite já existem. NUNCA aplicar rollback/001_rollback.sql aqui —
-- ele apaga as 11 tabelas existentes, inclusive dados reais.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- schools — NOVA (Adendo pré-conexão)
--
-- Resolve "vincular sem duplicar" sem fundir escolas de cidades diferentes
-- apenas pelo nome. cidade_normalizada NULL nunca é usada para encontrar
-- uma linha existente (ver register_prospect em 006_functions.sql) — uma
-- cidade desconhecida sempre cria uma linha nova, nunca reaproveita uma
-- escola de cidade diferente (ou de cidade também desconhecida) por engano.
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.schools (
    school_id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    nome                 text        NOT NULL,
    nome_normalizado     text        NOT NULL,
    cidade               text,
    cidade_normalizada   text,
    rede                 text,
    unidade              text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.schools OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.schools IS
    'Adendo pré-conexão — escola/rede à qual um prospect está vinculado. Dedupe por (nome_normalizado, cidade_normalizada, unidade); cidade desconhecida (NULL) nunca é fundida com nenhuma outra linha, nem entre si — ver register_prospect.';
COMMENT ON COLUMN rufino_linkedin.schools.cidade_normalizada IS
    'NULL quando a cidade não foi informada. register_prospect só reaproveita uma linha existente quando esta coluna é NOT NULL e bate exatamente — nunca casa por nome isolado.';

-- -----------------------------------------------------------------------------
-- prospects — NOVA (Adendo pré-conexão)
--
-- Pessoa identificada ANTES do aceite da conexão. Nunca é gravada em
-- connections. canonical_profile_url é a chave real de dedupe (ver
-- normalize_linkedin_url em 006_functions.sql) — linkedin_profile_url
-- preserva o valor original como veio, sem normalizar, só para auditoria.
-- connection_id é o vínculo idempotente com a jornada pós-aceite existente
-- (register_prospect e link_prospect_to_connection resolvem esse vínculo
-- nos dois sentidos, pela mesma URL canônica).
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.prospects (
    prospect_id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    linkedin_profile_url     text        NOT NULL,
    canonical_profile_url    text        NOT NULL,
    nome                     text        NOT NULL,
    primeiro_nome            text        NOT NULL,
    cargo_atual              text,
    cidade                   text,
    vinculo_decisorio        text,
    icp_tier                 text,
    school_id                uuid,
    status                   text        NOT NULL DEFAULT 'IDENTIFICADO',
    origem                   text        NOT NULL,
    convite_enviado_em       timestamptz,
    convite_aceito_em        timestamptz,
    motivo_encerramento      text,
    connection_id            uuid,
    lock_version             integer     NOT NULL DEFAULT 0,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.prospects OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.prospects IS
    'Adendo pré-conexão — funil IDENTIFICADO→QUALIFICADO→CONVITE_PENDENTE→CONECTADO→ENCERRADO, anterior ao aceite da conexão no LinkedIn. Nenhuma linha aqui implica que um convite foi de fato enviado automaticamente — mark_invite_sent só registra um fato que já aconteceu fora do sistema.';
COMMENT ON COLUMN rufino_linkedin.prospects.canonical_profile_url IS
    'URL normalizada (rufino_linkedin.normalize_linkedin_url) — chave real de dedupe e de vínculo com connections.profile_url. UNIQUE em 004_constraints_and_indexes.sql.';
COMMENT ON COLUMN rufino_linkedin.prospects.connection_id IS
    'Preenchido só depois que a mesma pessoa aparecer em connections (jornada pós-aceite já existente), por URL canônica — nunca por correspondência de nome. UNIQUE parcial em 004 garante 1:1.';

-- -----------------------------------------------------------------------------
-- prospect_events — NOVA (Adendo pré-conexão)
--
-- Histórico append-only do funil de prospecção, mesmo padrão de
-- connection_status_history. Nunca grava token bruto ou segredo em
-- `detalhe`.
-- -----------------------------------------------------------------------------
CREATE TABLE rufino_linkedin.prospect_events (
    prospect_event_id   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    prospect_id          uuid        NOT NULL,
    event_type           text        NOT NULL,
    detalhe              jsonb,
    actor                text        NOT NULL,
    source_workflow      text,
    execution_id         text,
    created_at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rufino_linkedin.prospect_events OWNER TO n8n_rufino_linkedin_owner_dev;

COMMENT ON TABLE rufino_linkedin.prospect_events IS
    'Adendo pré-conexão — histórico append-only de eventos de um prospect (IDENTIFICADO/QUALIFICADO/CONVITE_ENVIADO/CONVITE_ACEITO/ENCERRADO/VINCULADO_CONNECTION). Espelha connection_status_history.';


-- -----------------------------------------------------------------------------
-- schools (Adendo pré-conexão)
--
-- UNIQUE NULLS NOT DISTINCT é só o backstop contra duplicata EXATA sob
-- concorrência (duas chamadas simultâneas com o mesmo nome+cidade+unidade,
-- inclusive quando os três são NULL). A regra de negócio real — nunca casar
-- por nome quando a cidade é desconhecida ou diferente — vive em
-- register_prospect (006_functions.sql), não neste índice.
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX schools_nome_cidade_unidade_key
    ON rufino_linkedin.schools (nome_normalizado, cidade_normalizada, unidade)
    NULLS NOT DISTINCT;

-- -----------------------------------------------------------------------------
-- prospects (Adendo pré-conexão)
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.prospects
    ADD CONSTRAINT prospects_canonical_profile_url_key UNIQUE (canonical_profile_url),
    ADD CONSTRAINT prospects_school_id_fkey FOREIGN KEY (school_id)
        REFERENCES rufino_linkedin.schools (school_id) ON DELETE SET NULL,
    ADD CONSTRAINT prospects_connection_id_fkey FOREIGN KEY (connection_id)
        REFERENCES rufino_linkedin.connections (connection_id) ON DELETE SET NULL,
    ADD CONSTRAINT prospects_status_check CHECK (status IN (
        'IDENTIFICADO', 'QUALIFICADO', 'CONVITE_PENDENTE', 'CONECTADO', 'ENCERRADO'
    )),
    ADD CONSTRAINT prospects_icp_tier_check CHECK (icp_tier IS NULL OR icp_tier IN ('P1', 'P2', 'P3')),
    ADD CONSTRAINT prospects_motivo_encerramento_check CHECK (
        motivo_encerramento IS NULL OR motivo_encerramento IN (
            'RECUSADO', 'SEM_RESPOSTA_PROSPECCAO', 'DUPLICADO', 'FORA_DO_ICP', 'OUTRO'
        )
    ),
    ADD CONSTRAINT prospects_encerrado_tem_motivo_check CHECK (
        status <> 'ENCERRADO' OR motivo_encerramento IS NOT NULL
    );

-- Vínculo idempotente 1:1 com connections — nenhuma connection pode ser
-- reivindicada por dois prospects diferentes.
CREATE UNIQUE INDEX prospects_connection_id_key
    ON rufino_linkedin.prospects (connection_id) WHERE connection_id IS NOT NULL;

-- Consulta central de get_daily_prospect_queue.
CREATE INDEX prospects_status_tier_created_idx
    ON rufino_linkedin.prospects (status, icp_tier, created_at) WHERE status = 'QUALIFICADO';
CREATE INDEX prospects_school_id_idx ON rufino_linkedin.prospects (school_id);

-- -----------------------------------------------------------------------------
-- prospect_events (Adendo pré-conexão)
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.prospect_events
    ADD CONSTRAINT prospect_events_prospect_id_fkey FOREIGN KEY (prospect_id)
        REFERENCES rufino_linkedin.prospects (prospect_id) ON DELETE CASCADE,
    ADD CONSTRAINT prospect_events_event_type_check CHECK (event_type IN (
        'IDENTIFICADO', 'QUALIFICADO', 'CONVITE_ENVIADO', 'CONVITE_ACEITO',
        'ENCERRADO', 'VINCULADO_CONNECTION'
    ));

CREATE INDEX prospect_events_prospect_id_created_at_idx
    ON rufino_linkedin.prospect_events (prospect_id, created_at);


-- -----------------------------------------------------------------------------
-- Adendo pré-conexão: mesma disciplina — RLS habilitado (não forçado),
-- SELECT-only para a role de aplicação, toda escrita via função.
-- -----------------------------------------------------------------------------
ALTER TABLE rufino_linkedin.schools          ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.prospects        ENABLE ROW LEVEL SECURITY;
ALTER TABLE rufino_linkedin.prospect_events  ENABLE ROW LEVEL SECURITY;

CREATE POLICY schools_select_app ON rufino_linkedin.schools
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY prospects_select_app ON rufino_linkedin.prospects
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);
CREATE POLICY prospect_events_select_app ON rufino_linkedin.prospect_events
    FOR SELECT TO n8n_rufino_linkedin_dev USING (true);

GRANT SELECT ON
    rufino_linkedin.schools,
    rufino_linkedin.prospects,
    rufino_linkedin.prospect_events
TO n8n_rufino_linkedin_dev;


-- =============================================================================
-- ADENDO PRÉ-CONEXÃO (ver ADDENDUM-prospecting-pre-connection-SPEC.md,
-- commit df95326) — funções novas, mesma disciplina de hardening acima:
--   16. normalize_linkedin_url        (INTERNA — helper puro)
--   17. normalize_school_name         (INTERNA — helper puro)
--   18. register_prospect             (executável pela role de aplicação)
--   19. qualify_prospect              (executável pela role de aplicação)
--   20. get_daily_prospect_queue      (executável pela role de aplicação — só leitura)
--   21. mark_invite_sent              (executável pela role de aplicação)
--   22. confirm_invite_accepted       (executável pela role de aplicação)
--   23. close_prospect                (executável pela role de aplicação)
--   24. link_prospect_to_connection   (executável pela role de aplicação)
--
-- Nenhuma das 15 funções existentes teve assinatura, corpo ou contrato
-- alterado nesta rodada. register_connection/connections.profile_url
-- continuam exatamente como estão — o vínculo com prospects é resolvido
-- por fora, nos dois sentidos, pela mesma URL canônica (ver 18 e 24).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 16) normalize_linkedin_url — INTERNA. Pura, sem acesso a tabela: lower,
--     remove esquema/www, corta query/fragmento, remove barra final. Usada
--     por register_prospect e link_prospect_to_connection para comparar
--     prospects.linkedin_profile_url e connections.profile_url na mesma
--     forma canônica, independente de maiúsculas/www/barra final/query
--     string que o GPT ou Anderson tenham colado.
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.normalize_linkedin_url(p_url text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = rufino_linkedin, pg_temp
AS $fn$
DECLARE
    v_result text;
BEGIN
    v_result := lower(btrim(p_url));
    v_result := regexp_replace(v_result, '^https?://(www\.)?', '');
    v_result := regexp_replace(v_result, '[?#].*$', '');
    v_result := regexp_replace(v_result, '/+$', '');
    RETURN v_result;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.normalize_linkedin_url(text) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 17) normalize_school_name — INTERNA. Lower + espaços colapsados.
--     Deliberadamente sem remoção de acento (sem depender de `unaccent`,
--     extensão não confirmada neste ambiente) — "Colégio"/"Colegio" sem
--     acento NÃO são tratados como iguais nesta versão. Ajuste futuro, não
--     bloqueante.
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.normalize_school_name(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = rufino_linkedin, pg_temp
AS $fn$
    SELECT btrim(regexp_replace(lower(p_text), '\s+', ' ', 'g'));
$fn$;

ALTER FUNCTION rufino_linkedin.normalize_school_name(text) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 18) register_prospect — IDENTIFICADO (ou direto CONECTADO, ver abaixo).
--
-- Dedupe por canonical_profile_url (ON CONFLICT DO NOTHING, mesmo padrão de
-- register_connection). Resolve/cria schools sem fundir por nome quando a
-- cidade é desconhecida (ver 003_tables.sql). Vínculo idempotente com
-- connections: se já existir uma connections row com a mesma URL canônica
-- (pessoa que já tinha aceitado a conexão antes de entrar no funil de
-- prospecção), o prospect nasce direto em CONECTADO, nunca passando por
-- estados que não aconteceram.
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.register_prospect(
    p_linkedin_profile_url   text,
    p_nome                   text,
    p_primeiro_nome          text,
    p_cargo_atual            text,
    p_cidade                 text,
    p_escola_nome            text,
    p_rede                   text,
    p_unidade                text,
    p_origem                 text,
    p_workflow_name          text DEFAULT 'PROSPECCAO',
    p_execution_id           text DEFAULT NULL
)
RETURNS TABLE (
    prospect_id       uuid,
    status            text,
    school_id         uuid,
    connection_id     uuid,
    already_existed   boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_canonical          text;
    v_prospect_id        uuid;
    v_school_id          uuid;
    v_nome_norm          text;
    v_cidade_norm        text;
    v_connection_id       uuid;
    v_connection_data     date;
    v_status             text;
BEGIN
    IF p_linkedin_profile_url IS NULL OR btrim(p_linkedin_profile_url) = '' THEN
        RAISE EXCEPTION 'register_prospect: p_linkedin_profile_url obrigatorio';
    END IF;
    IF p_nome IS NULL OR p_primeiro_nome IS NULL OR p_origem IS NULL THEN
        RAISE EXCEPTION 'register_prospect: p_nome, p_primeiro_nome e p_origem sao obrigatorios';
    END IF;

    v_canonical := rufino_linkedin.normalize_linkedin_url(p_linkedin_profile_url);

    IF p_escola_nome IS NOT NULL AND btrim(p_escola_nome) <> '' THEN
        v_nome_norm := rufino_linkedin.normalize_school_name(p_escola_nome);

        IF p_cidade IS NOT NULL AND btrim(p_cidade) <> '' THEN
            v_cidade_norm := rufino_linkedin.normalize_school_name(p_cidade);

            SELECT s.school_id INTO v_school_id
              FROM rufino_linkedin.schools s
             WHERE s.nome_normalizado = v_nome_norm
               AND s.cidade_normalizada = v_cidade_norm
               AND s.unidade IS NOT DISTINCT FROM p_unidade
             LIMIT 1;
        END IF;

        -- Cidade desconhecida, ou nenhuma linha compativel com cidade
        -- conhecida: cria uma escola nova. Nunca reaproveita uma linha de
        -- cidade diferente, nem uma linha de cidade tambem desconhecida.
        IF v_school_id IS NULL THEN
            INSERT INTO rufino_linkedin.schools (nome, nome_normalizado, cidade, cidade_normalizada, rede, unidade)
            VALUES (p_escola_nome, v_nome_norm, p_cidade, v_cidade_norm, p_rede, p_unidade)
            ON CONFLICT (nome_normalizado, cidade_normalizada, unidade) DO NOTHING
            RETURNING rufino_linkedin.schools.school_id INTO v_school_id;

            IF v_school_id IS NULL THEN
                -- Concorrencia: outra sessao criou a mesma linha exata entre
                -- o SELECT acima e este INSERT. Reusa, nao duplica.
                SELECT s.school_id INTO v_school_id
                  FROM rufino_linkedin.schools s
                 WHERE s.nome_normalizado = v_nome_norm
                   AND s.cidade_normalizada IS NOT DISTINCT FROM v_cidade_norm
                   AND s.unidade IS NOT DISTINCT FROM p_unidade
                 LIMIT 1;
            END IF;
        END IF;
    END IF;

    INSERT INTO rufino_linkedin.prospects (
        prospect_id, linkedin_profile_url, canonical_profile_url, nome, primeiro_nome,
        cargo_atual, cidade, school_id, status, origem, lock_version
    ) VALUES (
        gen_random_uuid(), p_linkedin_profile_url, v_canonical, p_nome, p_primeiro_nome,
        p_cargo_atual, p_cidade, v_school_id, 'IDENTIFICADO', p_origem, 0
    )
    ON CONFLICT (canonical_profile_url) DO NOTHING
    RETURNING rufino_linkedin.prospects.prospect_id INTO v_prospect_id;

    IF v_prospect_id IS NULL THEN
        SELECT p.prospect_id, p.status, p.school_id, p.connection_id
          INTO v_prospect_id, v_status, v_school_id, v_connection_id
          FROM rufino_linkedin.prospects p
         WHERE p.canonical_profile_url = v_canonical;

        RETURN QUERY SELECT v_prospect_id, v_status, v_school_id, v_connection_id, true;
        RETURN;
    END IF;

    INSERT INTO rufino_linkedin.prospect_events (prospect_id, event_type, detalhe, actor, source_workflow, execution_id)
    VALUES (v_prospect_id, 'IDENTIFICADO', jsonb_build_object('origem', p_origem), p_origem, p_workflow_name, p_execution_id);

    -- Vinculo idempotente: se a pessoa ja aceitou a conexao antes de passar
    -- pela prospeccao, pula direto para CONECTADO.
    SELECT c.connection_id, c.data_conexao INTO v_connection_id, v_connection_data
      FROM rufino_linkedin.connections c
     WHERE rufino_linkedin.normalize_linkedin_url(c.profile_url) = v_canonical
     LIMIT 1;

    IF v_connection_id IS NOT NULL THEN
        UPDATE rufino_linkedin.prospects
           SET status = 'CONECTADO', connection_id = v_connection_id,
               convite_aceito_em = COALESCE(convite_aceito_em, v_connection_data::timestamptz),
               lock_version = lock_version + 1, updated_at = now()
         WHERE rufino_linkedin.prospects.prospect_id = v_prospect_id;

        INSERT INTO rufino_linkedin.prospect_events (prospect_id, event_type, detalhe, actor, source_workflow, execution_id)
        VALUES (v_prospect_id, 'VINCULADO_CONNECTION',
                jsonb_build_object('connection_id', v_connection_id, 'motivo', 'ja_conectado_antes_da_prospeccao'),
                'sistema', p_workflow_name, p_execution_id);

        v_status := 'CONECTADO';
    ELSE
        v_status := 'IDENTIFICADO';
    END IF;

    RETURN QUERY SELECT v_prospect_id, v_status, v_school_id, v_connection_id, false;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.register_prospect(
    text, text, text, text, text, text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 19) qualify_prospect — IDENTIFICADO → QUALIFICADO. Não reclassifica quem
--     já passou desse estado (função separada seria necessária para isso,
--     fora do escopo deste adendo).
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.qualify_prospect(
    p_prospect_id        uuid,
    p_icp_tier           text,
    p_vinculo_decisorio  text,
    p_justificativa      text,
    p_actor              text,
    p_workflow_name      text DEFAULT 'PROSPECCAO',
    p_execution_id       text DEFAULT NULL
)
RETURNS TABLE (
    prospect_id  uuid,
    status       text,
    icp_tier     text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_current_status text;
BEGIN
    IF p_icp_tier NOT IN ('P1', 'P2', 'P3') THEN
        RAISE EXCEPTION 'qualify_prospect: p_icp_tier invalido (%): use P1, P2 ou P3', p_icp_tier;
    END IF;

    SELECT p.status INTO v_current_status
      FROM rufino_linkedin.prospects p
     WHERE p.prospect_id = p_prospect_id
     FOR UPDATE;

    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'qualify_prospect: prospect_id % nao encontrado', p_prospect_id;
    END IF;

    IF v_current_status <> 'IDENTIFICADO' THEN
        RAISE EXCEPTION 'qualify_prospect: prospect % esta em % (esperado IDENTIFICADO)', p_prospect_id, v_current_status;
    END IF;

    UPDATE rufino_linkedin.prospects
       SET status = 'QUALIFICADO', icp_tier = p_icp_tier, vinculo_decisorio = p_vinculo_decisorio,
           lock_version = lock_version + 1, updated_at = now()
     WHERE rufino_linkedin.prospects.prospect_id = p_prospect_id;

    INSERT INTO rufino_linkedin.prospect_events (prospect_id, event_type, detalhe, actor, source_workflow, execution_id)
    VALUES (p_prospect_id, 'QUALIFICADO', jsonb_build_object('icp_tier', p_icp_tier, 'justificativa', p_justificativa), p_actor, p_workflow_name, p_execution_id);

    RETURN QUERY SELECT p_prospect_id, 'QUALIFICADO'::text, p_icp_tier;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.qualify_prospect(
    uuid, text, text, text, text, text, text
) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 20) get_daily_prospect_queue — SOMENTE LEITURA. Teto de 20 aplicado
--     dentro da função (LEAST), nunca confiado ao chamador. Não transiciona
--     status nenhum — é só a lista de candidatos do dia; quantos de fato
--     recebem convite é decisão humana, fora desta função.
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.get_daily_prospect_queue(
    p_limit          integer DEFAULT 20,
    p_workflow_name  text DEFAULT 'PROSPECCAO',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    prospect_id            uuid,
    nome                   text,
    primeiro_nome          text,
    cargo_atual            text,
    cidade                 text,
    school_id              uuid,
    icp_tier               text,
    linkedin_profile_url   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
BEGIN
    RETURN QUERY
    SELECT p.prospect_id, p.nome, p.primeiro_nome, p.cargo_atual, p.cidade, p.school_id,
           p.icp_tier, p.linkedin_profile_url
      FROM rufino_linkedin.prospects p
     WHERE p.status = 'QUALIFICADO'
     ORDER BY p.icp_tier, p.created_at
     LIMIT LEAST(COALESCE(p_limit, 20), 20);
END;
$fn$;

ALTER FUNCTION rufino_linkedin.get_daily_prospect_queue(integer, text, text) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 21) mark_invite_sent — QUALIFICADO → CONVITE_PENDENTE. Idempotente: uma
--     segunda chamada no mesmo prospect (retry/duplo clique) nunca reescreve
--     convite_enviado_em nem gera um segundo evento — devolve o estado atual
--     com already_sent=true. Registra só um convite que já foi enviado
--     manualmente dentro do LinkedIn; não envia nada.
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.mark_invite_sent(
    p_prospect_id    uuid,
    p_actor          text,
    p_workflow_name  text DEFAULT 'PROSPECCAO',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    prospect_id         uuid,
    status              text,
    convite_enviado_em  timestamptz,
    already_sent        boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_current_status      text;
    v_convite_enviado_em   timestamptz;
BEGIN
    SELECT p.status, p.convite_enviado_em INTO v_current_status, v_convite_enviado_em
      FROM rufino_linkedin.prospects p
     WHERE p.prospect_id = p_prospect_id
     FOR UPDATE;

    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'mark_invite_sent: prospect_id % nao encontrado', p_prospect_id;
    END IF;

    IF v_current_status IN ('CONVITE_PENDENTE', 'CONECTADO') THEN
        RETURN QUERY SELECT p_prospect_id, v_current_status, v_convite_enviado_em, true;
        RETURN;
    END IF;

    IF v_current_status <> 'QUALIFICADO' THEN
        RAISE EXCEPTION 'mark_invite_sent: prospect % esta em % (esperado QUALIFICADO)', p_prospect_id, v_current_status;
    END IF;

    v_convite_enviado_em := now();

    UPDATE rufino_linkedin.prospects
       SET status = 'CONVITE_PENDENTE', convite_enviado_em = v_convite_enviado_em,
           lock_version = lock_version + 1, updated_at = now()
     WHERE rufino_linkedin.prospects.prospect_id = p_prospect_id;

    INSERT INTO rufino_linkedin.prospect_events (prospect_id, event_type, actor, source_workflow, execution_id)
    VALUES (p_prospect_id, 'CONVITE_ENVIADO', p_actor, p_workflow_name, p_execution_id);

    RETURN QUERY SELECT p_prospect_id, 'CONVITE_PENDENTE'::text, v_convite_enviado_em, false;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.mark_invite_sent(uuid, text, text, text) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 22) confirm_invite_accepted — CONVITE_PENDENTE → CONECTADO. Ponto de
--     entrada da cadência pós-aceite já existente (nenhum workflow é
--     chamado por esta função — o handoff é manual/futuro, ver
--     README-IMPORT do adendo). Idempotente: confirmar de novo um prospect
--     já CONECTADO é no-op.
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.confirm_invite_accepted(
    p_prospect_id    uuid,
    p_data_aceite    timestamptz,
    p_actor          text,
    p_workflow_name  text DEFAULT 'PROSPECCAO',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    prospect_id         uuid,
    status              text,
    convite_aceito_em   timestamptz,
    already_confirmed   boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_current_status      text;
    v_convite_aceito_em    timestamptz;
BEGIN
    SELECT p.status, p.convite_aceito_em INTO v_current_status, v_convite_aceito_em
      FROM rufino_linkedin.prospects p
     WHERE p.prospect_id = p_prospect_id
     FOR UPDATE;

    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'confirm_invite_accepted: prospect_id % nao encontrado', p_prospect_id;
    END IF;

    IF v_current_status = 'CONECTADO' THEN
        RETURN QUERY SELECT p_prospect_id, v_current_status, v_convite_aceito_em, true;
        RETURN;
    END IF;

    IF v_current_status <> 'CONVITE_PENDENTE' THEN
        RAISE EXCEPTION 'confirm_invite_accepted: prospect % esta em % (esperado CONVITE_PENDENTE)', p_prospect_id, v_current_status;
    END IF;

    v_convite_aceito_em := COALESCE(p_data_aceite, now());

    UPDATE rufino_linkedin.prospects
       SET status = 'CONECTADO', convite_aceito_em = v_convite_aceito_em,
           lock_version = lock_version + 1, updated_at = now()
     WHERE rufino_linkedin.prospects.prospect_id = p_prospect_id;

    INSERT INTO rufino_linkedin.prospect_events (prospect_id, event_type, actor, source_workflow, execution_id)
    VALUES (p_prospect_id, 'CONVITE_ACEITO', p_actor, p_workflow_name, p_execution_id);

    RETURN QUERY SELECT p_prospect_id, 'CONECTADO'::text, v_convite_aceito_em, false;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.confirm_invite_accepted(uuid, timestamptz, text, text, text) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 23) close_prospect — qualquer estado → ENCERRADO. Idempotente com o
--     mesmo motivo; rejeita reescrever com um motivo diferente.
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.close_prospect(
    p_prospect_id    uuid,
    p_motivo         text,
    p_actor          text,
    p_workflow_name  text DEFAULT 'PROSPECCAO',
    p_execution_id   text DEFAULT NULL
)
RETURNS TABLE (
    prospect_id  uuid,
    status       text,
    motivo       text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_current_status  text;
    v_current_motivo  text;
BEGIN
    IF p_motivo NOT IN ('RECUSADO', 'SEM_RESPOSTA_PROSPECCAO', 'DUPLICADO', 'FORA_DO_ICP', 'OUTRO') THEN
        RAISE EXCEPTION 'close_prospect: p_motivo invalido (%)', p_motivo;
    END IF;

    SELECT p.status, p.motivo_encerramento INTO v_current_status, v_current_motivo
      FROM rufino_linkedin.prospects p
     WHERE p.prospect_id = p_prospect_id
     FOR UPDATE;

    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'close_prospect: prospect_id % nao encontrado', p_prospect_id;
    END IF;

    IF v_current_status = 'ENCERRADO' THEN
        IF v_current_motivo IS DISTINCT FROM p_motivo THEN
            RAISE EXCEPTION 'close_prospect: prospect % ja encerrado com motivo % (recebido %) -- nao reescreve motivo diferente', p_prospect_id, v_current_motivo, p_motivo;
        END IF;
        RETURN QUERY SELECT p_prospect_id, v_current_status, v_current_motivo;
        RETURN;
    END IF;

    UPDATE rufino_linkedin.prospects
       SET status = 'ENCERRADO', motivo_encerramento = p_motivo,
           lock_version = lock_version + 1, updated_at = now()
     WHERE rufino_linkedin.prospects.prospect_id = p_prospect_id;

    INSERT INTO rufino_linkedin.prospect_events (prospect_id, event_type, detalhe, actor, source_workflow, execution_id)
    VALUES (p_prospect_id, 'ENCERRADO', jsonb_build_object('motivo', p_motivo), p_actor, p_workflow_name, p_execution_id);

    RETURN QUERY SELECT p_prospect_id, 'ENCERRADO'::text, p_motivo;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.close_prospect(uuid, text, text, text, text) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- 24) link_prospect_to_connection — reconciliação no sentido connections→
--     prospects (o inverso do que register_prospect já faz no cadastro).
--     Chamada depois que register_connection (WF-01, inalterado) grava uma
--     conexão nova — não dentro do mesmo workflow nesta rodada (nenhum
--     workflow foi alterado), fica como um node Postgres adicional a
--     acrescentar ao WF-01 quando isso for autorizado, ou como reconciliação
--     manual/periódica enquanto isso não acontece. Idempotente: mesma
--     connection_id duas vezes é no-op; connection_id diferente da já
--     vinculada é rejeitado como conflito de dados (nunca sobrescreve).
-- -----------------------------------------------------------------------------
CREATE FUNCTION rufino_linkedin.link_prospect_to_connection(
    p_connection_id   uuid,
    p_workflow_name   text DEFAULT 'WF-01',
    p_execution_id    text DEFAULT NULL
)
RETURNS TABLE (
    prospect_id       uuid,
    linked            boolean,
    previous_status   text,
    new_status        text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rufino_linkedin, extensions, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
    v_profile_url             text;
    v_canonical               text;
    v_data_conexao            date;
    v_prospect_id             uuid;
    v_current_status          text;
    v_existing_connection_id  uuid;
    v_new_status              text;
BEGIN
    SELECT c.profile_url, c.data_conexao INTO v_profile_url, v_data_conexao
      FROM rufino_linkedin.connections c
     WHERE c.connection_id = p_connection_id;

    IF v_profile_url IS NULL THEN
        RAISE EXCEPTION 'link_prospect_to_connection: connection_id % nao encontrado', p_connection_id;
    END IF;

    v_canonical := rufino_linkedin.normalize_linkedin_url(v_profile_url);

    SELECT p.prospect_id, p.status, p.connection_id
      INTO v_prospect_id, v_current_status, v_existing_connection_id
      FROM rufino_linkedin.prospects p
     WHERE p.canonical_profile_url = v_canonical
     FOR UPDATE;

    IF v_prospect_id IS NULL THEN
        -- Conexao fora do funil de prospeccao -- nada a vincular.
        RETURN QUERY SELECT NULL::uuid, false, NULL::text, NULL::text;
        RETURN;
    END IF;

    IF v_existing_connection_id IS NOT NULL THEN
        IF v_existing_connection_id <> p_connection_id THEN
            RAISE EXCEPTION 'link_prospect_to_connection: prospect % ja vinculado a connection % (recebido %) -- conflito de dados, nao sobrescrito', v_prospect_id, v_existing_connection_id, p_connection_id;
        END IF;
        RETURN QUERY SELECT v_prospect_id, true, v_current_status, v_current_status;
        RETURN;
    END IF;

    v_new_status := CASE WHEN v_current_status = 'ENCERRADO' THEN 'ENCERRADO' ELSE 'CONECTADO' END;

    UPDATE rufino_linkedin.prospects
       SET connection_id = p_connection_id,
           status = v_new_status,
           convite_aceito_em = COALESCE(convite_aceito_em, v_data_conexao::timestamptz),
           lock_version = lock_version + 1, updated_at = now()
     WHERE rufino_linkedin.prospects.prospect_id = v_prospect_id;

    INSERT INTO rufino_linkedin.prospect_events (prospect_id, event_type, detalhe, actor, source_workflow, execution_id)
    VALUES (v_prospect_id, 'VINCULADO_CONNECTION', jsonb_build_object('connection_id', p_connection_id), 'sistema', p_workflow_name, p_execution_id);

    RETURN QUERY SELECT v_prospect_id, true, v_current_status, v_new_status;
END;
$fn$;

ALTER FUNCTION rufino_linkedin.link_prospect_to_connection(uuid, text, text) OWNER TO n8n_rufino_linkedin_owner_dev;

-- -----------------------------------------------------------------------------
-- Permissões do adendo — mesma transação, mesma disciplina: REVOKE FROM
-- PUBLIC em todas (inclusive as 2 internas); GRANT EXECUTE só para a role
-- de aplicação nas 7 de negócio.
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION rufino_linkedin.normalize_linkedin_url(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.normalize_school_name(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.register_prospect(
    text, text, text, text, text, text, text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.qualify_prospect(
    uuid, text, text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.get_daily_prospect_queue(integer, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.mark_invite_sent(uuid, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.confirm_invite_accepted(uuid, timestamptz, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.close_prospect(uuid, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rufino_linkedin.link_prospect_to_connection(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION rufino_linkedin.register_prospect(
    text, text, text, text, text, text, text, text, text, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.qualify_prospect(
    uuid, text, text, text, text, text, text
) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.get_daily_prospect_queue(integer, text, text) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.mark_invite_sent(uuid, text, text, text) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.confirm_invite_accepted(uuid, timestamptz, text, text, text) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.close_prospect(uuid, text, text, text, text) TO n8n_rufino_linkedin_dev;
GRANT EXECUTE ON FUNCTION rufino_linkedin.link_prospect_to_connection(uuid, text, text) TO n8n_rufino_linkedin_dev;


COMMIT;
