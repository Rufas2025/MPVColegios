# Piloto Leandro — teste real de ponta a ponta (2026-11-11)

Executado no banco real `rufino-linkedin-dev` e nos workflows reais do n8n DEV, sob autorização explícita. PROD não foi tocado. Nenhum workflow foi ativado (todas as execuções abaixo foram manuais, via MCP). Nenhuma mensagem real foi enviada no LinkedIn nem no Telegram.

## 1. Migração 013 — exceção pontual e auditável ao D+1

Arquivo: `013_anticipate_schedule_exceptional.sql` (rollback: `rollback/005_anticipate_schedule_exceptional_rollback.sql`).

Nova função `rufino_linkedin.anticipate_connection_schedule(p_connection_id, p_new_scheduled_at, p_motivo, p_actor, p_workflow_name, p_execution_id)`:
- Exige `p_motivo` e `p_actor` (rejeita em branco).
- Só permite **antecipar** (`p_new_scheduled_at` precisa ser antes do `scheduled_at` atual) — nunca adiar, nunca mover para qualquer data arbitrária.
- Só opera sobre uma conexão em `AGUARDANDO_D1`.
- Nunca faz `UPDATE` direto fora de função — é `SECURITY DEFINER`, única porta de escrita.
- Reaproveita `connection_status_history` (sem tabela nova): grava o evento com `previous_status = new_status` (o status não muda, só o agendamento) e o motivo/ator/antes/depois no campo `reason`.
- **Não toca `operational_config`** — a regra global (09h America/Sao_Paulo para todos os demais contatos) permanece intacta.
- Testada localmente antes de ir para o DEV real: caminho feliz + 3 guardas (sem motivo, tentativa de adiar, conexão fora de `AGUARDANDO_D1`) — todas rejeitadas corretamente.

Aplicada no DEV real via `SET LOCAL ROLE n8n_rufino_linkedin_owner_dev` (mesma credencial temporária de DDL das rodadas anteriores). Readback confirmou: 15 tabelas (sem tabela nova), 25 funções (24 + a nova), nenhum objeto pré-existente alterado.

**Chamada real, uma única vez, exclusivamente para a conexão do Leandro:**
```sql
SELECT * FROM rufino_linkedin.anticipate_connection_schedule(
  '0d315743-ff4f-43f9-8da7-7404f7a2585f'::uuid,
  now(),
  'Piloto 01 - teste de ponta a ponta autorizado explicitamente por Anderson Rufino em 2026-11-11, sem alterar a regra global de D+1',
  'anderson', 'PILOTO-01-EXCECAO', 'exec-anticipate-leandro-real-1'
);
-- Resultado real: previous_scheduled_at=2026-11-12T12:00:00Z (D+1 original) -> new_scheduled_at=2026-11-11T17:47:19Z
```
Nenhuma outra conexão existe no banco além da do Leandro neste momento, então nenhum outro contato foi ou poderia ter sido afetado.

## 2. Workflows reais preparados

Os 4 workflows já existiam (GATE 4) mas seus nodes Postgres estavam **sem credencial configurada** (bloqueador real, não documentado antes). Corrigido via `update_workflow`/`setNodeCredential`, usando a credencial de aplicação já existente (`Rufino LinkedIn DEV`, role `n8n_rufino_linkedin_dev`):

| Workflow | Nodes Postgres corrigidos |
|---|---|
| WF-02 - Scheduler D+1 | `Claim Due Connections (Postgres)` |
| WF-NOTIFY - Telegram Outbox | `Claim Notification Jobs`, `Confirm Approval Delivery`, `Confirm Delivery Notification` |
| WF-03 - Approval Callback | `Approve Message (Postgres)`, `Get Current Message Version`, `Present Message For Delivery` |
| WF-05 - Follow-up | `Claim Due Followups`, `Complete Followup (Respondeu)`, `Complete Followup (Sem Resposta)` |

Nenhum workflow foi ativado (`active` continua `false` nos 4). Todas as execuções abaixo foram manuais (`executionMode: manual`), não disparos recorrentes reais.

## 3. Bloqueio exato confirmado (credencial Telegram)

**Não existe nenhuma credencial Telegram cadastrada no n8n** (`list_credentials` retorna só as 2 credenciais Postgres). Os nodes `n8n-nodes-base.telegram`/`telegramTrigger` em WF-NOTIFY e WF-03 não têm credencial atribuída — erro real reproduzido: `"Node does not have any credentials set"`.

Além da credencial, há 2 campos com valor placeholder nunca preenchido:
- `telegram_chat_id` (nodes "Build Approval Message" e "Build Delivery Message" de WF-NOTIFY, e "Build Followup Reminder" de WF-05) — hoje `<__PLACEHOLDER_VALUE__Chat ID do Telegram de Anderson (ex.: 123456789)__>`.
- `chatIds`/`userIds` de restrição no `Approval Callback Trigger` (WF-03) e `Followup Callback Trigger` (WF-05).

**O que falta, exatamente:** (1) uma credencial n8n do tipo Telegram (bot token do bot do Rufino); (2) o chat_id real de Anderson no Telegram, para substituir os 3 placeholders acima. Nada mais bloqueia o envio da notificação real.

## 4. Teste real de ponta a ponta (sem o envio Telegram, que está bloqueado acima)

Todas as chamadas abaixo são reais, contra o banco `rufino-linkedin-dev`, usando a conexão real do Leandro.

| Passo | Ação | Resultado real |
|---|---|---|
| 1 | `anticipate_connection_schedule` (exceção, item 1) | `scheduled_at` antecipado para agora; `AGUARDANDO_D1` preservado |
| 2 | **WF-02 executado manualmente** | `claim_due_connections` reivindica Leandro → `AGUARDANDO_APROVACAO`; cria job `APPROVAL` |
| 3 | **WF-NOTIFY executado manualmente** | `claim_notification_jobs` reivindica o job real, emite `action_token` real → falha exatamente no node de envio Telegram (bloqueio do item 3) |
| 4 | `approve_message` com o `action_token` real capturado, decisão `APROVAR_E_PREPARAR` (mensagem v1 já aprovada por você em texto) | `new_status = APROVADO` |
| 5 | **WF-02 executado de novo** | `claim_due_connections` → **0 linhas** (Leandro não é reivindicado de novo — sem duplicidade) |
| 6 | Reuso do mesmo `action_token` de aprovação (callback_query_id diferente) | **Rejeitado:** `approve_message: action_token ja consumido` — prevenção de duplicidade confirmada |
| 7 | `present_message_for_delivery` | `status = PRONTO_PARA_ENVIO`; cria job `DELIVERY` |
| 8 | **WF-NOTIFY executado manualmente de novo** | `claim_notification_jobs` reivindica o job `DELIVERY` real, emite novo `action_token` real → falha de novo no envio Telegram (mesmo bloqueio) |
| 9 | **WF-05 executado manualmente** | `claim_due_followups` → 0 linhas (correto: nenhum follow-up existe ainda, pois o envio real ainda não foi confirmado) |

**Parado deliberadamente aqui.** `mark_message_sent` (que registraria o envio e agendaria o 1º follow-up) **não foi chamado** — essa chamada só deve acontecer quando você tiver colado esta mensagem de verdade no LinkedIn e confirmado manualmente, nunca antes.

## 5. Mensagem final, aprovada, pronta para copiar e enviar no LinkedIn

> Fala, Leandro! Tudo bem?
>
> Que bacana termos nos conectado por aqui! Gosto muito das boas conversas e das trocas que o LinkedIn proporciona, especialmente com quem vive o dia a dia da educação.
>
> Dei uma olhada na sua trajetória e vi que você passou pela Rede Elite de Ensino e hoje segue como Diretor de Unidade Escolar no Colegium, em Belo Horizonte, desde abril de 2024. Uma bonita jornada!
>
> Também estou no segmento educacional há cerca de 15 anos e acredito muito no valor de trocar experiências com quem está à frente da gestão das escolas.
>
> Vamos mantendo contato e compartilhando ideias por aqui!
>
> Grande abraço, Rufino

## 6. Envio confirmado e registrado (2026-11-11, 18:02 UTC / ~15h02 horário de Brasília)

Anderson confirmou por escrito, com print anexado como evidência, que enviou manualmente a mensagem acima ao Leandro no LinkedIn em 11/11/2026 às 15h (horário de Brasília). `mark_message_sent` foi chamado com o `action_token` de entrega real (passo 8 da tabela acima), `p_first_followup_at = now() + 3 dias` — mesma cadência já usada pelo node real "Compute First Followup Date" do WF-04 (`$now.plus(3, 'days')`), nunca inventada aqui.

**Nota de precisão:** `delivery_events.event_at`/`connection_status_history.created_at` registram o momento em que a confirmação foi processada no banco (18:02 UTC), não literalmente as 15h00:00 relatadas — a função não recebe um horário de envio como parâmetro, só confirma "agora". O horário exato relatado por você (15h, horário de Brasília) fica registrado no `actor`/`reason` do evento e neste documento, não como campo estruturado separado.

**Readback final confirmado:**

| Campo | Valor |
|---|---|
| `status` | `FOLLOWUP_PENDENTE` |
| `data_conexao_origem` / `confirmado_por` | `linkedin_mynetwork_confirmacao_manual` / `anderson` (inalterado) |
| Histórico de status | `NOVO → AGUARDANDO_D1 → (antecipação manual) → AGUARDANDO_APROVACAO → APROVADO → PRONTO_PARA_ENVIO → ENVIADO → FOLLOWUP_PENDENTE` — 8 eventos, todos com ator e motivo auditados |
| `delivery_events` | `MENSAGEM_APRESENTADA` (17:51:11) + `MARCADO_COMO_ENVIADO` (18:02:47) |
| `followups` | 1 linha, `sequence=1`, `scheduled_for = 2026-11-14 18:02:47 UTC` (D+3), não reivindicado ainda |

**Verificação de entrega pendente duplicada:** os 2 `notification_jobs` (APPROVAL e DELIVERY) permanecem em `CLAIMED` — nunca chegaram a `DELIVERED`, porque nenhuma confirmação real de entrega no Telegram ocorreu (não registrei uma entrega que não aconteceu). Tecnicamente esses 2 jobs ficaram reivindicáveis de novo (`claim_expires_at` já passou), mas isso **não representa risco real de ação duplicada**: confirmei na definição real de `transition_connection_status` que ela rejeita com erro qualquer transição cujo status atual não bata com o esperado (`conflito de concorrência`) — como Leandro já está em `FOLLOWUP_PENDENTE`, um eventual reclaim futuro do WF-NOTIFY encontraria, na pior hipótese, uma notificação Telegram redundante e inofensiva (quando o Telegram existir), nunca uma segunda aprovação ou um segundo envio real. Nenhuma mensagem nova foi nem será enviada automaticamente.

## 7. Acompanhamento de resposta (ponto 4 da sua autorização)

Mecanismo existente, sem mudança: `claim_due_followups` (WF-05) reivindica este follow-up a partir de `2026-11-14 18:02:47 UTC`; a resposta é confirmada manualmente por você via `complete_followup` (`RESPONDEU` encerra a jornada; `SEM_RESPOSTA` com nova data reagenda, sem data encerra). **Nenhuma mensagem nova é enviada automaticamente** — WF-05 continua inativo, e mesmo ativo, só envia um lembrete pedindo sua confirmação manual, nunca uma mensagem ao Leandro.

## 8. Regra permanente — inalterada

`rufino_linkedin.operational_config` continua com `horario_d1 = 09:00:00`, `timezone = America/Sao_Paulo`, aplicável a todos os demais contatos. A exceção do item 1 afetou somente a conexão do Leandro.

## 9. Lista exata do que seria necessário ativar (NÃO feito — aguardando sua decisão)

Nada abaixo foi ativado. Esta é a lista exata, para sua decisão explícita:

1. **Credencial Telegram** no n8n (bot token) + chat_id real de Anderson nos 3 nodes "Build..." + `chatIds`/`userIds` nos 2 triggers de callback (WF-03, WF-05).
2. **Ativar WF-02** (`active: true`) — dispara `claim_due_connections` 1x/dia, 09:00, para TODOS os contatos em D+1 (regra permanente, não só o Leandro).
3. **Ativar WF-NOTIFY** (`active: true`) — drena o outbox a cada 1 minuto, envia reais mensagens Telegram.
4. **Ativar WF-03** (`active: true`) — passa a receber callbacks reais do Telegram (webhook), processa aprovação/edição/descarte reais.
5. **Ativar WF-05** (`active: true`) — verifica follow-ups pendentes de hora em hora, envia lembretes reais e processa respostas reais.

Recomendo ativar só depois que a credencial Telegram (item 1) existir — caso contrário WF-NOTIFY/WF-03/WF-05 ativos vão gerar erros recorrentes sem nunca completar um envio real.
