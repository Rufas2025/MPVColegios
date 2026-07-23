# db/migrations/dev — Rufino LinkedIn Intelligence (GATE 3, banco DEV)

Migration versionada do banco operacional da jornada Rufino LinkedIn Intelligence, ambiente **DEV**. Gerada para revisão humana — **nenhum arquivo desta pasta foi executado**. Ver `MANUAL-STEPS.md` para os passos que dependem de uma ação manual (senha real, cadastro de credencial no n8n).

**v1.4.1 — patch corretivo.** Esta versão corrige 9 problemas encontrados na revisão da v1.4.0 antes de qualquer aplicação real: um bug funcional que quebrava as próprias funções (`FORCE ROW LEVEL SECURITY`), uma janela de privilégio entre a criação das funções e o travamento de suas permissões, uma corrida de concorrência em `register_connection`, falta de mensagem inicial na conexão, falta de validação de integridade de `message_version_id`, uma função interna (`transition_connection_status`) exposta à role de aplicação sem necessidade, followups que podiam ficar presos para sempre se um worker travasse, e grants de `pgcrypto` que não existiam explicitamente. Ver `CHANGELOG.md` da skill `rufino-linkedin-n8n-ops` (v1.4.1) para o relatório completo, item a item.

## Infraestrutura alvo

- **Ambiente:** DEV.
- **EasyPanel:** projeto `rufino-linkedin-dev`, serviço n8n `n8n`, banco operacional `linkedin-db` (banco interno do n8n é um serviço separado, `n8n-db` — não é este).
- **PostgreSQL:** versão 17.10 (self-hosted no EasyPanel).
- **Banco:** `rufino-linkedin-dev`.
- **Schema operacional:** `rufino_linkedin` (privado, nunca `public`).
- **Extensão:** `pgcrypto` 1.3, instalada no schema `extensions` — confirmado por consulta real em `pg_extension` antes de qualquer SQL definitivo ser escrito.

Esta é a implementação de referência **PostgreSQL operacional self-hosted no EasyPanel** — Supabase deixou de ser a implementação de referência deste projeto (ver `CHANGELOG.md` da skill, v1.4.0). Não há aqui nenhum conceito de `service_role`, Supavisor, Data API ou *Exposed schemas* — esses eram específicos do Supabase e não se aplicam a este ambiente.

## Pré-requisito: quem aplica a migration

Os arquivos `001`–`007` (e o rollback) devem ser aplicados por uma **credencial administrativa** do serviço `linkedin-db` no EasyPanel (a role padrão do serviço, não `n8n_rufino_linkedin_dev`) — é essa credencial que tem permissão para `CREATE SCHEMA`, `CREATE ROLE`, `ALTER TABLE ... OWNER TO`, `CREATE POLICY` e `GRANT`/`REVOKE` sobre objetos de outra role. `n8n_rufino_linkedin_dev` (a role de aplicação) nunca aplica sua própria migration — ela só é usada depois, como credencial de runtime do n8n.

## Ordem de aplicação

Os arquivos são numerados e devem ser aplicados **em ordem, um de cada vez**, cada um revisado antes do próximo:

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `001_preflight.sql` | Valida versão do PostgreSQL, banco atual, pgcrypto instalada e no schema `extensions`. Aborta com erro claro se algo divergir. Só leitura — não cria nada. |
| 2 | `002_roles_and_schema.sql` | **[v1.4.1]** Dentro de `BEGIN...COMMIT`: cria o schema `rufino_linkedin`, a role owner `n8n_rufino_linkedin_owner_dev` (NOLOGIN) e a role de aplicação `n8n_rufino_linkedin_dev` (sem senha); concede à owner `USAGE` no schema `extensions` e `EXECUTE` em `extensions.digest`/`extensions.gen_random_bytes`. |
| 3 | `003_tables.sql` | **[v1.4.1]** Dentro de `BEGIN...COMMIT`: cria as 8 tabelas (colunas, PK, NOT NULL). |
| 4 | `004_constraints_and_indexes.sql` | **[v1.4.1]** Dentro de `BEGIN...COMMIT`: adiciona FKs, UNIQUE, CHECK e índices das 8 tabelas. |
| 5 | `005_rls_and_grants.sql` | **[v1.4.1]** Dentro de `BEGIN...COMMIT`: habilita RLS nas 8 tabelas (**sem `FORCE`** — corrigido nesta versão, ver "Regras de segurança" abaixo), cria as policies `SELECT USING (true)` restritas por role, e concede `SELECT`-only à role de aplicação. |
| 6 | `006_functions.sql` | **[v1.4.1]** Dentro de um único `BEGIN...COMMIT`: cria as 9 funções `SECURITY DEFINER` **e já aplica `REVOKE EXECUTE FROM PUBLIC` + `GRANT EXECUTE` autorizado na mesma transação** (sem janela entre criar e trancar). 8 funções recebem `EXECUTE` para a role de aplicação; `transition_connection_status` passa a ser interna (só `REVOKE FROM PUBLIC`, sem `GRANT` para a role de aplicação). |
| 7 | `007_function_permissions.sql` | **[v1.4.1] Stub documental, sem SQL executável** — o conteúdo de permissões foi movido para dentro de 006 (ver acima). Mantido só para preservar a numeração. |
| 8 | `008_validation_queries.sql` | Somente leitura — 13 consultas para conferir o resultado depois de aplicar 001–007 (3 novas na v1.4.1: grants de `pgcrypto` da owner, contagem de funções executáveis pela role de aplicação, followups com claim abandonado). Não é uma etapa de migration, é um roteiro de conferência manual. |
| 9 | `009_smoke_tests.sql` | **[novo, v1.4.1]** Dentro de `BEGIN...ROLLBACK` (nunca commita) — prova, como a role de aplicação real (`SET LOCAL ROLE`), que `register_connection` funciona e cria a mensagem inicial, que as funções `SECURITY DEFINER` acessam `pgcrypto` e as tabelas, que escrita direta é negada, e que a chamada direta de `transition_connection_status` é negada. Não deixa dado nenhum ao final. |
| — | `rollback/001_rollback.sql` | Reverte 002–007, na ordem inversa. Nunca remove `pgcrypto`. Ver alerta de operação destrutiva no próprio arquivo. |
| — | `MANUAL-STEPS.md` | Passos que dependem de segredo real (senha da role de aplicação, cadastro de credencial no n8n) e o procedimento de retomada manual de `ERRO` — nunca automatizados nem versionados. |

Entre os passos 2 e 3 (ou a qualquer momento antes de considerar a migration "concluída"), seguir `MANUAL-STEPS.md` para a senha real e o cadastro da credencial no n8n. **Depois de aplicar 001–008, rode `009_smoke_tests.sql` antes de considerar a migration pronta para uso real** — ele roda e desfaz sozinho (`ROLLBACK`), então pode ser executado quantas vezes for útil.

## Modelo canônico

**8 tabelas** (schema `rufino_linkedin`): `connections`, `analyses`, `message_versions`, `approvals`, `delivery_events`, `followups`, `workflow_errors`, `connection_status_history`.

**9 funções `SECURITY DEFINER`** (schema `rufino_linkedin`): `register_connection`, `transition_connection_status` (**interna** desde a v1.4.1 — ver abaixo), `present_message_for_delivery`, `claim_due_connections`, `approve_message`, `save_message_edit`, `mark_message_sent`, `claim_due_followups`, `record_workflow_error`. **8 são executáveis pela role de aplicação; 1 (`transition_connection_status`) só é chamável pela role owner e pelas outras 8 funções (que rodam como a owner) — nunca diretamente pelo n8n.**

Detalhe completo de colunas, transições e corpo das funções: ver a skill `rufino-linkedin-n8n-ops`, arquivos `references/data-model.md` e `references/postgres-functions.md`.

## Regras de segurança aplicadas

- Schema privado `rufino_linkedin`, sem `USAGE` para `PUBLIC`.
- Objetos sempre referenciados de forma totalmente qualificada (`rufino_linkedin.connections`, `extensions.digest`, `extensions.gen_random_bytes`).
- `action_token`/`edit_token` brutos nunca persistidos — só hash SHA-256, com expiração e invalidação de uso único.
- `callback_query_id` `UNIQUE` para deduplicação, além da validação de hash do token.
- Todas as 9 funções: `SECURITY DEFINER`, owner `NOLOGIN`, `search_path` endurecido (`rufino_linkedin, extensions, pg_temp`), `REVOKE EXECUTE FROM PUBLIC`, sem SQL dinâmico. **8 delas também recebem `GRANT EXECUTE` para a role de aplicação; `transition_connection_status` fica só com o `REVOKE`, ou seja, é interna (fix v1.4.1).**
- **RLS habilitado, mas NÃO forçado, nas 8 tabelas (corrigido na v1.4.1).** A v1.4.0 usava `FORCE ROW LEVEL SECURITY`, o que fazia a política valer até para a própria role owner — como não existe policy de `INSERT`/`UPDATE` para a owner (só `SELECT` para a role de aplicação), isso teria bloqueado as 9 funções de gravar assim que fossem chamadas de verdade. Sem `FORCE`, a owner (dona das tabelas, `NOLOGIN`, só grava através das funções) continua isenta de RLS por desenho — RLS continua valendo como defesa adicional para qualquer outra role.
- **Grants de `pgcrypto` explícitos (fix v1.4.1):** a role owner recebe `USAGE` no schema `extensions` e `EXECUTE` em `extensions.digest(text,text)`/`extensions.gen_random_bytes(integer)` — a role de aplicação nunca recebe acesso a `extensions` (ela nunca chama essas funções diretamente, só via `SECURITY DEFINER`).
- Role owner (`n8n_rufino_linkedin_owner_dev`): `NOLOGIN`.
- Role de aplicação (`n8n_rufino_linkedin_dev`): sem `SUPERUSER`, `BYPASSRLS`, `CREATEDB`, `CREATEROLE` ou `REPLICATION`; recebe `EXECUTE` em 8 das 9 funções e `SELECT` nas 8 tabelas — nenhuma escrita direta.
- Nenhuma senha real em nenhum arquivo desta pasta, desta skill ou deste repositório.
- Nenhuma referência a `service_role`, Supavisor, Data API ou *Exposed schemas* — conceitos específicos do Supabase, que não é mais a implementação de referência.
- DEV e PROD permanecem separados — esta pasta é exclusivamente `dev/`; uma futura pasta `prod/` replica o mesmo conteúdo revisado, nunca reescrito, contra um serviço de banco distinto.

## Atomicidade da migration (fix v1.4.1, item 5)

Os arquivos `002` a `006` rodam cada um dentro do seu próprio `BEGIN...COMMIT` — uma falha em qualquer instrução reverte o arquivo inteiro, nunca deixa objetos "meio criados". `006_functions.sql`, especificamente, cria as 9 funções **e** aplica `REVOKE`/`GRANT` de permissão na mesma transação, fechando a janela que existia na v1.4.0 entre a criação de uma função (com o `EXECUTE` padrão do Postgres a `PUBLIC` ainda valendo) e o arquivo separado que revogava isso depois. `007_function_permissions.sql` virou um stub documental por causa dessa mudança — ver comentário no próprio arquivo.

## Mensagem inicial e integridade de versão (fix v1.4.1, itens 3 e 7)

- `register_connection` agora exige `p_mensagem` (não pode ser nula ou vazia) e cria, na mesma transação, a `message_versions` de `version=1`, `source='gpt'` — toda conexão nasce com uma mensagem, não existe mais o intervalo em que uma conexão existe sem nenhuma versão de mensagem.
- `claim_due_connections` devolve também `message_version_id` e `message_body` da versão vigente, para o WF-02/WF-03 montarem a notificação de aprovação sem uma segunda consulta.
- `approve_message` e `mark_message_sent` agora exigem `p_message_version_id` não nulo, confirmam que ele pertence à conexão informada e que é a versão vigente — rejeitam versão de outra conexão e versão obsoleta (ex.: uma edição concorrente mudou a versão entre o botão ser mostrado e clicado).
- `present_message_for_delivery` grava `message_version_id` no `metadata` do evento `MENSAGEM_APRESENTADA`, mesma disciplina que `mark_message_sent` já aplicava.

## Concorrência e consistência

- `lock_version` em `connections` para concorrência otimista, verificado em `transition_connection_status`.
- `FOR UPDATE SKIP LOCKED` em `claim_due_connections` e `claim_due_followups` — duas execuções concorrentes do scheduler nunca reivindicam o mesmo registro.
- **Idempotência concorrente corrigida (fix v1.4.1, item 6):** `register_connection` usa `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING RETURNING` em vez do padrão anterior "SELECT para checar, depois INSERT" — a checagem e a gravação são atômicas, então duas chamadas concorrentes com a mesma `idempotency_key` nunca colidem com um erro de violação de `UNIQUE`; a que perder o conflito simplesmente recebe de volta o registro que já existia (sem duplicar `analyses`/`message_versions`/histórico).
- Funções transacionais e atômicas — qualquer exceção reverte integralmente os efeitos daquela chamada.
- `UNIQUE` em `idempotency_key` (`connections`) e em `callback_query_id` (`approvals`, `delivery_events`).
- `connection_status_history` é append-only — sem `updated_at`, escrita exclusiva por `transition_connection_status`.
- Nenhuma escrita operacional direta nas tabelas pela role do n8n — só via função.
- Nenhuma exclusão de registro de auditoria no caminho operacional normal (sem `DELETE` concedido a nenhuma role de aplicação).
- **Claims abandonados (fix v1.4.1, item 8):** `claim_due_followups` agora reivindica também followups cujo `claimed_at` é mais antigo que 1 hora e cujo `executed_at` continua nulo (worker que travou ou foi encerrado no meio do processamento) — antes, uma linha reivindicada e nunca concluída ficava presa para sempre. `updated_at` passa a ser atualizado no momento do claim (não era, na v1.4.0).

## Status

Migration **v1.4.1, patch corretivo sobre a v1.4.0, gerada para revisão humana — não aplicada**. GATE 3 (desenho) permanece a base; esta pasta é o artefato de saída do GATE 3 estendido para geração de SQL, ainda pendente de: (1) revisão humana linha a linha, (2) ação manual de `MANUAL-STEPS.md`, (3) execução de `009_smoke_tests.sql`, (4) confirmação explícita de Anderson para aplicar em DEV. Nenhum SQL foi executado como parte desta entrega.
