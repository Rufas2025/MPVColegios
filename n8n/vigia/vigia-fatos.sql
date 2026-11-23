-- WF-90 Vigia: fatos do banco para o relatório diário e os alertas.
-- Somente leitura (SELECT). Roda com a credencial do app "Rufino LinkedIn DEV".
-- Devolve uma linha com um JSON; quem decide o que é alerta é o nó "Avaliar" (vigia-avaliar.js),
-- porque só ele conhece os feriados da tabela de dados do n8n.
WITH
fila AS (                      -- mesma ordem de claim_due_connections (WF-02)
    SELECT c.primeiro_nome, c.nome, c.data_conexao, c.scheduled_at, c.created_at,
           row_number() OVER (ORDER BY c.scheduled_at, c.connection_id) AS pos
      FROM rufino_linkedin.connections c
     WHERE c.status = 'AGUARDANDO_D1'
),
botoes AS (                    -- último botão de cada contato que está esperando um toque
    SELECT DISTINCT ON (c.connection_id)
           c.primeiro_nome, c.nome, c.status, t.scope, t.expires_at
      FROM rufino_linkedin.connections c
      JOIN rufino_linkedin.action_tokens t ON t.connection_id = c.connection_id
     WHERE c.status IN ('AGUARDANDO_APROVACAO', 'PRONTO_PARA_ENVIO')
       AND t.consumed_at IS NULL
     ORDER BY c.connection_id, t.created_at DESC
),
followups_abertos AS (
    SELECT f.scheduled_for, f.created_at, f.claimed_at, f.claim_expires_at, c.primeiro_nome, c.nome
      FROM rufino_linkedin.followups f
      JOIN rufino_linkedin.connections c ON c.connection_id = f.connection_id
     WHERE f.executed_at IS NULL
)
SELECT json_build_object(
    'agora', now(),
    'fila', COALESCE((SELECT json_agg(json_build_object(
                'nome', f.nome, 'primeiro', f.primeiro_nome, 'data_conexao', f.data_conexao,
                'scheduled_at', f.scheduled_at, 'created_at', f.created_at) ORDER BY f.pos) FROM fila f), '[]'::json),
    'ultima_reivindicacao_d1', (SELECT max(h.created_at)
                                  FROM rufino_linkedin.connection_status_history h
                                 WHERE h.new_status = 'AGUARDANDO_APROVACAO'
                                   AND h.previous_status = 'AGUARDANDO_D1'),
    -- Aprovações liberadas pelo WF-02 por dia (Brasília) nos últimos 20 dias; "recentes" = aceites de até 4 dias,
    -- que é o volume que a referência de 20/dia mede (as ondas do export ficam de fora).
    'aprovacoes_por_dia', COALESCE((SELECT json_agg(json_build_object('dia', x.dia, 'total', x.total, 'recentes', x.recentes) ORDER BY x.dia)
                              FROM (SELECT (h.created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
                                           count(*) AS total,
                                           count(*) FILTER (WHERE c.data_conexao >= (h.created_at AT TIME ZONE 'America/Sao_Paulo')::date - 4) AS recentes
                                      FROM rufino_linkedin.connection_status_history h
                                      JOIN rufino_linkedin.connections c ON c.connection_id = h.connection_id
                                     WHERE h.new_status = 'AGUARDANDO_APROVACAO' AND h.previous_status = 'AGUARDANDO_D1'
                                       AND h.created_at >= now() - interval '20 days'
                                     GROUP BY 1) x), '[]'::json),
    -- Painel: envios, descartes e respostas por dia (Brasília), últimos 14 dias.
    'movimentos_por_dia', COALESCE((SELECT json_agg(json_build_object('dia', m.dia, 'enviados', m.enviados,
                                    'descartados', m.descartados, 'respondidos', m.respondidos) ORDER BY m.dia)
                              FROM (SELECT (h.created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
                                           count(*) FILTER (WHERE h.new_status = 'ENVIADO') AS enviados,
                                           count(*) FILTER (WHERE h.new_status = 'DESCARTADO') AS descartados,
                                           count(*) FILTER (WHERE h.new_status = 'RESPONDEU') AS respondidos
                                      FROM rufino_linkedin.connection_status_history h
                                     WHERE h.new_status IN ('ENVIADO', 'DESCARTADO', 'RESPONDEU')
                                       AND h.created_at >= now() - interval '14 days'
                                     GROUP BY 1) m), '[]'::json),
    'ultimo_claim_followup', (SELECT max(f.claimed_at) FROM rufino_linkedin.followups f),
    'botoes', COALESCE((SELECT json_agg(json_build_object(
                'nome', b.nome, 'primeiro', b.primeiro_nome, 'status', b.status,
                'scope', b.scope, 'expires_at', b.expires_at) ORDER BY b.expires_at) FROM botoes b), '[]'::json),
    'sem_botao', (SELECT count(*) FROM rufino_linkedin.connections c
                   WHERE c.status IN ('AGUARDANDO_APROVACAO', 'PRONTO_PARA_ENVIO')
                     AND NOT EXISTS (SELECT 1 FROM rufino_linkedin.action_tokens t
                                      WHERE t.connection_id = c.connection_id AND t.consumed_at IS NULL)),
    'notificacoes_presas', (SELECT count(*) FROM rufino_linkedin.notification_jobs n
                             WHERE n.status IN ('PENDING', 'CLAIMED')
                               AND n.created_at < now() - interval '15 minutes'),
    'followups', COALESCE((SELECT json_agg(json_build_object(
                'nome', fa.nome, 'primeiro', fa.primeiro_nome, 'scheduled_for', fa.scheduled_for, 'created_at', fa.created_at,
                'claimed_at', fa.claimed_at, 'claim_expires_at', fa.claim_expires_at)
                ORDER BY fa.scheduled_for) FROM followups_abertos fa), '[]'::json),
    'erros_abertos', (SELECT count(*) FROM rufino_linkedin.workflow_errors e WHERE NOT e.resolved),
    'status_erro', (SELECT count(*) FROM rufino_linkedin.connections c WHERE c.status = 'ERRO'),
    'ultimo_aceite_email', (SELECT max(c.created_at)
                              FROM rufino_linkedin.connections c
                             WHERE c.data_conexao_origem = 'linkedin_email_notificacao_aceite')
) AS fatos;
