# TEST-REPORT.md — GATE 3, v1.5.0 — estabilização e teste real da camada PostgreSQL

Data: 2026-07-24. Escopo: exclusivamente a migration em `db/migrations/dev/` (v1.5.0). **Nenhum workflow n8n foi criado ou alterado. Nenhum SQL foi executado contra o banco real `rufino-linkedin-dev` nem contra qualquer serviço do EasyPanel.** Todos os testes abaixo rodaram contra um PostgreSQL isolado e descartável, criado e destruído dentro desta mesma tarefa.

## 1. Desvio de ambiente (declarado antes de qualquer teste)

O ambiente real de DEV (`rufino-linkedin-dev`, EasyPanel) roda **PostgreSQL 17.10**. O prompt desta tarefa exigia testar contra um **PostgreSQL 17 descartável**. Isso não foi possível neste ambiente de execução:

- `postgresql.org`/PGDG (fonte oficial dos pacotes/binários do PostgreSQL 17) estão bloqueados pela política de rede do proxy do sandbox (`connect_rejected`, confirmado via `curl -sS "$HTTPS_PROXY/__agentproxy/status"`).
- O daemon Docker não pôde ser iniciado (sem privilégio no sandbox) — inviabilizando um container oficial `postgres:17`.
- O pacote PyPI `pgserver` foi avaliado e descartado: só empacota PostgreSQL 16.2, sem `pgcrypto`.

Diante da escolha entre (a) entregar **NO-GO** sem nenhum teste de execução real, ou (b) usar **PostgreSQL 16.13** (pacote oficial do sistema operacional do sandbox, um Postgres real e não emulado — não uma simulação) como substituto documentado, esta decisão foi explicitamente colocada para Anderson, que escolheu a opção (b). **Todos os testes abaixo, portanto, rodaram contra PostgreSQL 16.13 — nenhum contra PostgreSQL 17.** As construções usadas pela migration (`FOR UPDATE SKIP LOCKED`, `pg_advisory_xact_lock`, `NULLS NOT DISTINCT` em índice parcial, `SECURITY DEFINER`/`search_path`, `#variable_conflict use_column`) têm comportamento idêntico entre PostgreSQL 16.x e 17.x — mas a aplicação real em DEV deve, antes de ser considerada concluída, reexecutar pelo menos `008_validation_queries.sql` e `009_smoke_tests.sql` contra o PostgreSQL 17.10 real de `rufino-linkedin-dev` (ou um clone descartável dele), para fechar esse desvio.

## 2. Ambiente de teste

- PostgreSQL 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1), pacote do sistema operacional do sandbox de execução, cluster local (`localhost:5432`), iniciado e parado só para esta tarefa.
- Banco `rufino-linkedin-dev` criado e destruído dentro deste ambiente local — **não é, e nunca teve qualquer relação de rede com, o banco real do EasyPanel de mesmo nome.**
- Schema `extensions` criado manualmente; `pgcrypto` instalada nele via `CREATE EXTENSION pgcrypto SCHEMA extensions` — reproduzindo a pré-condição que `001_preflight.sql` espera encontrar em DEV real.
- Todas as sessões de `psql` usadas para aplicar/testar a migration rodaram com a credencial administrativa local (`postgres`, equivalente à role administrativa do serviço `linkedin-db` no EasyPanel) — nunca a role de aplicação, exceto onde a própria migration assume essa role via `SET LOCAL ROLE` dentro de `009_smoke_tests.sql`.
- Ambiente completamente destruído ao final: banco derrubado, roles removidas, cluster PostgreSQL parado (`service postgresql stop`).

## 3. Comandos executados (ciclo completo, nesta ordem, nesta sessão)

```
service postgresql start
psql -c "CREATE DATABASE \"rufino-linkedin-dev\";"
psql -d rufino-linkedin-dev -c "CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;"

psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 001_preflight.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 002_roles_and_schema.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 003_tables.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 004_constraints_and_indexes.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 005_rls_and_grants.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 006_functions.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 007_function_permissions.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 008_validation_queries.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 009_smoke_tests.sql

bash tests/run_concurrency_tests.sh

psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f rollback/001_rollback.sql
# --- verificação de remoção total + pgcrypto preservada ---
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 001_preflight.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 002_roles_and_schema.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 003_tables.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 004_constraints_and_indexes.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 005_rls_and_grants.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 006_functions.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 007_function_permissions.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 008_validation_queries.sql
psql -v ON_ERROR_STOP=1 -d rufino-linkedin-dev -f 009_smoke_tests.sql

psql -c "DROP DATABASE \"rufino-linkedin-dev\";"
psql -c "DROP OWNED BY n8n_rufino_linkedin_dev CASCADE;"
psql -c "DROP OWNED BY n8n_rufino_linkedin_owner_dev CASCADE;"
psql -c "DROP ROLE n8n_rufino_linkedin_dev;"
psql -c "DROP ROLE n8n_rufino_linkedin_owner_dev;"
service postgresql stop
```

Todos os arquivos `001`–`007` foram aplicados com `psql -v ON_ERROR_STOP=1` — todos com **exit code 0**, sem exceção.

## 4. Resultado de `008_validation_queries.sql` (21 consultas)

Todas as 21 consultas produziram exatamente o resultado esperado documentado nos comentários do próprio arquivo:

1. **11 tabelas** listadas: `action_tokens`, `analyses`, `approvals`, `callback_receipts`, `connection_status_history`, `connections`, `delivery_events`, `followups`, `message_versions`, `notification_jobs`, `workflow_errors`.
2. **15 funções** listadas com assinatura exata (nomes/tipos de parâmetro conferem com `N8N-INTEGRATION.md`).
3. Todas as 15: `security_definer=t`, `owner=n8n_rufino_linkedin_owner_dev`, `search_path='rufino_linkedin, extensions, pg_temp'`.
4. **12 executáveis pela role de aplicação / 3 não** (`create_notification_job`, `issue_action_token`, `transition_connection_status`); **0 executáveis por `PUBLIC`** em qualquer uma das 15.
4b. Contagem confirmada: `executaveis_pela_app=12`, `total_funcoes=15`.
5. `SELECT`-only confirmado para a role de aplicação nas 11 tabelas.
6. RLS habilitado (`rls_habilitado=t`) e **não forçado** (`rls_forcado=f`) nas 11 tabelas.
7. Roles: owner sem `LOGIN`/`SUPERUSER`/`BYPASSRLS`/`CREATEDB`/`CREATEROLE`/`REPLICATION`; aplicação com `LOGIN`, sem os demais atributos.
8. Senha da role de aplicação **não definida** (`senha_ja_definida=f`) — confirma que a migration nunca grava senha.
9. `pgcrypto` 1.3 confirmada no schema `extensions`.
10. Nenhuma coluna de token bruto encontrada (0 linhas).
11. Grants de `extensions`: owner com `USAGE`+`EXECUTE` em `digest`/`gen_random_bytes`; role de aplicação **sem** `USAGE` (`app_usage_extensions=f`).
12/13. Consultas de dados (vazias — sem massa de dados real fora dos smoke tests, que rodam e desfazem sozinhos).
14. 38 colunas novas/alteradas confirmadas nas 4 tabelas afetadas (`action_tokens`, `callback_receipts`, `connections`, `followups`, `notification_jobs`).
15. **0 linhas** para `pending_action_token_hash`/`pending_action_token_expires_at` em `connections` — confirmando a remoção.
16. 4 constraints `UNIQUE` novas confirmadas: `action_tokens.token_hash`, `followups.callback_query_id`, `followups.claim_token_hash`, `notification_jobs.claim_token_hash`.
17. Índice `workflow_errors_execution_dedupe_key` confirmado, com `NULLS NOT DISTINCT` e a cláusula `WHERE` esperada.
18. **0 estados sem transição de saída** (lista de arestas completa).
19. Roles confirmadas sem privilégio administrativo.
20. **0 linhas** de membership da role de aplicação na owner.
21. `delivery_events_delivery_mode_check` confirmado só com `MANUAL_ASSISTED`.

## 5. Resultado de `009_smoke_tests.sql` (36 itens)

Execução completa dentro de `BEGIN...ROLLBACK` (nunca `COMMIT`), usando `SET LOCAL ROLE n8n_rufino_linkedin_dev` para simular a role real de aplicação.

**Resultado: 36 de 36 itens `SMOKE OK`. Zero `SMOKE FALHOU`. Zero erros (`ERROR`). Exit code 0.**

Cobertura confirmada por execução real (não apenas leitura do SQL):
- `[PRE]`/`[PRE-2]`: 0 funções executáveis por `PUBLIC`; app sem privilégio administrativo.
- Registro idempotente (`register_connection`), retry sem duplicar.
- `claim_due_connections` cria atomicamente o job `notification_jobs(APPROVAL)`.
- `claim_notification_jobs` reivindica o job e gera o `action_token`; `octet_length` de todos os 8 formatos de `callback_data` (`a:A`/`a:E`/`a:R`/`a:D`/`a:S`/`a:B`/`f:R`/`f:N`) medido em **52 bytes**, dentro do limite de 64.
- `confirm_notification_delivery` e seu retry idempotente.
- `approve_message` (`APROVAR_E_PREPARAR`), retry idempotente via `callback_receipts`, rejeição de conflito (mesmo `callback_query_id`, conteúdo diferente), rejeição de token já consumido mesmo com `callback_query_id` novo.
- `present_message_for_delivery` rejeitando versão obsoleta; criação do job `DELIVERY`.
- Ciclo completo de entrega: claim → confirm → `mark_message_sent` (`MARCAR_ENVIADA`, exige `p_first_followup_at`) → cria `followups sequence=1`; retry idempotente devolvendo os mesmos `connection_id`/`delivery_event_id`/`followup_id`/status.
- `claim_due_followups` (token de 48 caracteres hex) e `complete_followup` (`RESPONDEU` → `ENCERRADO`), retry idempotente.
- Segundo ciclo completo em conexão distinta com `SEM_RESPOSTA` (cria `sequence=2`, depois `ENCERRADO`).
- **Reclaim de follow-up**: worker A reivindica, claim forçado a expirar, worker B reivindica o mesmo `followup_id` com token novo; token do worker A rejeitado (`invalido`); um followup executado nunca é reivindicado de novo.
- **Reclaim de notification job**: worker A reivindica, claim forçado a expirar, worker B reivindica o mesmo job com `claim_token`/`action_token` novos; `claim_token`/`action_token` do worker A rejeitados (`consumido`) tanto em `confirm_notification_delivery` quanto em `approve_message`.
- Fluxo `EDITAR` e fluxo `REFAZER` (com drenagem explícita do job de notificação subsequente), incluindo rejeição de `regeneration_token` de uso único e expirado.
- Rejeição de transição a partir de status forjado/incorreto.
- `DESCARTAR` terminal.
- `record_workflow_error`: `retry_count` 0→1 corretamente incrementado; transição para `ERRO`; retry idempotente pelo mesmo `execution_id` (não duplica).
- Escrita direta negada; as 3 funções internas negadas para a role de aplicação; acesso a `extensions` negado para a role de aplicação.
- Recheque final: 0 funções executáveis por `PUBLIC`.

**Nenhum dado ficou persistido** após o `ROLLBACK` — verificado por contagem direta em `connections`, `action_tokens`, `callback_receipts`, `notification_jobs`, `followups`, `workflow_errors` (todas com `count=0`).

## 6. Testes de concorrência real (duas sessões `psql`, `tests/run_concurrency_tests.sh`)

### Teste 1 — `record_workflow_error` concorrente em duas sessões reais

Sessão A abre uma transação, chama `record_workflow_error` para a chave `(connection_id, source_workflow, error_type)` com `execution_id='concurrency-test-exec-A'`, aguarda (`pg_sleep`) e faz `COMMIT`. Sessão B, disparada quase simultaneamente com `execution_id='concurrency-test-exec-B'`, bloqueia no `pg_advisory_xact_lock` até a Sessão A commitar.

**Resultado:** Sessão A recebeu `retry_count=0`; Sessão B recebeu `retry_count=1` — nunca o mesmo valor duas vezes, mesmo com as duas chamadas efetivamente concorrentes. Serialização via `pg_advisory_xact_lock` confirmada por execução real, não por leitura do código.

### Teste 2 — duas sessões reivindicando `notification_jobs` simultaneamente

Duas linhas `PENDING` pré-criadas; duas sessões `psql` reais disparam `claim_notification_jobs(2)` o mais próximo possível uma da outra.

**Resultado:** Sessão 1 reivindicou 0 jobs (chegou depois, `FOR UPDATE SKIP LOCKED` já tinha os dois bloqueados); Sessão 2 reivindicou os 2 jobs. Total de UUIDs reivindicados: 4 valores distintos (2 jobs × `notification_job_id`+`connection_id`), **conjuntos disjuntos, sem sobreposição** — confirma que `FOR UPDATE SKIP LOCKED` nunca deixa duas sessões reivindicarem a mesma linha.

**Ambos os testes de concorrência passaram.** Dados de teste limpos manualmente ao final do script (esses dois testes usam `COMMIT`, não `ROLLBACK`, porque provar concorrência real exige que a primeira transação efetivamente commite antes da segunda prosseguir — documentado em `010_concurrency_tests.md`).

## 7. Rollback e reaplicação

- `rollback/001_rollback.sql` executado com `ON_ERROR_STOP=1`, exit code 0.
- Verificado por consulta direta: **0 tabelas** restantes no schema `rufino_linkedin`; **0 linhas** em `pg_namespace` para `rufino_linkedin` (schema removido); **0 roles** `n8n_rufino_linkedin_dev`/`n8n_rufino_linkedin_owner_dev` restantes; **`pgcrypto` 1.3 preservada** no schema `extensions`.
- Migration reaplicada do zero (`001`–`007`, todos exit code 0) contra o mesmo banco, sem nenhum erro de objeto residual.
- `008_validation_queries.sql` e `009_smoke_tests.sql` reexecutados após a reaplicação: **mesmos resultados** (21/21 consultas corretas; 36/36 smoke tests OK, 0 falhas).

## 8. Ausências confirmadas (negativas testadas, não apenas assumidas)

- Nenhuma escrita direta (`INSERT`/`UPDATE`) permitida à role de aplicação em nenhuma tabela — testado e rejeitado.
- Nenhuma das 15 funções executável por `PUBLIC` — testado (query 4 + item `[PRE]`/`[33]` do smoke test) antes e depois da reaplicação.
- A role de aplicação não acessa o schema `extensions` — testado e rejeitado (item 32 do smoke test); nenhuma chamada direta a `extensions.gen_random_bytes` existe em `009_smoke_tests.sql` sob a role do n8n (Correção 9 da v1.5.0).
- Nenhum job/followup entregue ou executado volta a ser reivindicado — testado explicitamente nos itens de reclaim.
- Nenhum token bruto persistido em nenhuma tabela — confirmado por revisão de todo `INSERT`/`RETURN QUERY` de `006_functions.sql` (Seção 13).

## 9. Riscos residuais reais

1. **Testes rodaram em PostgreSQL 16.13, não 17.10** (o real de `rufino-linkedin-dev`) — desvio explicitamente aprovado por Anderson, ver Seção 1. Recomenda-se reexecutar pelo menos `008`/`009` contra PostgreSQL 17 real (ou um clone descartável de DEV) antes da aplicação controlada.
2. **Retomada manual de `ERRO` continua administrativa** — sem mudança nesta versão, aceito por desenho (ver `MANUAL-STEPS.md`, seção 4).
3. **Telegram não é exactly-once** — o outbox garante que a intenção de notificar nunca se perde, mas uma entrega duplicada é possível se o envio remoto tiver sucesso e o worker cair antes de `confirm_notification_delivery`; os cliques subsequentes continuam seguros pela idempotência de `callback_receipts`. Documentado em `N8N-INTEGRATION.md`.
4. **Ambiente PROD** ainda não tem pasta própria (`db/migrations/prod/` não existe) — todos os riscos de `pgcrypto`/schema para PROD, já registrados desde a v1.4.0, continuam abertos.
5. **GATE 4 (nodes do n8n) não iniciado** — por desenho explícito desta rodada; é o próximo passo, usando `N8N-INTEGRATION.md` como contrato congelado.

## 10. Confirmação de escopo

- **EasyPanel:** nenhuma alteração. Nenhuma credencial, projeto ou serviço do EasyPanel foi acessado nesta tarefa.
- **n8n:** nenhum workflow criado, editado, importado ou executado.
- **Banco real `rufino-linkedin-dev` (EasyPanel):** nenhum SQL executado contra ele. Todos os comandos da Seção 3 rodaram contra um PostgreSQL local, descartável, sem qualquer conectividade com o ambiente EasyPanel.
- **Credenciais/senhas:** nenhuma credencial ou senha real foi usada, gerada ou persistida em qualquer arquivo.
- **Tokens brutos:** nenhum persistido em nenhuma tabela, em nenhum momento dos testes.

## 11. Conclusão

**GO PARA APLICAÇÃO CONTROLADA EM DEV**, condicionado à reexecução de `008_validation_queries.sql` e `009_smoke_tests.sql` contra PostgreSQL 17 real (ou clone descartável de DEV) antes da aplicação efetiva contra `rufino-linkedin-dev`, dado que todos os testes desta rodada rodaram em PostgreSQL 16.13 como desvio de ambiente explicitamente aprovado (Seção 1). Dentro dessa condição: arquitetura, schema, hardening `SECURITY DEFINER`, RLS/grants, idempotência real de callbacks, outbox durável, claims com posse e reclaim seguro, concorrência (record_workflow_error e claim_notification_jobs testados com duas sessões reais), e rollback/reaplicação — todos comprovados por execução real, não apenas por revisão estática. O contrato do banco está congelado (`N8N-INTEGRATION.md`) para a implementação dos nodes do n8n no GATE 4.
