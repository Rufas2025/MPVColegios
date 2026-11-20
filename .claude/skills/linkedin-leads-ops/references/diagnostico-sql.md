# Consultas de diagnóstico (somente leitura)

Rodar no workflow `99 - TEMP Manual SQL - Rufino LinkedIn DEV` com a credencial **`Rufino LinkedIn DEV`**
(app, só SELECT). Nunca use a credencial DDL para leitura. O app não lê `operational_config`.

## Resumo do dia

```sql
SELECT status, count(*) FROM rufino_linkedin.connections GROUP BY status ORDER BY status;
```

## Contatos com agenda e mensagem atual

```sql
SELECT c.nome, c.status, c.data_conexao, c.scheduled_at AT TIME ZONE 'America/Sao_Paulo' AS agendado_brasilia,
       c.data_conexao_origem, left(mv.message_body, 60) AS inicio_msg, mv.version
  FROM rufino_linkedin.connections c
  JOIN LATERAL (SELECT * FROM rufino_linkedin.message_versions m
                 WHERE m.connection_id = c.connection_id ORDER BY m.version DESC LIMIT 1) mv ON true
 ORDER BY c.scheduled_at;
```

## Duplicatas

```sql
SELECT lower(rtrim(profile_url, '/')) AS url, count(*) FROM rufino_linkedin.connections GROUP BY 1 HAVING count(*) > 1;
SELECT lower(nome) AS nome, count(*) FROM rufino_linkedin.connections GROUP BY 1 HAVING count(*) > 1;
```

## Notificações presas ou recentes

```sql
SELECT c.nome, j.job_type, j.status, j.created_at, j.claim_expires_at, j.delivered_at
  FROM rufino_linkedin.notification_jobs j JOIN rufino_linkedin.connections c USING (connection_id)
 WHERE j.status IN ('PENDING', 'CLAIMED') OR j.created_at > now() - interval '1 day'
 ORDER BY j.created_at DESC;
```

## Follow-ups pendentes e validade do botão

```sql
SELECT c.nome, f.sequence, f.scheduled_for, f.claimed_at, f.claim_expires_at, f.executed_at, f.resultado
  FROM rufino_linkedin.followups f JOIN rufino_linkedin.connections c USING (connection_id)
 WHERE f.executed_at IS NULL ORDER BY f.scheduled_for;
```

## Botões de aprovação/entrega ainda válidos

```sql
SELECT c.nome, c.status, t.scope, t.expires_at AT TIME ZONE 'America/Sao_Paulo' AS vence_brasilia
  FROM rufino_linkedin.action_tokens t JOIN rufino_linkedin.connections c USING (connection_id)
 WHERE t.consumed_at IS NULL AND t.expires_at > now() ORDER BY t.expires_at;
```

## Histórico de um contato

```sql
SELECT h.created_at, h.previous_status, h.new_status, h.actor, h.reason, h.workflow_name
  FROM rufino_linkedin.connection_status_history h
  JOIN rufino_linkedin.connections c USING (connection_id)
 WHERE c.nome ILIKE '%nome%' ORDER BY h.created_at;
```

## Versão das funções (conferir migração aplicada)

```sql
SELECT p.proname, md5(pg_get_functiondef(p.oid)) AS md5, pg_get_userbyid(p.proowner) AS dono,
       has_function_privilege('n8n_rufino_linkedin_dev', p.oid, 'execute') AS app,
       has_function_privilege('public', p.oid, 'execute') AS publico
  FROM pg_proc p WHERE p.pronamespace = 'rufino_linkedin'::regnamespace ORDER BY 1;
```

Referência em 20/11/2026: `register_connection` = `ee3a839b97911916ef918a15d9133657` (014),
`claim_due_followups` = `233dab2a9c192afcc9c6581de3a19820` (015). As 25 funções do DEV batem com um banco
local montado só com `db/migrations/dev/`.

## Erros registrados

```sql
SELECT source_workflow, error_type, left(error_message, 120), created_at
  FROM rufino_linkedin.workflow_errors WHERE NOT resolved ORDER BY created_at DESC;
```
