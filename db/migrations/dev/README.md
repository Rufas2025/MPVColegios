# db/migrations/dev — Rufino LinkedIn Intelligence (GATE 3, banco DEV)

Migration versionada do banco operacional da jornada Rufino LinkedIn Intelligence, ambiente **DEV**. Gerada para revisão humana — **nenhum arquivo desta pasta foi executado**. Ver `MANUAL-STEPS.md` para os passos que dependem de uma ação manual (senha real, cadastro de credencial no n8n).

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
| 2 | `002_roles_and_schema.sql` | Cria o schema `rufino_linkedin`, a role owner `n8n_rufino_linkedin_owner_dev` (NOLOGIN) e a role de aplicação `n8n_rufino_linkedin_dev` (sem senha). |
| 3 | `003_tables.sql` | Cria as 8 tabelas (colunas, PK, NOT NULL). |
| 4 | `004_constraints_and_indexes.sql` | Adiciona FKs, UNIQUE, CHECK e índices das 8 tabelas. |
| 5 | `005_rls_and_grants.sql` | Habilita e força RLS nas 8 tabelas, cria as policies `SELECT USING (true)` restritas por role, e concede `SELECT`-only à role de aplicação. |
| 6 | `006_functions.sql` | Cria as 9 funções `SECURITY DEFINER` (owner, `search_path` fixo, referências qualificadas, `extensions.digest`/`extensions.gen_random_bytes`). |
| 7 | `007_function_permissions.sql` | `REVOKE EXECUTE FROM PUBLIC` e `GRANT EXECUTE` só para a role de aplicação, nas 9 funções. |
| — | `008_validation_queries.sql` | Somente leitura — 10 consultas para conferir o resultado depois de aplicar 001–007. Não é uma etapa de migration, é um roteiro de conferência manual. |
| — | `rollback/001_rollback.sql` | Reverte 002–007, na ordem inversa. Nunca remove `pgcrypto`. Ver alerta de operação destrutiva no próprio arquivo. |
| — | `MANUAL-STEPS.md` | Passos que dependem de segredo real (senha da role de aplicação, cadastro de credencial no n8n) — nunca automatizados nem versionados. |

Entre os passos 2 e 3 (ou a qualquer momento antes de considerar a migration "concluída"), seguir `MANUAL-STEPS.md` para a senha real e o cadastro da credencial no n8n.

## Modelo canônico

**8 tabelas** (schema `rufino_linkedin`): `connections`, `analyses`, `message_versions`, `approvals`, `delivery_events`, `followups`, `workflow_errors`, `connection_status_history`.

**9 funções `SECURITY DEFINER`** (schema `rufino_linkedin`): `register_connection`, `transition_connection_status`, `present_message_for_delivery`, `claim_due_connections`, `approve_message`, `save_message_edit`, `mark_message_sent`, `claim_due_followups`, `record_workflow_error`.

Detalhe completo de colunas, transições e corpo das funções: ver a skill `rufino-linkedin-n8n-ops`, arquivos `references/data-model.md` e `references/postgres-functions.md`.

## Regras de segurança aplicadas

- Schema privado `rufino_linkedin`, sem `USAGE` para `PUBLIC`.
- Objetos sempre referenciados de forma totalmente qualificada (`rufino_linkedin.connections`, `extensions.digest`, `extensions.gen_random_bytes`).
- `action_token`/`edit_token` brutos nunca persistidos — só hash SHA-256, com expiração e invalidação de uso único.
- `callback_query_id` `UNIQUE` para deduplicação, além da validação de hash do token.
- Todas as 9 funções: `SECURITY DEFINER`, owner `NOLOGIN`, `search_path` endurecido (`rufino_linkedin, extensions, pg_temp`), `REVOKE EXECUTE FROM PUBLIC`, sem SQL dinâmico.
- Role owner (`n8n_rufino_linkedin_owner_dev`): `NOLOGIN`.
- Role de aplicação (`n8n_rufino_linkedin_dev`): sem `SUPERUSER`, `BYPASSRLS`, `CREATEDB`, `CREATEROLE` ou `REPLICATION`; recebe `EXECUTE` nas 9 funções e `SELECT` nas 8 tabelas — nenhuma escrita direta.
- Nenhuma senha real em nenhum arquivo desta pasta, desta skill ou deste repositório.
- Nenhuma referência a `service_role`, Supavisor, Data API ou *Exposed schemas* — conceitos específicos do Supabase, que não é mais a implementação de referência.
- DEV e PROD permanecem separados — esta pasta é exclusivamente `dev/`; uma futura pasta `prod/` replica o mesmo conteúdo revisado, nunca reescrito, contra um serviço de banco distinto.

## Concorrência e consistência

- `lock_version` em `connections` para concorrência otimista, verificado em `transition_connection_status`.
- `FOR UPDATE SKIP LOCKED` em `claim_due_connections` e `claim_due_followups` — duas execuções concorrentes do scheduler nunca reivindicam o mesmo registro.
- Funções transacionais e atômicas — qualquer exceção reverte integralmente os efeitos daquela chamada.
- `UNIQUE` em `idempotency_key` (`connections`) e em `callback_query_id` (`approvals`, `delivery_events`).
- `connection_status_history` é append-only — sem `updated_at`, escrita exclusiva por `transition_connection_status`.
- Nenhuma escrita operacional direta nas tabelas pela role do n8n — só via função.
- Nenhuma exclusão de registro de auditoria no caminho operacional normal (sem `DELETE` concedido a nenhuma role de aplicação).

## Status

Migration **gerada nesta rodada, para revisão humana — não aplicada**. GATE 3 (desenho) permanece a base; esta pasta é o artefato de saída do GATE 3 estendido para geração de SQL, ainda pendente de: (1) revisão humana linha a linha, (2) ação manual de `MANUAL-STEPS.md`, (3) confirmação explícita de Anderson para aplicar em DEV. Nenhum SQL foi executado como parte desta entrega.
