# Passos manuais — GATE 3 (banco DEV) — v1.5.0

Este documento cobre exatamente as ações que **não** estão em nenhum arquivo `.sql` desta pasta, porque não devem estar: envolvem um segredo real. Nenhum arquivo desta migration contém, ou deve conter, uma senha real — só nomes lógicos e placeholders.

Ambiente: EasyPanel, projeto **rufino-linkedin-dev**, serviço de banco **linkedin-db**, banco **rufino-linkedin-dev**, schema operacional **rufino_linkedin**.

## 1. Anderson gera uma senha forte fora do repositório

- Gere a senha com um gerenciador de senhas (1Password, Bitwarden, etc.) ou um comando local que não grave em nenhum arquivo versionado, ex.: `openssl rand -base64 32` executado no seu próprio terminal, **nunca** colado depois em um commit, issue, PR, mensagem de chat ou nesta skill.
- Requisitos mínimos: 32+ caracteres, gerada aleatoriamente (não uma frase memorizável reaproveitada de outro serviço).
- Guarde a senha **somente** no cofre de credenciais do n8n (passo 3) e, se quiser um backup, num gerenciador de senhas pessoal — nunca em texto plano em disco, e-mail, chat ou arquivo deste repositório.

## 2. Aplicar a senha manualmente na role de aplicação (fix v1.4.2, item 8)

Depois de rodar `002_roles_and_schema.sql` (que cria `n8n_rufino_linkedin_dev` **sem** senha), conecte-se ao banco `rufino-linkedin-dev` com uma credencial administrativa (a mesma usada para aplicar a migration) usando o cliente `psql` interativo, e rode:

```
\password n8n_rufino_linkedin_dev
```

Digite a senha gerada no passo 1 quando solicitado (duas vezes, para confirmação).

- **Por que `\password` e não `ALTER ROLE ... PASSWORD '<senha>'`:** o comando `\password` do `psql` lê a senha em modo **oculto** (echo desabilitado no terminal) e envia para o servidor já com hash — a senha em texto puro nunca é digitada em uma linha de comando SQL, nunca aparece ecoada na tela, nunca fica gravada em nenhum arquivo `.sql` versionado, nunca entra no Git, e não aparece em nenhum prompt escrito por esta skill nem em nenhum log de aplicação da migration (histórico do `psql`, logs do servidor com `log_statement`, scrollback de terminal salvo). Um `ALTER ROLE ... PASSWORD '<senha_real>'` digitado ou colado diretamente expõe a senha em texto puro em qualquer um desses lugares.
- Depois de definida, a senha deve ser registrada **manualmente** na credencial Postgres do n8n (passo 3) — nunca reaproveitada de PROD ou de qualquer outro ambiente/projeto.
- Feche a sessão do `psql` sem salvar histórico de comandos com a senha em texto puro (o próprio `\password` já evita isso, mas confirme que nenhum outro comando na mesma sessão ecoou a senha).

**Nenhum arquivo desta migration contém um placeholder de senha para substituição manual** — `002_roles_and_schema.sql` cria as roles sem senha alguma; a senha é aplicada inteiramente fora de qualquer arquivo, via `\password`, como descrito acima.

## 3. Cadastrar a credencial no n8n

No n8n de DEV (projeto **rufino-linkedin-dev**, serviço **n8n**), cadastre uma credencial nativa do tipo Postgres:

| Campo | Valor |
|---|---|
| Nome lógico da credencial | `Postgres — Rufino LinkedIn DEV` (ou equivalente, sem incluir a senha no nome) |
| Host | host interno do serviço `linkedin-db` no EasyPanel (rede interna do projeto `rufino-linkedin-dev`) |
| Porta | porta padrão do serviço `linkedin-db` (conforme configurado no EasyPanel) |
| Banco | `rufino-linkedin-dev` |
| Usuário | `n8n_rufino_linkedin_dev` |
| Senha | a senha real definida no passo 2 — colada diretamente no campo do cofre do n8n, nunca em texto de workflow, node ou arquivo |
| SSL | conforme exigido pela configuração do serviço `linkedin-db` no EasyPanel |

- **Nunca** cadastre uma credencial usando a role administrativa/superuser do serviço `linkedin-db` (equivalente a `postgres`) como credencial do n8n — só `n8n_rufino_linkedin_dev`, que tem exatamente `EXECUTE` em 12 das 15 funções + `SELECT` nas 11 tabelas **[v1.5.0]** (`transition_connection_status`, `issue_action_token` e `create_notification_job` são internas — ver seção 4 abaixo).
- Depois de cadastrada, teste a conexão dentro do próprio n8n (botão de teste da credencial) — isso não expõe a senha em lugar nenhum, só confirma que a conexão abre.

## 4. Retomada manual de `ERRO`

`transition_connection_status` é uma função **interna** (uma das 3 desde a v1.5.0, junto com `issue_action_token` e `create_notification_job`) — a role de aplicação (`n8n_rufino_linkedin_dev`) não tem `EXECUTE` nela, só as outras 12 funções (que rodam como a role owner) conseguem chamá-la. Isso fecha uma superfície de ataque desnecessária (o n8n nunca deveria poder pular direto para qualquer transição de status arbitrária), mas tem uma consequência prática: a única transição que a arquitetura sempre tratou como manual — tirar uma conexão do estado `ERRO` depois de confirmação humana (ver `references/statuses.md` da skill) — exige uma sessão administrativa, não pode ser feita chamando a função como se fosse a própria credencial do n8n.

Procedimento administrativo (até existir uma função própria, mais restrita, dedicada a isso — ver observação no fim desta seção):

1. Conecte-se ao banco `rufino-linkedin-dev` com uma credencial administrativa (a mesma usada para aplicar a migration — nunca a credencial do n8n).
2. Assuma a role owner só para esta chamada: `SET ROLE n8n_rufino_linkedin_owner_dev;` (funciona mesmo a owner sendo `NOLOGIN` — `NOLOGIN` só impede autenticar uma nova conexão diretamente como essa role; um superuser ou role com privilégio de `SET ROLE` ainda pode assumi-la dentro de uma sessão já autenticada).
3. Chame a função diretamente, informando o novo status confirmado por Anderson (não o sugerido automaticamente por `workflow_errors.recommended_resume_status`, que é só uma sugestão):
   ```sql
   SELECT * FROM rufino_linkedin.transition_connection_status(
       '<connection_id>', 'ERRO', '<novo_status_confirmado>',
       'anderson', 'retomada manual apos revisao', 'MANUAL', NULL
   );
   ```
4. `RESET ROLE;` ao terminar.

Isso é intencionalmente um procedimento administrativo, não uma automação — a retomada de `ERRO` nunca deve ser silenciosa ou automática. Uma versão futura desta jornada pode adicionar uma décima segunda função, `SECURITY DEFINER` e com `EXECUTE` restrito (ex.: só aceitando `p_expected_current_status='ERRO'`, com seus próprios logs/auditoria dedicados), para que essa retomada não precise mais de uma sessão administrativa — isso é uma evolução documentada, não algo pendente desta migration.

## 5. Roles já existentes de uma tentativa anterior (herdado da v1.4.2, sem mudança na v1.5.0)

`002_roles_and_schema.sql` **não corrige silenciosamente** nenhuma role que já exista com atributos divergentes do esperado — ele **aborta** a migration com uma mensagem clara se encontrar:

- `n8n_rufino_linkedin_owner_dev` já existente com `LOGIN`, `SUPERUSER`, `BYPASSRLS`, `CREATEDB`, `CREATEROLE` ou `REPLICATION` habilitados (owner deve ser estritamente `NOLOGIN` e sem nenhum desses privilégios).
- `n8n_rufino_linkedin_dev` já existente sem `LOGIN`, ou com `SUPERUSER`, `BYPASSRLS`, `CREATEDB`, `CREATEROLE` ou `REPLICATION` habilitados.
- `n8n_rufino_linkedin_dev` já sendo membro de `n8n_rufino_linkedin_owner_dev` (a role de aplicação nunca deve herdar privilégios da owner).

Se a migration abortar nesse ponto, a correção é **manual e deliberada** — inspecione a role divergente (`SELECT * FROM pg_roles WHERE rolname = '...'`), decida com a equipe se ela deve ser recriada do zero (`DROP ROLE` + reaplicar `002`) ou ajustada (`ALTER ROLE`), e só então reaplique `002_roles_and_schema.sql`. Nunca contorne o abort comentando a validação.

## 6. Checklist antes da migration

- [ ] Backup ou snapshot recente do banco `rufino-linkedin-dev` confirmado (mesmo em DEV — evita retrabalho se algo sair diferente do esperado).
- [ ] Confirmado, por consulta direta ao banco, que `pgcrypto` está instalada no schema `extensions` (já confirmado nesta rodada por consulta real em `pg_extension`: versão 1.3) — `001_preflight.sql` reconfirma isso automaticamente e aborta se divergir.
- [ ] Confirmado que o banco atual ao rodar a migration é de fato `rufino-linkedin-dev` (não `n8n-db`, não um banco de PROD).
- [ ] Nenhuma das roles `n8n_rufino_linkedin_owner_dev` / `n8n_rufino_linkedin_dev` já existe com definição divergente (ver seção 5 acima — a migration agora aborta em vez de corrigir sozinha).
- [ ] Arquivos `001` a `007` revisados nesta ordem, sem pular nenhum (`007` é um stub documental — não tem SQL para revisar, só o comentário explicando por quê).
- [ ] Ninguém aplicou ainda nenhum destes arquivos neste banco (evitar reaplicação parcial fora de ordem).
- [ ] Todos os arquivos `001`–`009` serão aplicados com `psql -v ON_ERROR_STOP=1 -f <arquivo>` — sem essa flag um erro no meio do arquivo não interrompe o `psql`.
- [ ] **[v1.5.0]** Confirmado que a versão do PostgreSQL alvo é a mesma testada (17.10 em DEV real) — se divergir, reexecutar `008_validation_queries.sql`/`009_smoke_tests.sql` contra a versão real antes de prosseguir (o desvio desta rodada usou PostgreSQL 16.13 descartável, ver `TEST-REPORT.md`).

## 7. Checklist depois da migration

- [ ] `008_validation_queries.sql` executado (manualmente, uma consulta de cada vez) e todos os 21 resultados **[v1.5.0]** batem com o "Esperado" comentado em cada bloco.
- [ ] `009_smoke_tests.sql` executado com sucesso (todas as 36 linhas **[v1.5.0]** `SMOKE OK`, nenhuma `SMOKE FALHOU`) — roda e desfaz sozinho (`ROLLBACK`), pode repetir quantas vezes quiser.
- [ ] Senha real aplicada na role `n8n_rufino_linkedin_dev` via `\password` (passo 2) e credencial cadastrada no n8n (passo 3).
- [ ] Teste de conexão da credencial no n8n bem-sucedido.
- [ ] Nenhuma senha real ficou em nenhum arquivo deste repositório, em nenhum log de terminal salvo, ou em qualquer mensagem de chat.
- [ ] `EXECUTE` confirmado: 12 das 15 funções **[v1.5.0]** para `n8n_rufino_linkedin_dev`; `transition_connection_status`/`issue_action_token`/`create_notification_job` **sem** `EXECUTE` para a role de aplicação, e **nenhuma** das 15 com `EXECUTE` para `PUBLIC` (consultas 2 e 4 de `008_validation_queries.sql`).
- [ ] `SELECT`-only confirmado para a role de aplicação nas 11 tabelas **[v1.5.0]** — nenhum `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE` (consulta 5).
- [ ] RLS habilitado nas 11 tabelas **[v1.5.0]**, **`FORCE` desabilitado** (consulta 6 — importante: `rls_forcado` deve ser `false`, não `true`).
- [ ] Role de aplicação confirmada sem `SUPERUSER`/`BYPASSRLS`/`CREATEDB`/`CREATEROLE`/`REPLICATION`, e sem ser membro da owner (consultas 7 e 19).
- [ ] Grants de `pgcrypto` confirmados: owner com `USAGE` em `extensions` + `EXECUTE` em `digest`/`gen_random_bytes`; role de aplicação **sem** `USAGE` em `extensions` (consulta 11; confirmado também em execução real por `009_smoke_tests.sql`, item 32).
- [ ] Toda `connections` com sua `message_versions` de `version=1`/`source='gpt'` (consulta 12 — só relevante depois de existirem dados reais).
- [ ] **[v1.5.0]** Ausência de `connections.pending_action_token_hash`/`_expires_at` confirmada (consulta 15); existência de `action_tokens`, `callback_receipts`, `notification_jobs` e das novas colunas de `followups` (`claim_token_hash`/`claim_expires_at`/`claimed_by`/`claim_execution_id`) confirmada (consulta 14); nenhuma coluna de token bruto em nenhuma tabela.
- [ ] **[v1.5.0]** 4 constraints `UNIQUE` novas confirmadas: `action_tokens.token_hash`, `followups.claim_token_hash`, `notification_jobs.claim_token_hash`, `(connection_id, job_type, status)` em `notification_jobs` (consulta 16).
- [ ] **[v1.5.0]** Índice `workflow_errors_execution_dedupe_key` (`NULLS NOT DISTINCT`) confirmado (consulta 17).
- [ ] Nenhum status não-terminal sem transição de saída, conforme lista de arestas de `transition_connection_status` (consulta 18 — estrutural, espelha o SQL real).
- [ ] **[v1.5.0]** `delivery_events.delivery_mode` CHECK confirmado só com `MANUAL_ASSISTED` (consulta 21).
- [ ] Rollback (`rollback/001_rollback.sql`) revisado e compreendido pela equipe — sem executá-lo — como plano de contingência.
- [ ] GATE 3 (banco DEV) atualizado para refletir que a migration foi testada de fato em PostgreSQL descartável (ver `TEST-REPORT.md`); aplicação real contra `rufino-linkedin-dev` segue pendente de confirmação explícita separada.
