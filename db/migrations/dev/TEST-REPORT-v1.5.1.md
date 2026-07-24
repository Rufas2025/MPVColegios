# TEST-REPORT-v1.5.1.md — correção pontual de 3 defeitos confirmados no GATE 3

Data: 2026-07-24. Escopo: correção pontual de 3 defeitos confirmados na migration v1.5.0 (`db/migrations/dev/`), sem reescrever arquitetura, sem criar workflow, sem alterar EasyPanel/n8n, sem tocar no banco real, sem alterar nenhuma assinatura pública congelada em `N8N-INTEGRATION.md`. Baseline oficial desta rodada: `rufino-linkedin-gate3-migration-dev-v1.5.0.zip`, `rufino-linkedin-n8n-ops-v1.5.0.zip`, `rufino-linkedin-n8n-ops-v1.5.0.skill`, `TEST-REPORT.md` e `N8N-INTEGRATION.md` da v1.5.0.

## 1. Os 3 defeitos corrigidos

### Correção 1 — token bruto dentro de JSONB

**Problema confirmado:** `approve_message` montava `callback_receipts.result` incluindo `raw_edit_token`/`raw_regeneration_token` — persistindo token bruto dentro de uma coluna JSONB, contradizendo a regra "nenhum token bruto é persistido em lugar nenhum".

**Correção:** `callback_receipts.result` para `approve_message` agora guarda só `approval_id`/`connection_id`/`decision`/`new_status`/`continuation` (`'EDIT'`/`'REGENERATE'`/`'NONE'`) — nunca um valor de token. Um retry (mesmo `callback_query_id`, mesmo fingerprint) cujo `continuation` seja `EDIT` ou `REGENERATE`, com a conexão ainda no estado que esperava aquele token (`AGUARDANDO_APROVACAO` ou `REFAZER`, respectivamente), gera e devolve um token **novo**, rotacionando o hash atomicamente — sem repetir a decisão de negócio (sem novo `approval`, sem nova transição, sem nova versão, sem novo job). Se o fluxo já tiver avançado, os tokens de continuação voltam `NULL`. Arquivo: `006_functions.sql`, função `approve_message`.

### Correção 2 — outbox bloqueando múltiplas entregas históricas

**Problema confirmado:** `notification_jobs_active_per_connection_type_key UNIQUE (connection_id, job_type, status)` impedia duas linhas `DELIVERED` (ou duas `SUPERSEDED`) para a mesma `connection_id`+`job_type` — quebrando o fluxo real de apresentar → editar/refazer → apresentar de novo.

**Correção:** substituída por um índice `UNIQUE` parcial — `notification_jobs_one_active_per_connection_type_idx ON (connection_id, job_type) WHERE status IN ('PENDING', 'CLAIMED')` — que só proíbe dois jobs **ativos** simultâneos; qualquer quantidade de linhas `DELIVERED`/`SUPERSEDED` históricas passa a ser permitida. `create_notification_job` não precisou mudar (já superava o job ativo anterior antes de inserir o novo). Arquivos: `004_constraints_and_indexes.sql`.

### Correção 3 — retry atrasado rejeitado por checagem de data

**Problema confirmado:** `mark_message_sent` validava `p_first_followup_at <= now()` e `complete_followup` validava `p_next_followup_at <= now()` **antes** de consultar `callback_receipts` — um retry legítimo (ex.: reentrega do Telegram) que chegasse depois que a data agendada já tivesse passado de verdade era rejeitado por engano.

**Correção:** a ordem de validação foi invertida — ambas as funções agora checam `callback_receipts` (por `callback_query_id`+fingerprint) **antes** de validar que a data é futura; a checagem de data só se aplica quando não existe receipt (primeira chamada). Um retry com o mesmo conteúdo é sempre devolvido do receipt persistido, mesmo com a data no passado. Mesmo `callback_query_id` com fingerprint diferente continua falhando como conflito. Arquivo: `006_functions.sql`, funções `mark_message_sent` e `complete_followup`.

## 2. Nenhuma assinatura pública mudou

As 15 funções foram reconferidas por consulta real a `pg_proc` depois da reaplicação — todas as assinaturas (nomes e tipos de parâmetro, ordem, defaults) são **idênticas** às registradas em `TEST-REPORT.md` da v1.5.0, incluindo `approve_message`, `mark_message_sent` e `complete_followup` (as 3 funções corrigidas). `N8N-INTEGRATION.md` continua válido tal como estava; foram acrescentadas apenas notas de esclarecimento de comportamento de retry (Correções 1 e 3) nas seções de `approve_message`, `mark_message_sent` e `complete_followup` — nenhum parâmetro, retorno ou nome de função mudou.

## 3. Ambiente de teste

Mesmo desvio documentado desde a v1.5.0: PostgreSQL 17 (a versão real de `rufino-linkedin-dev`) segue indisponível no ambiente de execução desta tarefa (proxy bloqueia `postgresql.org`/PGDG; Docker sem privilégio de iniciar). Todos os testes desta rodada rodaram contra **PostgreSQL 16.13** (pacote do sistema, real, não emulado), banco `rufino-linkedin-dev` local, criado e destruído dentro desta tarefa — **sem qualquer relação de rede com o EasyPanel real**.

## 4. Comandos executados (ciclo completo)

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
bash tests/run_delayed_retry_tests.sh

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
bash tests/run_concurrency_tests.sh
bash tests/run_delayed_retry_tests.sh

psql -c "DROP DATABASE \"rufino-linkedin-dev\";"
psql -c "DROP OWNED BY n8n_rufino_linkedin_dev CASCADE;"
psql -c "DROP OWNED BY n8n_rufino_linkedin_owner_dev CASCADE;"
psql -c "DROP ROLE n8n_rufino_linkedin_dev;"
psql -c "DROP ROLE n8n_rufino_linkedin_owner_dev;"
service postgresql stop
```

Todos os arquivos `001`–`007` foram aplicados com `psql -v ON_ERROR_STOP=1` — exit code 0 em toda a rodada, tanto na aplicação inicial quanto na reaplicação pós-rollback.

## 5. Resultado de `008_validation_queries.sql` (23 consultas — 21 herdadas da v1.5.0 + 2 novas)

Todas as 23 consultas produziram o resultado esperado:

- As 21 consultas da v1.5.0 (tabelas, funções, hardening, RLS, roles, ausência de token bruto por nome de coluna, `NULLS NOT DISTINCT`, etc.) continuam corretas sem regressão.
- **Consulta 22 [nova, Correção 2]:** índice `notification_jobs_one_active_per_connection_type_idx` confirmado (`UNIQUE`, `WHERE (status = ANY (ARRAY['PENDING'::text, 'CLAIMED'::text]))`); constraint antiga `notification_jobs_active_per_connection_type_key` confirmada **ausente** (0 linhas).
- **Consulta 23 [nova, Correção 1]:** 0 linhas de `callback_receipts` contendo as chaves `raw_edit_token`/`raw_regeneration_token`/`raw_action_token`/`raw_claim_token`; 0 linhas onde `result::text` contém qualquer sequência hex de 48 ou 64 caracteres (os dois comprimentos de token usados na jornada) — verificação de **conteúdo** do JSONB, não apenas de nome de coluna.

## 6. Resultado de `009_smoke_tests.sql` (41 itens — 36 herdados da v1.5.0 + 5 novos)

Execução completa dentro de `BEGIN...ROLLBACK` (nunca `COMMIT`). **Resultado: 41 de 41 itens OK. Zero falhas. Exit code 0.**

Os 36 itens herdados da v1.5.0 continuam passando sem regressão. Os 5 itens novos:

- **[22b]:** depois de `approve_message(EDITAR)`, `raw_edit_token` não aparece em `callback_receipts.result` — nem como chave, nem como valor de texto em qualquer lugar do JSON.
- **[22c]:** retry do mesmo `callback_query_id` de EDITAR não duplica `approvals`/`connection_status_history`, e devolve um `raw_edit_token` **novo e diferente** do primeiro, usado com sucesso em seguida por `save_message_edit`.
- **[23b]:** mesma prova de ausência de vazamento para `raw_regeneration_token` no fluxo REFAZER.
- **[23c]:** retry do mesmo `callback_query_id` de REFAZER não duplica nada, e devolve um `raw_regeneration_token` novo e utilizável por `save_regenerated_message`.
- **[24b]:** ciclo completo apresentar → entregar → editar → apresentar de novo → entregar de novo produz **2 linhas `DELIVERED`** para a mesma `connection_id`+`job_type='APPROVAL'`, sem violar nenhuma constraint (a constraint antiga bloquearia isso).

**Nenhum dado ficou persistido** após o `ROLLBACK` — confirmado por contagem direta em todas as tabelas afetadas (`connections`, `action_tokens`, `callback_receipts`, `notification_jobs`, `followups`, `workflow_errors`, todas com `count=0`).

## 7. Testes de concorrência real (herdados da v1.5.0, sem regressão)

Reexecutados com sucesso depois da correção: `record_workflow_error` concorrente (retry_count 0 depois 1, nunca duplicado) e `claim_notification_jobs` concorrente (conjuntos de claim disjuntos). Ver `010_concurrency_tests.md` para o detalhe.

## 8. Testes de retry atrasado real (novo, Correção 3)

**Scripts:** `tests/delayed_retry_mark_message_sent.sql`, `tests/delayed_retry_complete_followup.sql`, orquestrados por `tests/run_delayed_retry_tests.sh`. Cada um roda em modo autocommit (sem `BEGIN` explícito), faz a primeira chamada com uma data poucos segundos no futuro, **commita de verdade**, espera com `pg_sleep(4)` a data passar de verdade, e faz o retry com o mesmo `callback_query_id` e o mesmo valor literal de data.

**Teste `mark_message_sent`:** primeira chamada `MARCAR_ENVIADA` com `p_first_followup_at` = +3s; após o sleep, `data_ja_passou = t` (confirmado por consulta real); retry devolveu exatamente o mesmo `delivery_event_id`/`connection_id`/`new_status`/`followup_id`; `delivery_events` com `event_type='MARCADO_COMO_ENVIADO'` = 1 (não duplicado); `followups` = 1 (não duplicado). **OK.**

**Teste `complete_followup`:** primeira chamada `SEM_RESPOSTA` com `p_next_followup_at` = +3s; após o sleep, `data_ja_passou = t`; retry devolveu exatamente o mesmo `followup_id`/`new_connection_status`/`next_followup_id`/`next_followup_sequence`; `followups` para a conexão = 2 (sequence=1 encerrado + sequence=2 criado uma única vez, não triplicado pelo retry). **OK.**

Ambos os testes limparam os próprios dados ao final (`DELETE` explícito — usam `COMMIT` real, não `ROLLBACK`, para que o `pg_sleep` realmente separe duas transações). Confirmado por consulta direta: 0 linhas residuais com prefixo `delayedtest-*` ao final da rodada.

## 9. Rollback e reaplicação

- `rollback/001_rollback.sql` executado com `ON_ERROR_STOP=1`, exit code 0.
- Confirmado por consulta direta: **0 tabelas** restantes no schema `rufino_linkedin`; schema removido; **0 roles** restantes; **`pgcrypto` 1.3 preservada**.
- Migration reaplicada do zero (`001`–`007`, todos exit code 0).
- `008_validation_queries.sql`, `009_smoke_tests.sql`, `run_concurrency_tests.sh` e `run_delayed_retry_tests.sh` reexecutados após a reaplicação: **mesmos resultados** (23/23 consultas corretas; 41/41 smoke tests OK; ambos os testes de concorrência OK; ambos os testes de retry atrasado OK).

## 10. Ausências confirmadas

- **0 tokens brutos em `callback_receipts.result`** — verificado por conteúdo (não só nome de coluna), consulta 23 de `008_validation_queries.sql` e itens [22b]/[23b] de `009_smoke_tests.sql`.
- **Múltiplos jobs `DELIVERED` históricos permitidos** — item [24b], 2 linhas confirmadas sem violação de constraint.
- **Apenas um job ativo `PENDING`/`CLAIMED` por conexão/tipo** — garantido pelo índice parcial `notification_jobs_one_active_per_connection_type_idx` (consulta 22).
- **Retry atrasado de `mark_message_sent` funciona** — Seção 8, Teste 1.
- **Retry atrasado de `complete_followup` funciona** — Seção 8, Teste 2.
- **0 funções executáveis por `PUBLIC`** — consulta 4 e itens `[PRE]`/`[33]` de `009_smoke_tests.sql`, reconfirmado após a reaplicação.
- **Aplicação sem escrita direta** — item [30].
- **Aplicação sem acesso a `extensions`** — item [32].
- **Rollback atualizado** — cobre as tabelas/funções novas desde a v1.5.0; nenhuma mudança estrutural nova nesta rodada exigiu ajuste em `rollback/001_rollback.sql` (Correção 2 trocou apenas um índice, removido junto com a tabela; nenhuma tabela/função nova foi criada nesta rodada).
- **Assinaturas públicas inalteradas** — Seção 2 acima.
- **`N8N-INTEGRATION.md` continua compatível** — só recebeu esclarecimentos de comportamento de retry, sem mudança de contrato.

## 11. Riscos residuais reais

1. **Testes rodaram em PostgreSQL 16.13, não 17.10** (mesmo risco já registrado desde a v1.5.0) — recomenda-se reexecutar `008`/`009`/`run_concurrency_tests.sh`/`run_delayed_retry_tests.sh` contra PostgreSQL 17 real antes da aplicação efetiva em DEV.
2. **Retomada manual de `ERRO` continua administrativa** — sem mudança nesta rodada.
3. **Telegram não é exactly-once** — sem mudança nesta rodada (outbox garante durabilidade, não exactly-once de envio).
4. **Ambiente PROD** ainda não tem pasta própria — sem mudança nesta rodada.
5. **GATE 4 não iniciado** — por desenho explícito desta rodada.

## 12. Confirmação de escopo

- **EasyPanel:** nenhuma alteração.
- **n8n:** nenhum workflow criado, editado, importado ou executado.
- **Banco real `rufino-linkedin-dev` (EasyPanel):** nenhum SQL executado contra ele — todos os comandos rodaram contra um PostgreSQL local, descartável, sem qualquer conectividade com o EasyPanel.
- **Credenciais/senhas:** nenhuma credencial ou senha real usada, gerada ou persistida.
- **Tokens brutos:** nenhum persistido em nenhuma tabela — inclusive corrigido nesta rodada (Correção 1).
- **Escopo desta rodada:** limitado aos 3 defeitos descritos; nenhuma refatoração estética, nenhum novo workflow, nenhuma mudança de assinatura pública.

## 13. Conclusão

**GO PARA APLICAÇÃO CONTROLADA EM DEV**, com a mesma condição já registrada desde a v1.5.0: reexecutar `008_validation_queries.sql`, `009_smoke_tests.sql`, `tests/run_concurrency_tests.sh` e `tests/run_delayed_retry_tests.sh` contra PostgreSQL 17 real (ou clone descartável de DEV) antes da aplicação efetiva contra `rufino-linkedin-dev`. Dentro dessa condição: os 3 defeitos confirmados estão corrigidos e comprovados por execução real (não apenas revisão estática) — ausência de token bruto em JSONB, outbox aceitando entregas históricas múltiplas, e retry atrasado real idempotente — sem alterar nenhuma assinatura pública congelada em `N8N-INTEGRATION.md` e sem regressão em nenhum dos 36 itens de smoke test nem nos 2 testes de concorrência herdados da v1.5.0.
