# db/migrations/dev — Rufino LinkedIn Intelligence (GATE 3, banco DEV)

Migration versionada do banco operacional da jornada Rufino LinkedIn Intelligence, ambiente **DEV**. Gerada para revisão humana — **nenhum arquivo desta pasta foi executado**. Ver `MANUAL-STEPS.md` para os passos que dependem de uma ação manual (senha real, cadastro de credencial no n8n).

**v1.4.2 — versão final candidata do GATE 3.** Esta versão resolve, numa única rodada, os bloqueios funcionais que sobravam depois da v1.4.1: dois estados sem saída na máquina de estados (`REFAZER` não tinha como voltar para aprovação; `FOLLOWUP_PENDENTE` não conseguia fechar um ciclo completo de resposta/sem-resposta/reagendamento), duas novas funções `SECURITY DEFINER` (`save_regenerated_message`, `complete_followup`), reforço de idempotência e concorrência, validação estrita de roles pré-existentes (sem correção silenciosa de privilégio divergente), e troca da orientação de senha manual de `ALTER ROLE ... PASSWORD` (texto puro, arrisca vazar em log/histórico) para `\password` (entrada oculta no `psql`). Ver `CHANGELOG.md` da skill `rufino-linkedin-n8n-ops` (v1.4.2) para o relatório completo, item a item.

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

Todos os arquivos `001`–`009` devem ser aplicados com `psql -v ON_ERROR_STOP=1 -f <arquivo>` — sem essa flag, um erro no meio de um arquivo não interrompe o `psql`, que segue tentando executar os comandos seguintes dentro de uma transação já abortada.

## Ordem de aplicação

Os arquivos são numerados e devem ser aplicados **em ordem, um de cada vez**, cada um revisado antes do próximo:

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `001_preflight.sql` | Valida versão do PostgreSQL, banco atual, pgcrypto instalada e no schema `extensions`. Aborta com erro claro se algo divergir. Só leitura — não cria nada. |
| 2 | `002_roles_and_schema.sql` | Dentro de `BEGIN...COMMIT`: cria o schema `rufino_linkedin`, a role owner `n8n_rufino_linkedin_owner_dev` (NOLOGIN) e a role de aplicação `n8n_rufino_linkedin_dev` (sem senha); concede à owner `USAGE` no schema `extensions` e `EXECUTE` em `extensions.digest`/`extensions.gen_random_bytes`. **[v1.4.2]** Se qualquer uma das duas roles já existir, **valida** seus atributos (`rolcanlogin`, `rolsuper`, `rolbypassrls`, `rolcreatedb`, `rolcreaterole`, `rolreplication`) contra o esperado e **aborta com mensagem clara** em vez de corrigir silenciosamente um privilégio divergente perigoso; também valida que a role de aplicação não é membro da role owner. |
| 3 | `003_tables.sql` | Dentro de `BEGIN...COMMIT`: cria as 8 tabelas (colunas, PK, NOT NULL). **[v1.4.2]** `connections` ganha `pending_regeneration_token_hash`/`pending_regeneration_token_expires_at`; `followups` ganha `callback_query_id`. |
| 4 | `004_constraints_and_indexes.sql` | Dentro de `BEGIN...COMMIT`: adiciona FKs, UNIQUE, CHECK e índices das 8 tabelas. **[v1.4.2]** Novos índices parciais para os tokens de regeneração e de edição; `UNIQUE` em `followups.callback_query_id`; índice de `followups.scheduled_for` corrigido para considerar `executed_at IS NULL` (não mais `claimed_at IS NULL`); índice novo em `workflow_errors` por `execution_id`. |
| 5 | `005_rls_and_grants.sql` | Dentro de `BEGIN...COMMIT`: habilita RLS nas 8 tabelas (**sem `FORCE`**), cria as policies `SELECT USING (true)` restritas por role, e concede `SELECT`-only à role de aplicação. |
| 6 | `006_functions.sql` | Dentro de um único `BEGIN...COMMIT`: cria as **11 funções** `SECURITY DEFINER` **e já aplica `REVOKE EXECUTE FROM PUBLIC` + `GRANT EXECUTE` autorizado na mesma transação** (sem janela entre criar e trancar). 10 funções recebem `EXECUTE` para a role de aplicação; `transition_connection_status` é interna (só `REVOKE FROM PUBLIC`, sem `GRANT` para a role de aplicação). **[v1.4.2]** Duas funções novas: `save_regenerated_message` (consome o token de regeneração emitido por `approve_message`/REFAZER e grava a nova versão gerada pelo GPT) e `complete_followup` (fecha um follow-up com RESPONDEU ou SEM_RESPOSTA, criando o próximo follow-up quando aplicável). `approve_message`, `mark_message_sent` e `record_workflow_error` tiveram assinatura/retorno ampliados — ver `references/postgres-functions.md` da skill para o detalhe função a função. |
| 7 | `007_function_permissions.sql` | Stub documental, sem SQL executável — o conteúdo de permissões foi movido para dentro de 006 (ver acima). Mantido só para preservar a numeração. |
| 8 | `008_validation_queries.sql` | Somente leitura — **19 consultas** para conferir o resultado depois de aplicar 001–007. **[v1.4.2]** 6 novas: existência/tipo das 3 colunas novas, constraint `UNIQUE` de `callback_query_id`, ausência de qualquer coluna de token bruto, verificação estrutural de que nenhum status não-terminal ficou sem transição de saída (espelha a lista de arestas real de `006_functions.sql`), divergência de atributos de role, e não-associação da role de aplicação à owner. Não é uma etapa de migration, é um roteiro de conferência manual. |
| 9 | `009_smoke_tests.sql` | Dentro de `BEGIN...ROLLBACK` (nunca commita) — prova, como a role de aplicação real (`SET LOCAL ROLE`), os 30 itens do fluxo completo: registro idempotente, claim, aprovação, edição, REFAZER + regeneração (token de uso único, expiração, validação cruzada de conexão/versão), envio com criação do primeiro follow-up (sem duplicar em retry), claim de follow-ups, conclusão RESPONDEU/SEM_RESPOSTA com e sem próximo follow-up, callback duplicado, claim abandonado recuperável, followup executado nunca reivindicado de novo, preservação de auditoria em `record_workflow_error`, ausência total de escrita direta e de chamada direta a `transition_connection_status`, e nenhuma função exposta a `PUBLIC`. Não deixa dado nenhum ao final. |
| — | `rollback/001_rollback.sql` | Reverte 002–007, na ordem inversa. **[v1.4.2]** Inclui o `DROP FUNCTION` das 2 funções novas e a assinatura atualizada de `mark_message_sent`. Nunca remove `pgcrypto`. Ver alerta de operação destrutiva no próprio arquivo. |
| — | `MANUAL-STEPS.md` | Passos que dependem de segredo real (senha da role de aplicação via `\password`, cadastro de credencial no n8n), o procedimento de retomada manual de `ERRO`, e o que fazer se uma role já existir com atributos divergentes — nunca automatizados nem versionados. |

Entre os passos 2 e 3 (ou a qualquer momento antes de considerar a migration "concluída"), seguir `MANUAL-STEPS.md` para a senha real e o cadastro da credencial no n8n. **Depois de aplicar 001–008, rode `009_smoke_tests.sql` antes de considerar a migration pronta para uso real** — ele roda e desfaz sozinho (`ROLLBACK`), então pode ser executado quantas vezes for útil.

## Modelo canônico

**8 tabelas** (schema `rufino_linkedin`): `connections`, `analyses`, `message_versions`, `approvals`, `delivery_events`, `followups`, `workflow_errors`, `connection_status_history`.

**11 funções `SECURITY DEFINER`** (schema `rufino_linkedin`): `register_connection`, `transition_connection_status` (**interna**), `present_message_for_delivery`, `claim_due_connections`, `approve_message`, `save_message_edit`, `save_regenerated_message` **[novo, v1.4.2]**, `mark_message_sent`, `claim_due_followups`, `complete_followup` **[novo, v1.4.2]**, `record_workflow_error`. **10 são executáveis pela role de aplicação; 1 (`transition_connection_status`) só é chamável pela role owner e pelas outras 10 funções (que rodam como a owner) — nunca diretamente pelo n8n.**

A contagem é derivada diretamente das `CREATE FUNCTION`/`REVOKE`/`GRANT` reais em `006_functions.sql` — não é um número preservado de versões anteriores.

Detalhe completo de colunas, transições e corpo das funções: ver a skill `rufino-linkedin-n8n-ops`, arquivos `references/data-model.md` e `references/postgres-functions.md`.

## Regras de segurança aplicadas

- Schema privado `rufino_linkedin`, sem `USAGE` para `PUBLIC`.
- Objetos sempre referenciados de forma totalmente qualificada (`rufino_linkedin.connections`, `extensions.digest`, `extensions.gen_random_bytes`).
- `action_token`/`edit_token`/`regeneration_token` brutos nunca persistidos — só hash SHA-256, com expiração e invalidação de uso único.
- `callback_query_id` `UNIQUE` para deduplicação (em `approvals`, `delivery_events` e, desde a v1.4.2, também em `followups`), além da validação de hash do token.
- Todas as 11 funções: `SECURITY DEFINER`, owner `NOLOGIN`, `search_path` endurecido (`rufino_linkedin, extensions, pg_temp`), `REVOKE EXECUTE FROM PUBLIC`, sem SQL dinâmico. **10 delas também recebem `GRANT EXECUTE` para a role de aplicação; `transition_connection_status` fica só com o `REVOKE`, ou seja, é interna.**
- **RLS habilitado, mas NÃO forçado, nas 8 tabelas.** A owner (dona das tabelas, `NOLOGIN`, só grava através das funções) continua isenta de RLS por desenho — RLS continua valendo como defesa adicional para qualquer outra role. `FORCE ROW LEVEL SECURITY` nunca é usado.
- **Grants de `pgcrypto` explícitos:** a role owner recebe `USAGE` no schema `extensions` e `EXECUTE` em `extensions.digest(text,text)`/`extensions.gen_random_bytes(integer)` — a role de aplicação nunca recebe acesso a `extensions` (ela nunca chama essas funções diretamente, só via `SECURITY DEFINER`).
- Role owner (`n8n_rufino_linkedin_owner_dev`): `NOLOGIN`, `NOSUPERUSER`, `NOBYPASSRLS`, `NOCREATEDB`, `NOCREATEROLE`, `NOREPLICATION`.
- Role de aplicação (`n8n_rufino_linkedin_dev`): `LOGIN`, sem `SUPERUSER`, `BYPASSRLS`, `CREATEDB`, `CREATEROLE` ou `REPLICATION`, sem membership na owner; recebe `EXECUTE` em 10 das 11 funções e `SELECT` nas 8 tabelas — nenhuma escrita direta.
- **[v1.4.2] Roles pré-existentes nunca são corrigidas silenciosamente** — se `002_roles_and_schema.sql` encontrar qualquer uma das duas roles já criada com atributos divergentes do esperado, ou a role de aplicação já como membro da owner, ele aborta com uma mensagem explícita em vez de tentar consertar. A correção, quando necessário, é manual e deliberada (ver `MANUAL-STEPS.md`, seção 5).
- Nenhuma senha real em nenhum arquivo desta pasta, desta skill ou deste repositório. Nenhum placeholder de senha executável em nenhum arquivo `.sql` — a senha é aplicada inteiramente fora da migration, via `\password` (ver `MANUAL-STEPS.md`).
- Nenhuma referência a `service_role`, Supavisor, Data API ou *Exposed schemas* — conceitos específicos do Supabase, que não é mais a implementação de referência.
- DEV e PROD permanecem separados — esta pasta é exclusivamente `dev/`; uma futura pasta `prod/` replica o mesmo conteúdo revisado, nunca reescrito, contra um serviço de banco distinto.

## Atomicidade da migration

Os arquivos `002` a `006` rodam cada um dentro do seu próprio `BEGIN...COMMIT` — uma falha em qualquer instrução reverte o arquivo inteiro, nunca deixa objetos "meio criados". `006_functions.sql`, especificamente, cria as 11 funções **e** aplica `REVOKE`/`GRANT` de permissão na mesma transação, sem nenhuma janela em que uma função recém-criada fique com o `EXECUTE` padrão do Postgres a `PUBLIC` ainda valendo. `007_function_permissions.sql` é um stub documental por causa dessa disciplina — ver comentário no próprio arquivo.

## Fluxo de aprovação, edição e regeneração (Correção 1, v1.4.2)

- `approve_message` com `p_decision = 'REFAZER'` transita a conexão de `AGUARDANDO_APROVACAO` para `REFAZER`, gera um `regeneration_token` aleatório de 32 bytes (`extensions.gen_random_bytes`), persiste **só o hash SHA-256** (nunca o valor bruto) com expiração de 2 dias, e devolve o token bruto **uma única vez** no retorno da função — quem chama (WF-03) é responsável por entregá-lo ao GPT para a nova geração, nunca gravá-lo em lugar nenhum.
- `save_regenerated_message` (nova, v1.4.2) recebe esse token bruto de volta (via WF-03-REGEN), localiza e trava a conexão, valida hash/expiração/status (`REFAZER`)/uso único, invalida o token na mesma transação, rejeita mensagem vazia, insere a nova `message_versions` (`version = max+1`, `source = 'gpt'`), transita `REFAZER → AGUARDANDO_APROVACAO`, gera um novo `pending_action_token` (mesmo mecanismo de `transition_connection_status`) e devolve `connection_id`, `message_version_id`, `version`, o token bruto de aprovação e sua expiração.
- Antes da v1.4.2, `REFAZER` era um estado sem saída documentada no SQL — a única forma de sair dele exigiria uma função que não existia. Essa era uma das duas lacunas estruturais fechadas nesta versão (ver `references/statuses.md`).

## Fluxo de envio e follow-up completo (Correção 2, v1.4.2)

- `mark_message_sent` com `p_action = 'MARCAR_ENVIADA'` agora **exige** `p_first_followup_at` (data futura, vinda explicitamente do workflow — nunca inventada no banco), marca a mensagem como enviada, cria atomicamente o primeiro `followups` (`sequence = 1`, `ON CONFLICT (connection_id, sequence) DO NOTHING` — retry não duplica), e transita a conexão para `FOLLOWUP_PENDENTE`.
- `complete_followup` (nova, v1.4.2) fecha um follow-up reivindicado: com `p_resultado = 'RESPONDEU'`, transita `FOLLOWUP_PENDENTE → RESPONDEU → ENCERRADO` e nunca cria novo follow-up; com `p_resultado = 'SEM_RESPOSTA'` e `p_next_followup_at` preenchido (data futura), transita `FOLLOWUP_PENDENTE → SEM_RESPOSTA → FOLLOWUP_PENDENTE` e cria o próximo follow-up (`sequence + 1`); com `p_next_followup_at` nulo, transita `FOLLOWUP_PENDENTE → SEM_RESPOSTA → ENCERRADO`, fechando a jornada.
- Antes da v1.4.2, não havia nenhuma função para fechar um follow-up ou criar o próximo — `FOLLOWUP_PENDENTE` era o segundo estado sem saída documentada no SQL. Essa era a segunda lacuna estrutural fechada nesta versão.

## Auditoria de erro (Correção 4, v1.4.2)

`record_workflow_error` grava o registro em `workflow_errors` **antes** de tentar qualquer transição para `ERRO`, e a tentativa de transição roda dentro de um bloco `EXCEPTION WHEN OTHERS` isolado (savepoint implícito do PL/pgSQL) — se a transição falhar por qualquer motivo, o erro é capturado e reportado no retorno (`transitioned_to_erro = false`, `transition_error` com o `SQLERRM`), mas o `INSERT` em `workflow_errors` já commitado dentro da função nunca é desfeito. O retorno inclui `retry_count` (tentativas já registradas para a mesma conexão/workflow/tipo de erro), `retry_limit`, `retry_allowed` e `current_status` (relido do banco, nunca simplesmente aceito do parâmetro `p_previous_status`).

## Concorrência e consistência

- `lock_version` em `connections` para concorrência otimista, verificado em `transition_connection_status`.
- `FOR UPDATE SKIP LOCKED` em `claim_due_connections` e `claim_due_followups` — duas execuções concorrentes do scheduler nunca reivindicam o mesmo registro.
- `register_connection` usa `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING RETURNING` em vez de "SELECT para checar, depois INSERT" — a checagem e a gravação são atômicas, então duas chamadas concorrentes com a mesma `idempotency_key` nunca colidem com um erro de violação de `UNIQUE`; a que perder o conflito simplesmente recebe de volta o registro que já existia (sem duplicar `analyses`/`message_versions`/histórico).
- Funções transacionais e atômicas — qualquer exceção reverte integralmente os efeitos daquela chamada.
- `UNIQUE` em `idempotency_key` (`connections`), em `callback_query_id` (`approvals`, `delivery_events`, `followups` — v1.4.2) e em `(connection_id, sequence)` (`followups`).
- `connection_status_history` é append-only — sem `updated_at`, escrita exclusiva por `transition_connection_status`.
- Nenhuma escrita operacional direta nas tabelas pela role do n8n — só via função.
- Nenhuma exclusão de registro de auditoria no caminho operacional normal (sem `DELETE` concedido a nenhuma role de aplicação).
- **Claims abandonados:** `claim_due_followups` reivindica também followups cujo `claimed_at` é mais antigo que 1 hora e cujo `executed_at` continua nulo (worker que travou ou foi encerrado no meio do processamento); um followup já `executed_at` nunca volta a ser elegível para claim. `updated_at` é atualizado no momento do claim.
- **`complete_followup`** deduplica por `callback_query_id` globalmente antes de processar, além de rejeitar um followup cujo `executed_at` já esteja preenchido.

## Status

Migration **v1.4.2, versão final candidata do GATE 3, gerada para revisão humana — não aplicada**. GATE 3 (desenho) permanece a base; esta pasta é o artefato de saída do GATE 3 estendido para geração de SQL, ainda pendente de: (1) revisão humana linha a linha, (2) ação manual de `MANUAL-STEPS.md`, (3) execução de `009_smoke_tests.sql`, (4) confirmação explícita de Anderson para aplicar em DEV. Nenhum SQL foi executado como parte desta entrega.
