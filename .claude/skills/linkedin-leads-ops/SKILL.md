---
name: linkedin-leads-ops
description: "Opera, diagnostica e mantém a arquitetura LinkedIn Leads do Anderson Rufino (Gmail bado14 → Apps Script 'Linkedin | Leads' → n8n Rufino LinkedIn DEV → PostgreSQL rufino_linkedin → Telegram @rufino_linkedin_nareco_bot). Use sempre que a tarefa envolver aceites do LinkedIn que não chegaram, aprovação ou entrega no Telegram, botões que não respondem, follow-up D+5, lembretes duplicados, WF-01E/WF-02/WF-05/WF-NOTIFY/WF-ROUTER, feriados, migrações do schema rufino_linkedin, backup/rollback, ou a checagem diária da cadência, mesmo que o usuário não cite nomes de workflow."
---

# LinkedIn Leads: operação e manutenção

Complementa a skill `rufino-linkedin-n8n-ops` (desenho da jornada e geração de workflows). Esta aqui é o
**manual de operação** do que está em produção desde 20/11/2026. Fonte de verdade: o banco e o n8n reais;
o repositório tem o histórico (`n8n/CHANGELOG-2026-11.md`, `n8n/AUDITORIA-2026-11-20.md`).

## Regras que não mudam

- **Nunca automatizar a conta do LinkedIn.** Nada de envio programático, clique, scraping ou browser automation. O envio é sempre manual, feito pelo Anderson. O sistema só lê e-mails da própria caixa dele.
- **R$0 de orçamento.** Sem Unipile, Expandi, APIs pagas ou trials.
- **Sem segredos em código ou conversa.** Tokens ficam em Propriedades do Apps Script e credenciais do n8n. O `otpToken` dos links do e-mail nunca é guardado nem seguido.
- **Contatos reais não são tocados em teste.** Teste com dados simulados (pin data) ou banco local; nada de mensagem comercial real.
- **Publicar, ativar, aplicar migração ou alterar registro real exige "pode" explícito do Anderson**, item por item.
- **Textos para leads** passam pela skill `nar-eco-revisao-antislop` e seguem: homem "Fala, {Nome}! Tudo bem?" + "Valeu por ter aceito o meu convite aqui no LinkedIn"; mulher ou nome ambíguo "Olá, {Nome}! Tudo bem?" + "Obrigado por ter aceito…"; nunca "nos conectamos"/"conexão"; sem travessão; assinatura "Grande abraço,\nRufino".

## Arquitetura

```text
LinkedIn (aceite) ──e-mail──▶ Gmail bado14 (invitations@linkedin.com, "X aceitou seu convite")
        │
        ▼ a cada 10 min (acionador)
Apps Script "Linkedin | Leads"  (apps-script/linkedin-leads/Codigo.gs)
  lê nome, primeiro nome, cargo (HTML), slug do perfil, data de chegada
  POST + cabeçalho X-Leads-Token ─────────────▶ n8n WF-01E  /webhook/rufino-linkedin-aceites
  rotula "LinkedIn/Aceite processado" só quando o n8n responde processado=true
        │
        ▼
WF-01E: classifica ICP → monta mensagem D+1 → register_connection (AGUARDANDO_D1, scheduled_at = D+1 útil 9h)
        │
        ▼ seg–sex 9h, pula feriados
WF-02: claim_due_connections → job APPROVAL ──▶ WF-NOTIFY (a cada minuto) ──▶ Telegram: aprovação
        │                                                                     botões a:A / a:E / a:R / a:D
        ▼ toque
WF-ROUTER (único Telegram Trigger): approve_message → present_message_for_delivery → job DELIVERY
        ──▶ WF-NOTIFY (disparo imediato) ──▶ Telegram: só o texto + "Abrir perfil" + a:S / a:B
        ▼ Anderson cola no LinkedIn e toca "Marcar como enviada" (a:S)
mark_message_sent → FOLLOWUP_PENDENTE + follow-up em +3 dias
        ▼ seg–sex 9h, pula feriados
WF-05: claim_due_followups (botão vale 7 dias) → Telegram "X respondeu?" f:R / f:N ──▶ WF-ROUTER → complete_followup
```

## Componentes

Instância n8n: `rufino-linkedin-dev-n8n.snfrzv.easypanel.host`, projeto `Ml3QRAVaQdfd1Bj6`.

| Workflow | ID | Gatilho | Responsabilidade |
|---|---|---|---|
| WF-01E Intake por E-mail | `KMD9YouA1Un7Y68H` | Webhook POST `rufino-linkedin-aceites` (Header Auth) | Valida, classifica ICP, dedup por URL, monta mensagem, `register_connection`. Trava `PROCESSAMENTO_REAL` no 1º Code node. |
| WF-02 Scheduler D+1 | `CxLUUmLpj3mA0nfz` | Seg–sex 9h (America/Sao_Paulo) | Pula feriado; `claim_due_connections(p_limit => 20)`: no máximo 20 aprovações por dia, mais antigas primeiro. |
| WF-NOTIFY Outbox | `xmshrOsfUkWSBfnG` | A cada minuto + "Disparo Imediato" | `claim_notification_jobs` → envia aprovação/entrega → `confirm_notification_delivery`. |
| WF-ROUTER | `Gjc9slZAO5lcS5RM` | **Único** Telegram Trigger (callback_query) | Valida remetente (chat 5550833898) e roteia `a:*` e `f:*`. |
| WF-05 Follow-up | `W36Y8pew9wwaCb6d` | Seg–sex 9h | Pula feriado; `claim_due_followups` → lembrete com nome e botões. Sem trigger de Telegram. |
| 99 - TEMP Manual SQL | `T29l4aosjdj26HZF` | Manual | Utilitário para SQL pontual autorizado (inativo). |

Inativos que **não podem ser ativados** (têm Telegram Trigger próprio e roubariam o webhook do roteador):
WF-03 `eomHxG6ODD8pMvMp`, WF-04 `J1CFdbxNhICh9MEP`, `TEST - Capturar Chat ID` `afpOaSXoyRzpHphR`.

Credenciais (por nome; nunca copie valores):
- `Rufino LinkedIn DEV` (postgres, role `n8n_rufino_linkedin_dev`, só SELECT + EXECUTE).
- `Rufino LinkedIn DEV - Owner (DDL)` (postgres; para migração, exige `SET LOCAL ROLE n8n_rufino_linkedin_owner_dev`).
- `Rufino LinkedIn DEV - Telegram` (bot).
- `Apps Script - Token Aceites LinkedIn` (Header Auth, cabeçalho `X-Leads-Token`).

Apps Script (conta Google bado14), Propriedades do script: `N8N_WEBHOOK_URL`, `N8N_WEBHOOK_TOKEN`
(criado por `gerarToken()`), `MODO` (`SIMULAR` | `TESTE` | `PRODUCAO`), `MEU_SLUG` (opcional). O nome da
propriedade é sempre `MODO`; o valor muda.

Dados auxiliares: tabela de dados n8n `Feriados - Rufino LinkedIn` (`68dMfcuKOk9OqDXb`, colunas `data`,
`descricao`), cadastrada até 15/11/2027.

## Estados e cadência

```text
NOVO → AGUARDANDO_D1 → AGUARDANDO_APROVACAO → APROVADO → PRONTO_PARA_ENVIO → ENVIADO → FOLLOWUP_PENDENTE
                              │  ↘ REFAZER ↗          ↖ (Voltar e editar) ┘                 │
                              └→ DESCARTADO                                                ├→ RESPONDEU → ENCERRADO
                                                                                           └→ SEM_RESPOSTA → FOLLOWUP_PENDENTE (+3 dias)
```

- **D+1:** `data_conexao` + 1 dia; sábado/domingo vão para segunda; hora = `operational_config.horario_d1` (9h). Feriado não muda `scheduled_at`: o WF-02 simplesmente não roda e o contato sai no próximo dia útil.
- **Origem da data:** `linkedin_email_notificacao_aceite` = dia de chegada do e-mail (pode ser 1 dia depois do aceite, nunca antes).
- **Follow-up:** "Marcar como enviada" agenda +3 dias a partir do toque; o lembrete sai às 9h do dia útil seguinte ao vencimento. "Sem resposta" agenda mais +3 dias; "Respondeu" encerra.
- **Validade dos botões:** aprovação/entrega 7 dias (`action_tokens`); follow-up 7 dias (claim, migração 015). Botão vencido mostra ⚠️ e não grava nada.

## Diagnóstico

Consultas prontas em `references/diagnostico-sql.md`. Rode só leitura, pelo workflow `99 - TEMP Manual SQL`
com a credencial do app.

| Sintoma | Onde olhar | Causa provável |
|---|---|---|
| Aceite não virou contato | Apps Script → Execuções; log de `processarAceites` | `MODO` diferente de `PRODUCAO`; acionador removido; e-mail não chegou (LinkedIn suprime se você já viu no app; limite de envio). |
| Script loga "HTTP 403" | Credencial Header Auth no n8n | Token no n8n diferente de `N8N_WEBHOOK_TOKEN`; credencial criada em outra instância (já aconteceu: crm nar). |
| Script loga "HTTP 404" | WF-01E | Workflow despublicado ou caminho mudou. |
| Contato "REVISAR"/"NAO LIDO" no Telegram | Cargo do e-mail | Cargo ausente ou fora do padrão. Se o Anderson confirmar ICP, cadastrar com `register_connection` pelo `99 - TEMP Manual SQL` (mesmos parâmetros do WF-01E, `p_workflow_name => 'MANUAL-REVISAR'`; precedente: Narda, 20/11). |
| Aprovação não chegou às 9h | Execuções do WF-02 e WF-NOTIFY | Feriado na tabela; WF-02 inativo; job preso em CLAIMED (expira em 15 min e é reenviado). |
| Botão não faz nada | Execuções do WF-ROUTER | Outro workflow com Telegram Trigger foi ativado e roubou o webhook; republique o WF-ROUTER e desative o outro. |
| ⚠️ "Não foi possível concluir" | — | Botão já usado, vencido (7 dias) ou de mensagem antiga. Não é erro do sistema. |
| Lembrete duplicado | `followups.claim_expires_at` | Só deve acontecer após 7 dias sem resposta (reenvio intencional). Se for mais cedo, confira a md5 de `claim_due_followups` (= `233dab2a…`). |
| Contato duplicado | `connections` por URL | Mesma pessoa com slug codificado e decodificado (`%e2%80%98` vs `‘`). O WF-01E usa sempre o slug como vem no link. |

Duplicata no WF-01E é barrada em três camadas: rótulo no Gmail, consulta "Buscar Existentes" por URL e
`ON CONFLICT (idempotency_key)` em `register_connection` (chave `li-{slug}`).

## Como testar sem afetar contatos reais

1. **Lógica do n8n:** `test_workflow` com pin data em todo nó com credencial **e** nos nós `executeWorkflow` (senão o WF-NOTIFY real dispara). Ex.: WF-01E com eventos falsos e `modo: producao` para provar a trava.
2. **Banco:** Postgres 16 local descartável com as migrações do repositório (ver `db/migrations/dev/README.md`); testes em `db/migrations/dev/tests/` rodam dentro de `BEGIN … ROLLBACK`.
3. **Apps Script:** `testarLeitura` (não envia nada), `testarConexao` (pacote vazio), `enviarTeste` com `MODO = TESTE` (n8n não grava; resumo "TESTE" no Telegram).
4. **Telegram:** workflow temporário que envia mensagem marcada "TESTE" com token falso; tocar o botão deve gerar ⚠️ sem gravar. Arquive o temporário depois.
5. **Teste simulado não prova execução real.** Pin data pula credenciais, Telegram e banco. Só o evento real (9h de dia útil, toque real) fecha a validação.

## Backup e rollback

- **Antes de alterar um workflow:** registre o `versionId` (`get_workflow_history`) e salve o JSON em `n8n/backups/AAAA-MM-DD/`. Restaurar: n8n → Histórico de versões → Restaurar, e publicar.
- **Migração:** arquivo novo e incremental em `db/migrations/dev/NNN_*.sql` com rollback em `rollback/`. Testar no Postgres local (aplicar, testar, rollback restaura md5, reaplicar) antes do DEV.
- **Aplicar no DEV:** pelo `99 - TEMP Manual SQL` com a credencial DDL, conteúdo entre `BEGIN;` e `COMMIT;` com `SET LOCAL ROLE n8n_rufino_linkedin_owner_dev;` logo após o `BEGIN`. Conferir com a credencial do app: md5 da função, dono e `has_function_privilege`.
- **Rollbacks existentes:** `006_origem_email_aceite_rollback.sql` (014; aborta se houver contato com a origem por e-mail) e `007_followup_claim_ttl_rollback.sql` (015).
- **Travar a entrada de novos contatos sem desligar nada:** `PROCESSAMENTO_REAL = false` no WF-01E e publicar, ou `MODO = SIMULAR` no Apps Script.

## Lições aprendidas

1. **Um bot, um webhook.** O Telegram aceita um único webhook por bot. Qualquer workflow com Telegram Trigger publicado toma o webhook do anterior. Todos os botões passam pelo WF-ROUTER; workflows que mandam mensagem com botão não têm trigger próprio.
2. **Filtro no Telegram Trigger descarta callback.** O filtro chatIds/userIds do trigger fazia o roteador ignorar toques; a segurança fica no IF "Validar Remetente Autorizado".
3. **Credencial DDL precisa de `SET LOCAL ROLE`.** Sem isso a migração falha com "permission denied for schema" e, por estar em transação, nada é aplicado.
4. **Simulado ≠ real.** `test_workflow` não executa nós com credencial. Já houve erro só visível em execução real (tipos `bigint` em `confirm_notification_delivery`, corrigido com `::text`).
5. **Ordem dos ramos = posição no canvas.** No WF-01E a resposta ao Apps Script fica abaixo do registro para que falha de gravação não rotule o e-mail.
6. **Validade de botão precisa casar com o ritmo humano.** Claim de 1 hora gerava lembrete duplicado e botão morto; virou 7 dias.
7. **Conferir a instância antes de criar credencial.** Há duas instâncias n8n (Rufino LinkedIn DEV e crm nar).

## Limitações conhecidas e pendências

- Detecção de resposta é manual (toque em "Respondeu"); dá para automatizar pelo e-mail "X enviou uma mensagem".
- Sem alerta de falha (WF-90 Error Handler existe, inativo).
- O LinkedIn não manda e-mail de aceite se a notificação já foi vista no app; rede de segurança é a exportação de conexões (Connections.csv).
- Lote antigo (~30 conexões de outubro em diante) ainda não importado.
- Botão "Editar" aponta para formulário inexistente (WF-03-EDIT inativo); use "Refazer" ou "Voltar e editar".
- Gancho "2027" no texto vale até ~fevereiro/2027.
- Botões vencidos não são reenviados automaticamente.
- Exports atualizados de WF-ROUTER, WF-NOTIFY, WF-02 e WF-05 ainda não estão no repositório; `gate4/workflows/dev/` é histórico (versões antigas).
- WF-NOTIFY gera ~1.440 execuções/dia; considerar não salvar execuções de sucesso.

## Checklist da operação de segunda, 23/11/2026

Antes das 9h:
- [ ] Apps Script → Execuções: `processarAceites` rodando a cada 10 min, sem erro.
- [ ] n8n: WF-01E, WF-02, WF-05, WF-NOTIFY e WF-ROUTER ativos.

9h às 9h15:
- [ ] WF-02 executou com sucesso e reivindicou 20 contatos (teto diário).
- [ ] Chegaram 20 aprovações no Telegram: os 8 aceites recentes (Nagib, Regiane, Rodrigo, Walid, Kerena, Maycon, Sylvio, Narda), o Ari de Sá Neto e os 11 mais antigos do lote do export (onda 1).
- [ ] Às 10h: onda 2 do lote cadastrada (workflow `99 - TEMP Lote Export Onda 2`, 20 contatos para terça). Terça 10h: onda 3 (5 contatos para quarta). Lembretes agendados nesta sessão.
- [ ] WF-05 executou e chegaram 2 lembretes: Leandro (real) e TESTE SINTETICO.
- [ ] Nenhuma mensagem duplicada.

Durante o dia:
- [ ] Aprovar uma mensagem → a cópia chega em segundos com "Abrir perfil", "Marcar como enviada" e "Voltar e editar".
- [ ] Enviar no LinkedIn e tocar "Marcar como enviada" → status `FOLLOWUP_PENDENTE`, follow-up em +3 dias.
- [ ] Fanny: trocar "Fala" por "Olá" ao colar e marcar como enviada (botão vale até 26/11).
- [ ] Leandro: tocar "Respondeu" ou "Sem resposta" conforme a conversa real.
- [ ] TESTE SINTETICO: tocar "Respondeu" para encerrar.
- [ ] Rudney e Bruno: decidir até 26/11.
- [ ] Rodar a consulta "Resumo do dia" de `references/diagnostico-sql.md` e conferir os estados.
