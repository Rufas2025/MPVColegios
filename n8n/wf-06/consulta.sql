-- Contatos que viram cartão às 9h de hoje, ainda com a versão 1 do modelo e com pesquisa útil (alta ou média).
SELECT c.connection_id::text AS connection_id, c.nome, c.primeiro_nome, c.cargo, c.instituicao,
       COALESCE((SELECT a.resumo FROM rufino_linkedin.analyses a WHERE a.connection_id = c.connection_id
                  ORDER BY a.created_at DESC LIMIT 1), c.cargo, '') AS titulo,
       mv.message_body AS mensagem_modelo,
       r.confianca, r.trajetoria, r.tempo_de_casa, r.rapport, r.bloco_cartao
  FROM rufino_linkedin.connections c
  JOIN LATERAL (SELECT m.version, m.source, m.edited_by, m.message_body FROM rufino_linkedin.message_versions m
                 WHERE m.connection_id = c.connection_id ORDER BY m.version DESC LIMIT 1) mv ON true
  JOIN LATERAL rufino_linkedin.get_contact_research(c.connection_id, 90) r ON true
 WHERE c.status = 'AGUARDANDO_D1'
   AND c.scheduled_at <= ((now() AT TIME ZONE 'America/Sao_Paulo')::date + time '09:05') AT TIME ZONE 'America/Sao_Paulo'
   AND mv.version = 1 AND mv.source = 'gpt' AND mv.edited_by IS NULL
   AND r.confianca IN ('alta', 'media')
 ORDER BY c.scheduled_at, c.nome
 LIMIT 60;
