# 010_concurrency_tests.md — Testes de concorrência real (v1.5.0)

Este documento e os scripts em `tests/` **não fazem parte da migration de produção** (001–009) — existem para provar, com concorrência genuína entre duas conexões PostgreSQL reais (não simulada dentro de uma única sessão), os invariantes de concorrência que `009_smoke_tests.sql` não consegue exercitar sozinho (uma única sessão, uma única transação, nunca duas transações reais correndo ao mesmo tempo).

Rodam contra um banco descartável — **nunca contra o banco real `rufino-linkedin-dev`**. São entregues no ZIP desta migration para auditoria e reexecução independente, não para aplicação em DEV/PROD.

## Por que isso não cabe em `009_smoke_tests.sql`

`009_smoke_tests.sql` roda inteiro dentro de `BEGIN...ROLLBACK`, uma única transação. Isso é exatamente o que garante que nenhum dado de teste persista — mas também significa que ele não pode provar nada que dependa de **duas transações reais correndo ao mesmo tempo** (ex.: `pg_advisory_xact_lock` de uma sessão bloqueando outra sessão de verdade, ou duas chamadas de `claim_notification_jobs` disputando as mesmas linhas via `FOR UPDATE SKIP LOCKED` a partir de conexões separadas). Os cenários abaixo exigem processos `psql` distintos, cada um com sua própria conexão e transação.

## Teste 1 — `record_workflow_error` concorrente (Correção 8)

**Scripts:** `tests/concurrency_record_workflow_error_session_a.sql`, `tests/concurrency_record_workflow_error_session_b.sql`.

**O que prova:** duas sessões chamando `record_workflow_error` para a **mesma chave lógica** (`connection_id IS NULL`, `source_workflow='WF-CONCURRENCY-TEST'`, `error_type='erro_concorrente_v150'`) — mas `execution_id` diferente em cada uma — nunca recebem o mesmo `retry_count`. A Sessão A abre transação, insere (`retry_count=0`), segura a transação aberta por 3 segundos (`pg_sleep(3)`) e só então commita. A Sessão B começa ~1 segundo depois: ao chamar `record_workflow_error`, ela **bloqueia** em `pg_advisory_xact_lock` até a Sessão A commitar, e só então calcula seu próprio `retry_count` — que sai `1`, nunca `0` de novo.

**Resultado real desta rodada** (ver `TEST-REPORT.md` para o log completo): Sessão A → `retry_count=0`; Sessão B → `retry_count=1`. Serialização confirmada — sem o `pg_advisory_xact_lock`, existiria uma janela real em que as duas poderiam ler `count(*)=0` e ambas gravarem `retry_count=0`.

## Teste 2 — Duas sessões reivindicando `notification_jobs` simultaneamente (Correção 5)

**Scripts:** `tests/concurrency_claim_notification_jobs_setup.sql` (cria 2 conexões de teste, cada uma já com um job `APPROVAL` `PENDING`), `tests/concurrency_claim_notification_jobs_session.sql` (rodado duas vezes ao mesmo tempo, cada instância tentando `claim_notification_jobs(2)`).

**O que prova:** as duas sessões nunca reivindicam o mesmo `notification_job_id` — `FOR UPDATE SKIP LOCKED` garante exclusão mútua real entre conexões distintas, não só dentro de uma transação. Uma das duas sessões pode legitimamente reivindicar os dois jobs (se a outra ainda não tinha começado a travar linhas no momento em que a primeira já commitou) — o que importa é que a **interseção dos conjuntos reivindicados por cada sessão é sempre vazia**.

**Resultado real desta rodada**: Sessão 1 reivindicou 0 jobs; Sessão 2 reivindicou os 2 jobs de teste — conjuntos disjuntos, nenhuma duplicação. Ver `TEST-REPORT.md`.

## Como rodar

```bash
cd db/migrations/dev
PGDATABASE=rufino-linkedin-dev bash tests/run_concurrency_tests.sh
```

O script orquestrador (`tests/run_concurrency_tests.sh`):
1. Roda o Teste 1 (duas sessões `psql` em background, sincronizadas por `pg_sleep`), depois confirma via consulta direta que os dois `retry_count` gravados são distintos e sequenciais.
2. Roda o Teste 2 (setup + duas sessões `psql` verdadeiramente concorrentes via `&`/`wait`), depois confirma que os conjuntos de UUIDs reivindicados por cada sessão não se sobrepõem.
3. Limpa os dados de teste ao final (`DELETE` explícito — estes dois testes usam `COMMIT`, não `ROLLBACK`, porque a prova de serialização exige transações que realmente terminem para uma liberar o lock para a outra; por isso a limpeza é manual e explícita, não automática como em `009_smoke_tests.sql`).

**Pré-requisito:** a migration 001–006 já aplicada no banco de destino (o mesmo banco descartável usado para `009_smoke_tests.sql`).

## Reclaim sob concorrência real (nota)

Os cenários de reclaim (follow-up abandonado, notification job com claim expirado, rejeição do worker antigo) já são cobertos deterministicamente em `009_smoke_tests.sql` (itens 19 e 21) simulando o timeout via `UPDATE ... SET claim_expires_at = now() - interval '1 minute'` como uma sessão administrativa — isso é suficiente para provar a lógica de rotação de token e rejeição do worker antigo, porque o mecanismo de reclaim não depende de concorrência real para funcionar (depende só de `claim_expires_at` já ter passado, o que uma única sessão consegue forçar deterministicamente). A concorrência real só é indispensável para os dois testes acima, onde o comportamento correto depende de duas transações genuinamente simultâneas disputando o mesmo lock/linha.
