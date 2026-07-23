# Passos manuais — GATE 3 (banco DEV)

Este documento cobre exatamente as ações que **não** estão em nenhum arquivo `.sql` desta pasta, porque não devem estar: envolvem um segredo real. Nenhum arquivo desta migration contém, ou deve conter, uma senha real — só nomes lógicos e placeholders.

Ambiente: EasyPanel, projeto **rufino-linkedin-dev**, serviço de banco **linkedin-db**, banco **rufino-linkedin-dev**, schema operacional **rufino_linkedin**.

## 1. Anderson gera uma senha forte fora do repositório

- Gere a senha com um gerenciador de senhas (1Password, Bitwarden, etc.) ou um comando local que não grave em nenhum arquivo versionado, ex.: `openssl rand -base64 32` executado no seu próprio terminal, **nunca** colado depois em um commit, issue, PR, mensagem de chat ou nesta skill.
- Requisitos mínimos: 32+ caracteres, gerada aleatoriamente (não uma frase memorizável reaproveitada de outro serviço).
- Guarde a senha **somente** no cofre de credenciais do n8n (passo 3) e, se quiser um backup, num gerenciador de senhas pessoal — nunca em texto plano em disco, e-mail, chat ou arquivo deste repositório.

## 2. Aplicar a senha manualmente na role de aplicação

Depois de rodar `002_roles_and_schema.sql` (que cria `n8n_rufino_linkedin_dev` **sem** senha), conecte-se ao banco `rufino-linkedin-dev` com uma credencial administrativa (a mesma usada para aplicar a migration) e rode, substituindo o placeholder pela senha real gerada no passo 1:

```sql
ALTER ROLE n8n_rufino_linkedin_dev PASSWORD '<SENHA_REAL_AQUI>';
```

- **Este comando não entra em nenhum arquivo versionado.** Rode-o direto num cliente SQL (psql, DBeaver, o console de banco do EasyPanel) e feche a sessão sem salvar o histórico com a senha em texto puro.
- Nunca reutilize a senha de PROD ou de qualquer outro ambiente/projeto.

**Comandos que exigem substituição manual antes de rodar** (nenhum outro arquivo desta migration tem esse tipo de placeholder):

- `ALTER ROLE n8n_rufino_linkedin_dev PASSWORD '<SENHA_REAL_AQUI>';` — substituir `<SENHA_REAL_AQUI>` pela senha gerada no passo 1.

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

- **Nunca** cadastre uma credencial usando a role administrativa/superuser do serviço `linkedin-db` (equivalente a `postgres`) como credencial do n8n — só `n8n_rufino_linkedin_dev`, que tem exatamente `EXECUTE` nas 9 funções + `SELECT` nas 8 tabelas.
- Depois de cadastrada, teste a conexão dentro do próprio n8n (botão de teste da credencial) — isso não expõe a senha em lugar nenhum, só confirma que a conexão abre.

## 4. Checklist antes da migration

- [ ] Backup ou snapshot recente do banco `rufino-linkedin-dev` confirmado (mesmo em DEV — evita retrabalho se algo sair diferente do esperado).
- [ ] Confirmado, por consulta direta ao banco, que `pgcrypto` está instalada no schema `extensions` (já confirmado nesta rodada por consulta real em `pg_extension`: versão 1.3) — `001_preflight.sql` reconfirma isso automaticamente e aborta se divergir.
- [ ] Confirmado que o banco atual ao rodar a migration é de fato `rufino-linkedin-dev` (não `n8n-db`, não um banco de PROD).
- [ ] Nenhuma das roles `n8n_rufino_linkedin_owner_dev` / `n8n_rufino_linkedin_dev` já existe com definição divergente (a migration usa `IF NOT EXISTS`, mas revise se já havia algo com esse nome de uma tentativa anterior).
- [ ] Arquivos `001` a `007` revisados nesta ordem, sem pular nenhum.
- [ ] Ninguém aplicou ainda nenhum destes arquivos neste banco (evitar reaplicação parcial fora de ordem).

## 5. Checklist depois da migration

- [ ] `008_validation_queries.sql` executado (manualmente, uma consulta de cada vez) e todos os 10 resultados batem com o "Esperado" comentado em cada bloco.
- [ ] Senha real aplicada na role `n8n_rufino_linkedin_dev` (passo 2) e credencial cadastrada no n8n (passo 3).
- [ ] Teste de conexão da credencial no n8n bem-sucedido.
- [ ] Nenhuma senha real ficou em nenhum arquivo deste repositório, em nenhum log de terminal salvo, ou em qualquer mensagem de chat.
- [ ] `EXECUTE` das 9 funções confirmado só para `n8n_rufino_linkedin_dev` (consulta 4 de `008_validation_queries.sql`).
- [ ] `SELECT`-only confirmado para a role de aplicação nas 8 tabelas — nenhum `INSERT`/`UPDATE`/`DELETE` (consulta 5).
- [ ] RLS habilitado e forçado nas 8 tabelas (consulta 6).
- [ ] Role de aplicação confirmada sem `SUPERUSER`/`BYPASSRLS`/`CREATEDB`/`CREATEROLE`/`REPLICATION` (consulta 7).
- [ ] Rollback (`rollback/001_rollback.sql`) revisado e compreendido pela equipe — sem executá-lo — como plano de contingência.
- [ ] GATE 3 (banco DEV) atualizado para refletir que a migration foi gerada e revisada; aplicação real segue pendente de confirmação explícita separada.
