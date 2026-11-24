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
| 20/11 | Banco | Migração 015 aplicada (claim de follow-up 7 dias). md5 de claim_due_followups no DEV = `233dab2a9c192afcc9c6581de3a19820`, igual ao teste local; app executa, PUBLIC não. |
| 20/11 | WF-05 `W36Y8pew9wwaCb6d` | Publicado (versão `9ea9444c`), autorizado por Anderson. Detalhes abaixo. Workflow temporário de preview `NqOUs9ddhl32xcpB` arquivado. |
| 20/11 | WF-02 `CxLUUmLpj3mA0nfz` | Teto de 20 aprovações por dia (`p_limit` 50 → 20), versão `faa158e7`. Autorizado por Anderson. |
| 20/11 | Banco | Lote do export de conexões (Connections.csv de 19/11): 36 ICP + Ari de Sá Neto aprovados. Onda 1 (12) cadastrada em 20/11; ondas 2 (20) e 3 (5, depois 6) prontas nos workflows inativos `cyeA1JATMy5oEVXM` e `CPL1RObZ6u9MUklc`, para rodar seg 23/11 e ter 24/11 após 9h. Origem `outro_confirmado_manualmente`, workflow `LOTE-EXPORT-2026-11`. Os arquivos do export não foram versionados (dados pessoais). |
| 20/11 | Banco | Narda Helena Jorosky cadastrada manualmente (REVISAR → ICP, autorizado). |
| 20/11 | WF-01E `KMD9YouA1Un7Y68H` | Regra de ICP ajustada, autorizada por Anderson (versão `70b397de`; anterior `1556abae`). (1) "Direção" / "Direção Geral" como substantivo conta como decisor (antes só "diretor/diretora"); "assistente/secretária/apoio de direção" continua fora. (2) Corrigido falso positivo: "Associação" era lido como "sócia"; agora "sócio/sócia" só como palavra inteira. (3) "Coordenação geral" em escola vai para REVISAR (pode ser quem decide), não mais FORA_ICP; demais coordenações continuam fora. Teste simulado (execução 1289, sem gravar): Direção Geral → ICP, Coordenador geral → REVISAR, Professora \| Associação → FORA_ICP. Webhook segue 403 sem token e com token errado. |
| 20/11 | Lote | Onda 3 passou de 5 para 6 contatos: uma coordenadora geral de colégio incluída a pedido de Anderson. Testado no Postgres local (saudação "Olá/Obrigado", idempotente) e gravado no workflow inativo `CPL1RObZ6u9MUklc`; roda ter 24/11 após 9h. |
| 21/11 | WF-02 `CxLUUmLpj3mA0nfz` | Regra de volume decidida por Anderson: **o D+1 manda**, 20/dia é só referência (sobe para 30 se estourar com frequência). `p_limit` 20 → 100 (trava contra enxurrada por erro). Versão `9baf1a46` (anterior `faa158e7`, backup em `n8n/backups/2026-11-21/`). Consulta testada no Postgres local com o papel do app. Fila real em 21/11 ~12h: 28 contatos vencem seg 23/11 9h (12 da onda 1, Maycon, Sylvio, os 6 aceites de 20/11, Narda e 8 aceites novos de 20 e 21/11), todos saem no D+1. |
| 21/11 | WF-90 `hIDAtmpRUxOIEVGM` (novo, **inativo**) | Vigia: relatório 8h40 (sempre), checagem 15h (só com falha) e alerta imediato de erro dos workflows da cadência. Somente leitura no banco; sem Telegram Trigger. Testado com Telegram simulado (execuções 2060, 2061, 2064). Ativação prevista depois da execução real das 9h de seg 23/11, com autorização. Ver `n8n/vigia/README.md`. |
| 23/11 | WF-NOTIFY `xmshrOsfUkWSBfnG` (**publicado 23/11 21h**, versão `d059f377`, autorizado por Anderson) | Mensagem de entrega dentro de bloco `<pre>`: um toque no Telegram copia o texto inteiro, sem selecionar. Pedido do Anderson para valer a partir de 24/11. Testado com pin data (execução 4844, escape de `< > &` ok). Publicado = `0da7e069`; backup do nó alterado em `n8n/backups/2026-11-23/`. |
| 23/11 | Lote | WF-02 das 9h liberou 39 aprovações (primeira execução sem teto de 20). Onda 2 cadastrada às 10h01 (execução 4894): 20 contatos `AGUARDANDO_D1`, nenhum já existente; saem ter 24/11 9h. |
| 23/11 | WF-90 `hIDAtmpRUxOIEVGM` (inativo) | Painel diário aprovado por Anderson: 18h fechamento (enviados, descartados, respostas, pendências, amanhã) e 8h40 com ontem, semana e taxa de resposta. Fonte: histórico de status. Testado (execução 4905). |

## Detalhes

### WF-05 Follow-up `W36Y8pew9wwaCb6d` (publicado em 20/11)

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

Ordem de publicação executada:
1. Aplicar 015 no DEV (credencial DDL, que precisa de `SET LOCAL ROLE n8n_rufino_linkedin_owner_dev` dentro da transação; a primeira tentativa sem isso falhou com "permission denied for schema" e não alterou nada) e conferir md5 de claim_due_followups = `233dab2a9c192afcc9c6581de3a19820`.
2. Publicar o WF-05.
3. Arquivar o workflow temporário `99 - TEMP Preview Lembrete Follow-up` (`NqOUs9ddhl32xcpB`).

Efeito esperado: na primeira execução (dia útil, 9h) sai o lembrete do follow-up vencido do Leandro (agendado para 14/11) e, se já vencido, o do "TESTE SINTETICO WF-ROUTER" (22/11).
