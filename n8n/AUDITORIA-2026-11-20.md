# Auditoria final: LinkedIn Leads (20/11/2026, ~15h30 Brasília)

Escopo: Gmail → Apps Script `Linkedin | Leads` → n8n DEV → PostgreSQL DEV (`rufino_linkedin`) → Telegram,
incluindo a correção do WF-05. Auditoria somente leitura: nenhum workflow publicado foi alterado, nenhum
registro real foi modificado e nenhuma mensagem comercial foi enviada.

Única escrita na instância: o texto da consulta do workflow utilitário `99 - TEMP Manual SQL` (inativo),
trocado por SELECTs de leitura. Duas consultas falharam sem efeito (permissão de SELECT em
`operational_config`, que o app de fato não tem).

Classificação: **VALIDADO** = evidência direta · **PENDENTE** = depende de evento real futuro · **FALHOU** = problema comprovado.

## Resultado por componente

| # | Componente | Status | Evidência |
|---|---|---|---|
| 1 | WF-01E (intake e-mail) | VALIDADO | Ativo; versão publicada `1556abae` = última versão (sem rascunho pendente). Execução real 1025: 7 `register_connection` sem erro. Nenhum erro desde então. |
| 1 | WF-02 (D+1) | VALIDADO (config) / PENDENTE (execução) | Ativo, versão `cf84cb3a` publicada = atual. Dias úteis 9h, fuso America/Sao_Paulo, checagem de feriado. Primeira execução real com a cadência nova: 23/11 9h. |
| 1 | WF-05 (follow-up) | VALIDADO (config) / PENDENTE (execução) | Ativo, `9ea9444c` publicada = atual; backup `475aafa8` no histórico e em `n8n/backups/2026-11-20/`. Sem Telegram Trigger. |
| 1 | WF-NOTIFY | VALIDADO | Ativo, `0da7e069` = atual. Roda a cada minuto, execuções recentes com sucesso. Nenhum job PENDING/CLAIMED preso. |
| 1 | WF-ROUTER | VALIDADO | Ativo, `87f4d477` = atual, não alterado. Único Telegram Trigger ativo da instância. Toque real às 15:10 (execução 1047) processado; 5 cenários simulados roteados certo. |
| 1 | Conflito de webhook Telegram | VALIDADO | Só o WF-ROUTER tem Telegram Trigger ativo. WF-03, WF-04 e `TEST - Capturar Chat ID` têm trigger próprio mas estão **inativos** (risco documentado: nunca ativá-los). |
| 2 | Migração 014 | VALIDADO | `register_connection` md5 `ee3a839b…` (= repositório). CHECK de origem inclui `linkedin_email_notificacao_aceite`. Usada com sucesso pelo WF-01E. |
| 2 | Migração 015 | VALIDADO | `claim_due_followups` md5 `233dab2a…` (= repositório e teste local). Assinatura igual à chamada do WF-05. |
| 2 | Funções x repositório | VALIDADO | As 25 funções do schema no DEV têm md5 idêntico ao banco local montado só com as migrações do repositório. |
| 2 | Permissões | VALIDADO | App (`n8n_rufino_linkedin_dev`) só tem SELECT nas tabelas; escreve só por funções SECURITY DEFINER. PUBLIC não executa nenhuma função. Funções internas (`transition_connection_status`, `issue_action_token`, `create_notification_job`, `normalize_*`) negadas ao app. |
| 3 | 7 aceites ICP | VALIDADO | Todos `AGUARDANDO_D1`, origem `linkedin_email_notificacao_aceite`, confirmado por `sistema:email-linkedin`, 1 versão de mensagem cada, saudação certa (Olá/Obrigado: Regiane, Kerena; Fala/Valeu: demais). Agenda: Nagib, Regiane, Rodrigo, Walid, Kerena = 23/11 9h; Maycon, Sylvio = 20/11 9h (feriado), saem 23/11 9h. |
| 4 | Deduplicação | VALIDADO | Nenhuma URL nem nome duplicado em `connections`. Índice único em `idempotency_key`; WF-01E checa URL existente; Apps Script rotula o e-mail processado. |
| 4 | Autenticação do webhook | VALIDADO | Sem cabeçalho → 403; token errado → 403; GET → 404; URL de teste → 404 (testado agora). Header Auth `X-Leads-Token`. |
| 4 | Travas | VALIDADO | `PROCESSAMENTO_REAL = true` (liberado por Anderson em 20/11). `MODO = PRODUCAO` comprovado pelo log "8 aceite(s) enviado(s), 8 conversa(s) rotulada(s)". Registro roda antes da resposta ao script. |
| 4 | Acionador de 10 min do Apps Script | VALIDADO (atualizado 12h31) | Aceite real da Narda Helena Jorosky chegou sozinho: WF-01E execução 1076 às 12h31, classificado REVISAR (cita ensino superior), aviso enviado ao Telegram, e-mail rotulado. Anderson confirmou ICP e o cadastro manual foi feito (execução 1082, `AGUARDANDO_D1`, 23/11 9h, workflow `MANUAL-REVISAR`). |
| 5 | Botões de aprovação/entrega (a:A, a:S, a:B) | VALIDADO | Fluxo real Fanny/Rudney/Bruno em 19/11; cópia limpa + botões confirmados por Anderson. |
| 5 | Botões de follow-up (f:R, f:N) | PENDENTE | Caminho de erro validado com toque real (token falso → aviso ⚠️, nada gravado). Caminho de sucesso só em teste local + simulado; primeiro uso real: lembrete do Leandro em 23/11. |
| 6 | Dias úteis e feriados | VALIDADO (config) / PENDENTE (execução) | WF-02 e WF-05: seg–sex 9h, tabela `Feriados - Rufino LinkedIn`. Teste com a tabela real hoje (20/11, feriado): fluxo parou antes de reivindicar. 23/11 não é feriado. |
| 7 | Backups e rollback | VALIDADO | Backup WF-05 (JSON + histórico n8n). Rollbacks 006 (014) e 007 (015) testados localmente, restauram md5 original. |
| 7 | Código versionado x publicado | FALHOU (parcial, não bloqueante) | Banco: 100% igual. WF-01E: igual em lógica; a ordem dos ramos dependia da posição no canvas e o código versionado deixava a resposta antes do registro (corrigido no repositório nesta auditoria, sem tocar o n8n). WF-ROUTER, WF-NOTIFY, WF-02 e WF-05 publicados **não têm export atualizado no repositório**; `gate4/workflows/dev/` contém versões antigas (WF-03/04/05 com Telegram Trigger próprio). Rastreabilidade hoje = histórico de versões do n8n (IDs neste documento). |
| 8 | Contato sintético | PENDENTE (ação na segunda) | `TESTE SINTETICO WF-ROUTER` em FOLLOWUP_PENDENTE, follow-up vence 22/11 → gera 1 lembrete em 23/11 9h. Tocar "Respondeu" para encerrar. |
| 8 | Lembretes antigos | VALIDADO | Leandro: follow-up real vencido desde 14/11 → 1 lembrete em 23/11 (legítimo). Nenhum job de notificação pendente. |
| 8 | Botões já entregues | PENDENTE (prazo) | Aprovação de Rudney e Bruno e entrega de Fanny valem até **26/11 ~20h50 (Brasília)**. Depois disso o botão falha e não há reenvio automático. |

## Bloqueios reais

Nenhum bloqueio para a operação de 23/11. Pontos que exigem ação humana:

1. **Fanny:** o texto gravado começa com "Fala, Fanny!"; pela regra (mulher → "Olá") corrija ao colar. Marcar como enviada até 26/11.
2. **Rudney e Bruno:** aprovar ou descartar até 26/11.
3. **Contato sintético:** tocar "Respondeu" no lembrete de 23/11.
5. **Exports:** baixar do n8n (menu ⋯ → Download) WF-ROUTER, WF-NOTIFY, WF-02 e WF-05 para `n8n/workflows/` para fechar a rastreabilidade.

## Não é 100%

A operação real de 23/11 9h ainda não aconteceu. Até lá ficam PENDENTES: primeira execução do WF-02 com
a cadência por e-mail, primeiro lembrete real do WF-05, primeiro toque real em "Respondeu"/"Sem resposta",
(o acionador do Apps Script já foi comprovado pelo aceite da Narda).
