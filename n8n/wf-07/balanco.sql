-- WF-07 Balanço semanal (Anderson, 27/11/2026): toda segunda 8h, números da semana anterior (seg a dom)
-- e do acumulado. Somente leitura. Uma linha com um JSON.
--   enviada   = evento MARCADO_COMO_ENVIADO (primeiro);
--   respondeu = histórico com new_status RESPONDEU (botão do lembrete ou /respondeu);
--   tipo      = última versão da mensagem: modelo (sem edited_by), automática (auto-pesquisa:*), feita à mão (resto);
--   contatos de teste (nome começando com "teste") ficam de fora;
--   perfil    = mesmo critério do WF-01E (mantenedor / pedagógico / gestão), sobre título + cargo.
WITH jan AS (
    SELECT (date_trunc('week', now() AT TIME ZONE 'America/Sao_Paulo') - interval '7 days') AT TIME ZONE 'America/Sao_Paulo' AS ini,
           date_trunc('week', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo' AS fim
), env AS (
    SELECT d.connection_id, min(d.event_at) AS enviado_em
      FROM rufino_linkedin.delivery_events d
     WHERE d.event_type = 'MARCADO_COMO_ENVIADO'
     GROUP BY d.connection_id
), resp AS (
    SELECT h.connection_id, min(h.created_at) AS respondeu_em
      FROM rufino_linkedin.connection_status_history h
     WHERE h.new_status = 'RESPONDEU'
     GROUP BY h.connection_id
), ult AS (
    SELECT DISTINCT ON (m.connection_id) m.connection_id, m.edited_by
      FROM rufino_linkedin.message_versions m
     ORDER BY m.connection_id, m.version DESC
), base AS (
    SELECT c.connection_id, c.nome, c.status, e.enviado_em, r.respondeu_em,
           CASE WHEN u.edited_by IS NULL THEN 'Modelo padrão'
                WHEN u.edited_by LIKE 'auto-pesquisa:%' THEN 'Personalizada automática'
                ELSE 'Personalizada à mão' END AS tipo,
           CASE WHEN t.h ~ '(mantenedor|fundador|founder|\msoci[oa]\M|proprietari|\mowner\M|\mceo\M|presidente)' THEN 'Mantenedor'
                WHEN t.h ~ '(pedagogic|coordenador|coordenacao|academic|diretora? de ensino)' THEN 'Pedagógico'
                ELSE 'Gestão' END AS perfil
      FROM env e
      JOIN rufino_linkedin.connections c ON c.connection_id = e.connection_id AND c.nome NOT ILIKE 'teste%'
      LEFT JOIN resp r ON r.connection_id = e.connection_id
      LEFT JOIN ult u ON u.connection_id = e.connection_id
      CROSS JOIN LATERAL (
          SELECT translate(lower(coalesce((SELECT a.resumo FROM rufino_linkedin.analyses a
                                            WHERE a.connection_id = c.connection_id
                                            ORDER BY a.created_at DESC LIMIT 1), '') || ' ' || coalesce(c.cargo, '')),
                           'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc') AS h
      ) t
)
SELECT json_build_object(
    'semana', to_char(j.ini AT TIME ZONE 'America/Sao_Paulo', 'DD/MM') || ' a '
              || to_char((j.fim AT TIME ZONE 'America/Sao_Paulo') - interval '1 day', 'DD/MM'),
    'aceites_semana', (SELECT count(*) FROM rufino_linkedin.connections c
                        WHERE c.created_at >= j.ini AND c.created_at < j.fim AND c.nome NOT ILIKE 'teste%'),
    'enviadas_semana', (SELECT count(*) FROM base b WHERE b.enviado_em >= j.ini AND b.enviado_em < j.fim),
    'responderam_das_enviadas_semana', (SELECT count(*) FROM base b
                                         WHERE b.enviado_em >= j.ini AND b.enviado_em < j.fim AND b.respondeu_em IS NOT NULL),
    'respostas_na_semana', (SELECT coalesce(json_agg(b.nome ORDER BY b.respondeu_em), '[]'::json) FROM base b
                             WHERE b.respondeu_em >= j.ini AND b.respondeu_em < j.fim),
    'total_enviadas', (SELECT count(*) FROM base),
    'total_responderam', (SELECT count(*) FROM base b WHERE b.respondeu_em IS NOT NULL),
    'por_tipo', (SELECT coalesce(json_agg(x ORDER BY x.enviadas DESC), '[]'::json) FROM (
                   SELECT b.tipo AS nome, count(*) AS enviadas, count(b.respondeu_em) AS responderam
                     FROM base b GROUP BY b.tipo) x),
    'por_perfil', (SELECT coalesce(json_agg(x ORDER BY x.enviadas DESC), '[]'::json) FROM (
                     SELECT b.perfil AS nome, count(*) AS enviadas, count(b.respondeu_em) AS responderam
                       FROM base b GROUP BY b.perfil) x),
    'sem_resposta_7d', (SELECT count(*) FROM base b
                         WHERE b.status = 'FOLLOWUP_PENDENTE' AND b.enviado_em < now() - interval '7 days'),
    'sem_resposta_7d_nomes', (SELECT coalesce(json_agg(x.nome ORDER BY x.enviado_em), '[]'::json) FROM (
                               SELECT b.nome, b.enviado_em FROM base b
                                WHERE b.status = 'FOLLOWUP_PENDENTE' AND b.enviado_em < now() - interval '7 days'
                                ORDER BY b.enviado_em LIMIT 12) x),
    'aguardando_aprovacao', (SELECT count(*) FROM rufino_linkedin.connections c
                              WHERE c.status IN ('AGUARDANDO_APROVACAO', 'REFAZER') AND c.nome NOT ILIKE 'teste%'),
    'falta_marcar_enviada', (SELECT count(*) FROM rufino_linkedin.connections c
                              WHERE c.status IN ('APROVADO', 'PRONTO_PARA_ENVIO') AND c.nome NOT ILIKE 'teste%')
) AS balanco
  FROM jan j;
