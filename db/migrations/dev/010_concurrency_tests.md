# 010_concurrency_tests.md — Testes de concorrência real e retry atrasado real (v1.5.0/v1.5.1)

Este documento e os scripts em `tests/` **não fazem parte da migration de produção** (001–009) — existem para provar, com concorrência genuína entre duas conexões PostgreSQL reais e com passagem real de tempo de parede (nenhuma das duas coisas é simulável dentro de uma única transação), os invariantes que `009_smoke_tests.sql` não consegue exercitar sozinho (uma única sessão, uma única transação, `now()` estável do início ao fim, nunca duas transações reais correndo ao mesmo tempo, nunca um `COMMIT` real entre duas chamadas).

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

## Teste 3 — Retry atrasado real de `mark_message_sent`/`complete_followup` (v1.5.1, Correção 3)

**Scripts:** `tests/delayed_retry_mark_message_sent.sql`, `tests/delayed_retry_complete_followup.sql`, orquestrados por `tests/run_delayed_retry_tests.sh`.

**Por que isso também não cabe em `009_smoke_tests.sql`:** o bug corrigido nesta rodada era `mark_message_sent`/`complete_followup` validando `p_first_followup_at`/`p_next_followup_at` como data futura **antes** de checar `callback_receipts` — um retry legítimo (reentrega do Telegram, por exemplo) que chegasse depois que a data agendada já tivesse passado de verdade era rejeitado por engano, mesmo sendo um callback já processado com sucesso. Provar isso exige que a data realmente passe entre a primeira chamada e o retry — e `now()` não muda dentro de uma transação só, então isso é inexercitável em `009_smoke_tests.sql` (`BEGIN...ROLLBACK`, uma transação, do início ao fim). Cada script roda em modo autocommit (sem `BEGIN` explícito): monta a conexão até o ponto certo, faz a primeira chamada com uma data poucos segundos no futuro, **commita de verdade**, espera com `pg_sleep` até a data passar de verdade, e só então faz o retry com o **mesmo** `callback_query_id` e o **mesmo** valor literal de data (nunca recalculado — um valor recalculado teria um fingerprint diferente e seria tratado, corretamente, como conflito, não como retry).

**O que prova:** o retry, mesmo com a data já no passado, devolve exatamente o mesmo resultado da primeira chamada (mesmo `delivery_event_id`/`followup_id`/status, ou mesmo `next_followup_id`/sequência) e não duplica nenhuma linha em `delivery_events`/`followups`. Cada script se autovalida (bloco `DO $verify$ ... RAISE EXCEPTION` em caso de divergência) e limpa os próprios dados ao final — como usam `COMMIT` real (não `ROLLBACK`), a limpeza é `DELETE` explícito, mesma disciplina do Teste 1/2 acima.

**Resultado real desta rodada:** ambos os retries devolveram resultado idêntico ao da primeira chamada, sem duplicar nada. Ver `TEST-REPORT-v1.5.1.md` para o log completo.

## Como rodar

```bash
cd db/migrations/dev
PGDATABASE=rufino-linkedin-dev bash tests/run_concurrency_tests.sh
PGDATABASE=rufino-linkedin-dev bash tests/run_delayed_retry_tests.sh
```

O script orquestrador `tests/run_concurrency_tests.sh`:
1. Roda o Teste 1 (duas sessões `psql` em background, sincronizadas por `pg_sleep`), depois confirma via consulta direta que os dois `retry_count` gravados são distintos e sequenciais.
2. Roda o Teste 2 (setup + duas sessões `psql` verdadeiramente concorrentes via `&`/`wait`), depois confirma que os conjuntos de UUIDs reivindicados por cada sessão não se sobrepõem.
3. Limpa os dados de teste ao final (`DELETE` explícito — estes dois testes usam `COMMIT`, não `ROLLBACK`, porque a prova de serialização exige transações que realmente terminem para uma liberar o lock para a outra; por isso a limpeza é manual e explícita, não automática como em `009_smoke_tests.sql`).

O script orquestrador `tests/run_delayed_retry_tests.sh` roda o Teste 3 (os dois scripts de retry atrasado, um de cada vez — não há concorrência aqui, só passagem real de tempo, então não há necessidade de rodá-los em paralelo).

**Pré-requisito:** a migration 001–007 já aplicada no banco de destino (o mesmo banco descartável usado para `009_smoke_tests.sql`).

## Reclaim sob concorrência real (nota)

Os cenários de reclaim (follow-up abandonado, notification job com claim expirado, rejeição do worker antigo) já são cobertos deterministicamente em `009_smoke_tests.sql` (itens 19 e 21) simulando o timeout via `UPDATE ... SET claim_expires_at = now() - interval '1 minute'` como uma sessão administrativa — isso é suficiente para provar a lógica de rotação de token e rejeição do worker antigo, porque o mecanismo de reclaim não depende de concorrência real para funcionar (depende só de `claim_expires_at` já ter passado, o que uma única sessão consegue forçar deterministicamente). A concorrência real só é indispensável para os dois testes acima, onde o comportamento correto depende de duas transações genuinamente simultâneas disputando o mesmo lock/linha.
