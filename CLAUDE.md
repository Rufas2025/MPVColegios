# CLAUDE.md: MPVColegios

Este repositório reúne o MVP para escolas (`web/`) e a automação **LinkedIn Leads / Rufino LinkedIn
Intelligence** do Anderson Rufino (`apps-script/`, `db/`, `n8n/`, `gate4/`). As instruções abaixo valem
para o trabalho na automação do LinkedIn.

## Antes de qualquer tarefa no LinkedIn Leads

- Use a skill do projeto `.claude/skills/linkedin-leads-ops/` (operação, diagnóstico, backup, checklist).
  Para desenhar ou gerar workflows novos, use também a skill `rufino-linkedin-n8n-ops`.
- Estado atual e histórico: `n8n/AUDITORIA-2026-11-20.md` e `n8n/CHANGELOG-2026-11.md`.
- O n8n correto é **Rufino LinkedIn DEV** (`rufino-linkedin-dev-n8n.snfrzv.easypanel.host`, projeto
  `Ml3QRAVaQdfd1Bj6`). O MCP `n8n - crm nar` é outra instância, de outros clientes: não criar nada lá.

## Regras do projeto

1. **Nunca automatizar a conta do LinkedIn** (envio, clique, scraping, browser). Envio é manual, pelo Anderson.
2. **R$0:** sem ferramentas ou APIs pagas.
3. **Nada de segredo** em código, commit ou conversa. Credenciais por nome; tokens em Propriedades do
   Apps Script ou credenciais do n8n. Nunca guardar ou seguir o `otpToken` dos links do LinkedIn.
4. **Produção só com autorização explícita**, item por item: publicar/ativar workflow, aplicar migração,
   alterar registro real, mudar `PROCESSAMENTO_REAL` ou `MODO`.
5. **Teste sem contato real:** pin data (incluindo nós `executeWorkflow`), banco Postgres local, modos
   `SIMULAR`/`TESTE` do Apps Script. Teste simulado não substitui a primeira execução real; diga isso.
6. **Um único Telegram Trigger** (WF-ROUTER). Nunca ativar WF-03, WF-04 ou `TEST - Capturar Chat ID`, e
   nunca criar outro workflow com Telegram Trigger para o mesmo bot.
7. **Migrações:** sempre incrementais em `db/migrations/dev/NNN_*.sql`, com rollback em `rollback/` e teste
   local (aplicar, testar, rollback restaura md5, reaplicar). No DEV, usar a credencial DDL com
   `SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;` logo após `BEGIN;`.
8. **Backup antes de alterar workflow:** `versionId` + JSON em `n8n/backups/AAAA-MM-DD/`.
9. **Textos para leads:** regras de saudação por gênero, sem "nos conectamos", sem travessão, revisão com
   a skill `nar-eco-revisao-antislop`. Nunca enviar mensagem comercial em teste.
10. **Commit e push só quando o Anderson pedir** (ou um hook exigir), no branch de trabalho em uso.

## Mapa rápido

| Pasta | Conteúdo |
|---|---|
| `apps-script/linkedin-leads/` | `Codigo.gs` (leitor do Gmail) e `wf-01e-intake-email.n8n.ts` (código do WF-01E) |
| `db/migrations/dev/` | Migrações 001–015, rollbacks, testes, `N8N-INTEGRATION.md`, `MANUAL-STEPS.md` |
| `n8n/` | Changelog, auditoria e backups de workflows |
| `gate4/workflows/dev/` | Exports antigos (11/2026). **Desatualizados**: não reimportar sem comparar com o n8n |
| `.claude/skills/linkedin-leads-ops/` | Manual de operação e consultas de diagnóstico |
