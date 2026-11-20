# Alterações no n8n DEV (Rufino LinkedIn) - novembro de 2026

Instância: `rufino-linkedin-dev-n8n.snfrzv.easypanel.host` · projeto `Ml3QRAVaQdfd1Bj6`
Credenciais: Postgres app `DgnSAHo0I8CRFwci`, Postgres DDL `ydSAccXsQ6f7YGBr`, Telegram `COKModG0SV9z7mMi`,
Header Auth `AvjmcjATuLDd2jvx` (Apps Script). Chat Telegram autorizado: `5550833898`.

## Publicadas

| Data | Workflow | Mudança |
|---|---|---|
| 19/11 | WF-ROUTER `Gjc9slZAO5lcS5RM` | Filtro chatIds/userIds removido do Telegram Trigger (descartava callback_query); a segurança fica no IF "Validar Remetente Autorizado". Textos de confirmação (toast) por botão. Após "Aprovar" e após "Voltar e editar", dispara o WF-NOTIFY na hora (sem esperar o minuto). |
| 19/11 | WF-NOTIFY `xmshrOsfUkWSBfnG` | Casts `::text` em confirm_notification_delivery. Aprovação em HTML com escape. Entrega = só o texto da mensagem (cópia limpa) + botões "Abrir perfil", "Marcar como enviada", "Voltar e editar". Gatilho "Disparo Imediato" (executeWorkflowTrigger). |
| 19/11 | WF-02 `CxLUUmLpj3mA0nfz` | Agenda dias úteis 9h (America/Sao_Paulo) e pula feriados da tabela de dados `Feriados - Rufino LinkedIn` (`68dMfcuKOk9OqDXb`). |
| 20/11 | WF-01E `KMD9YouA1Un7Y68H` (novo) | Recebe do Apps Script `Linkedin \| Leads` os e-mails de aceite, classifica ICP, monta a mensagem D+1 e chama register_connection (origem `linkedin_email_notificacao_aceite`). Webhook com Header Auth `X-Leads-Token`. `PROCESSAMENTO_REAL = true` desde 20/11 (autorizado). Registro roda antes da resposta ao script. Código: `apps-script/linkedin-leads/`. |
| 20/11 | Banco | Migração 014 aplicada (origem `linkedin_email_notificacao_aceite`). |

## Preparadas, aguardando autorização para publicar

### WF-05 Follow-up `W36Y8pew9wwaCb6d` (inativo; rascunho alterado em 20/11)

Backup da versão anterior: `n8n/backups/2026-11-20/`.

Problemas encontrados:
1. **Conflito de webhook:** o WF-05 tinha um Telegram Trigger próprio. O Telegram aceita um só webhook por bot; publicar o WF-05 trocaria o webhook do WF-ROUTER e todos os botões de aprovação parariam. O WF-ROUTER já trata `f:R`/`f:N` (complete_followup), então o ramo era redundante.
2. **Lembrete duplicado a cada hora:** claim_due_followups dava 1 hora de validade ao botão. Depois disso o botão falhava e a execução seguinte (de hora em hora) mandava outro lembrete do mesmo follow-up.
3. **Lembrete sem identificação:** o texto era "Follow-up pendente: a conexao respondeu (sequence N)?", sem nome nem perfil.
4. **Horário:** rodava de hora em hora, 24h, inclusive fins de semana e feriados.

Correção:
- Removido o Telegram Trigger e todo o ramo de callback (9 nós). Os botões continuam sendo tratados pelo WF-ROUTER, que não foi alterado.
- Agenda: dias úteis 9h, pulando feriados (mesmo padrão do WF-02).
- Novo nó "Buscar Contato" (uma consulta para todos os follow-ups) e "Montar Lembrete": nome, cargo · instituição, pergunta "X respondeu?", botão "Abrir perfil de X", botões "Respondeu" / "Sem resposta" (`f:R:`/`f:N:` + token, 52 bytes, limite do Telegram 64).
- Migração `db/migrations/dev/015_followup_claim_ttl.sql`: validade do botão de 1 hora para 7 dias. Rollback: `rollback/007_followup_claim_ttl_rollback.sql`. Testes: `tests/followup_claim_ttl_tests.sql`.

Ordem de publicação (quando autorizado):
1. Aplicar 015 no DEV (credencial DDL) e conferir md5 de claim_due_followups = `233dab2a9c192afcc9c6581de3a19820`.
2. Publicar o WF-05.
3. Arquivar o workflow temporário `99 - TEMP Preview Lembrete Follow-up` (`NqOUs9ddhl32xcpB`).

Efeito imediato esperado: na primeira execução (dia útil, 9h) sai o lembrete do follow-up vencido do Leandro (agendado para 14/11) e, se já vencido, o do "TESTE SINTETICO WF-ROUTER" (22/11).
