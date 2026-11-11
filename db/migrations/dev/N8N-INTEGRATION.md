# N8N-INTEGRATION.md — Contrato congelado do banco para o n8n (v1.5.0)

Este documento é o contrato **congelado** entre o banco PostgreSQL (schema `rufino_linkedin`) e os workflows n8n que o GATE 4 vai construir. Ele existe para que quem implementar os nodes **não precise ler o corpo SQL de nenhuma função** — só este documento. Nenhum node ou workflow foi criado como parte desta entrega; isto é só a especificação do contrato.

Todas as 12 funções abaixo são `SECURITY DEFINER`, chamadas via um único node **Execute Query** cada, sempre com **argumentos nomeados** (`$1`/posicional funciona, mas nomeado evita erro de ordem quando a assinatura crescer). 3 funções adicionais do schema (`transition_connection_status`, `issue_action_token`, `create_notification_job`) são **internas** — nunca chamadas pelo n8n, listadas aqui só para completude (seção final).

## Convenções gerais

- **Tokens em `callback_data` do Telegram** (aprovação, entrega, follow-up) usam o formato compacto `<categoria>:<ação>:<token>` — ver seção "Formato de callback_data" abaixo. O n8n monta e faz o parse desse formato; nenhuma função SQL conhece esse formato, elas só recebem o token puro (a parte depois do segundo `:`).
- **`callback_query_id`** vem sempre do objeto `CallbackQuery` do Telegram (`update.callback_query.id`), nunca gerado pelo n8n.
- **Retry**: todo node que chama uma função de callback (`approve_message`, `mark_message_sent`, `complete_followup`) pode ser reexecutado com segurança passando exatamente o mesmo `callback_query_id` e o mesmo conteúdo — a função devolve o resultado já persistido, mesmo que o token já tenha sido consumido pela primeira chamada. Reexecutar com o mesmo `callback_query_id` e conteúdo **diferente** falha com erro claro (nunca sobrescreve).
- **Erros**: qualquer falha (token inválido/expirado/consumido, callback duplicado com conteúdo diferente, parâmetro obrigatório ausente) vem como exceção SQL — no n8n, isso aparece como falha do node Execute Query. Trate como erro de negócio esperado (responda ao usuário/Telegram apropriadamente) exceto quando a mensagem indicar um bug real de integração (ex.: parâmetro ausente que o node deveria sempre enviar).

## Formato de `callback_data` (máximo 64 bytes do Telegram)

| Prefixo | Significado | Função a chamar |
|---|---|---|
| `a:A:<token>` | Aprovar e preparar | `approve_message` com `p_decision='APROVAR_E_PREPARAR'` |
| `a:E:<token>` | Editar | `approve_message` com `p_decision='EDITAR'` |
| `a:R:<token>` | Refazer | `approve_message` com `p_decision='REFAZER'` |
| `a:D:<token>` | Descartar | `approve_message` com `p_decision='DESCARTAR'` |
| `a:S:<token>` | Marcar enviada | `mark_message_sent` com `p_action='MARCAR_ENVIADA'` |
| `a:B:<token>` | Voltar para edição | `mark_message_sent` com `p_action='VOLTAR_EDITAR'` |
| `f:R:<token>` | Respondeu | `complete_followup` com `p_resultado='RESPONDEU'` |
| `f:N:<token>` | Sem resposta | `complete_followup` com `p_resultado='SEM_RESPOSTA'` |

`<token>` tem sempre 48 caracteres hex minúsculo (24 bytes aleatórios) — o Switch/IF do n8n faz `split(callback_data, ':')` para extrair a categoria (`a`/`f`), a ação (segunda posição) e o token (terceira posição). **Nenhum `connection_id`, `message_version_id`, `followup_id` ou `callback_query_id` trafega dentro de `callback_data`** — todo contexto é resolvido pelo banco a partir do hash do token.

---

## 1. Intake (WF-01)

### `register_connection`

**Finalidade:** registrar uma nova conexão analisada pelo GPT, de forma idempotente.

**Quando chamar:** ao receber o payload do GPT Action (webhook de intake), depois de validar contra `schemas/connection.schema.json`.

**Parâmetros obrigatórios:** `p_idempotency_key`, `p_nome`, `p_primeiro_nome`, `p_profile_url`, `p_data_conexao`, `p_mensagem` (nunca vazia). `p_idempotency_key` é responsabilidade do n8n: derive de forma estável do `connection_id` que o GPT já usa (nunca de texto livre mutável como `resumo`).

**⚠️ Mudança de contrato (migração incremental `012`, "atualização da regra D+1") — 2 parâmetros novos, obrigatórios em tempo de execução:**
- `p_data_conexao_origem` (`text`, `DEFAULT NULL` só por exigência de sintaxe — se vier `NULL` ou fora do enum, a função rejeita com `RAISE EXCEPTION`). Valores aceitos: `'linkedin_mynetwork_confirmacao_manual'` (data lida visualmente em `linkedin.com/mynetwork/invite-connect/connections/`) ou `'outro_confirmado_manualmente'`. **Nunca** um valor de origem automatizada/scraping — o enum exclui estruturalmente qualquer coisa que não seja confirmação manual auditável.
- `p_data_conexao_confirmado_por` (`text`, mesma regra de obrigatoriedade em runtime) — identifica quem confirmou visualmente a data (ex.: `'anderson'`).
- Ambos os valores são gravados em `connections.data_conexao_origem`/`connections.data_conexao_confirmado_por` (colunas novas, `NOT NULL`) como trilha de auditoria permanente.
- `p_data_conexao` continua sendo **a data de conexão exibida pelo próprio LinkedIn** — nunca a data de importação nem a data em que alguém confirmou manualmente o fato. O D+1 é calculado a partir dela.
- **Horário operacional configurável:** como o LinkedIn exibe a data sem horário, o horário usado para montar `scheduled_at` não é inventado a partir do aceite — vem de `rufino_linkedin.operational_config` (tabela singleton, hoje `horario_d1='09:00:00'`, `timezone='America/Sao_Paulo'`), lida internamente pela função (`SECURITY DEFINER`); o n8n não precisa (e não deve) passar horário algum.
- Linhas antigas (se existirem) foram marcadas com `data_conexao_origem='legado_sem_origem_registrada'` / `data_conexao_confirmado_por='legado_sem_confirmacao_registrada'` — nunca um valor inventado como se fosse real.
- Rollback dedicado em `rollback/003_d1_rule_update_rollback.sql`, que restaura a assinatura/corpo exatos de antes (20 parâmetros, horário fixo 09:00/America/Sao_Paulo) sem tocar em nenhum outro objeto.

**Retorno:** `connection_id`, `status` (real, persistido — nunca um enum artificial), `scheduled_at`, `message_version_id`, `already_existed` (boolean).

**Retry:** reenviar o mesmo payload com a mesma `idempotency_key` é seguro — devolve o registro existente (`already_existed=true`), nunca duplica.

**Erros esperados:** parâmetro obrigatório ausente/vazio; `p_data_conexao_origem` ausente ou fora do enum; `p_data_conexao_confirmado_por` ausente/vazio.

**Exemplo de chamada (argumentos nomeados, assinatura atual pós-`012`):**
```sql
SELECT * FROM rufino_linkedin.register_connection(
    p_idempotency_key              => $1,
    p_nome                         => $2,
    p_primeiro_nome                => $3,
    p_cargo                        => $4,
    p_instituicao                  => $5,
    p_cidade                       => $6,
    p_profile_url                  => $7,
    p_conversation_url             => $8,
    p_data_conexao                 => $9,
    p_resumo                       => $10,
    p_ganchos                      => $11,
    p_melhor_gancho                => $12,
    p_justificativa                => $13,
    p_confianca                    => $14,
    p_sensivel                     => $15,
    p_alertas                      => $16,
    p_brain_version                => $17,
    p_mensagem                     => $18,
    p_workflow_name                => 'WF-01',
    p_execution_id                 => $19,
    p_data_conexao_origem          => $20,
    p_data_conexao_confirmado_por  => $21
);
```

---

## 2. Scheduler D+1 (WF-02)

### `claim_due_connections`

**Finalidade:** reivindicar, de forma atômica, as conexões cujo D+1 chegou, e enfileirar a notificação de aprovação de cada uma.

**Quando chamar:** no Schedule Trigger do WF-02.

**Parâmetros:** `p_limit` (obrigatório, positivo, máximo 500), `p_workflow_name` (default `'WF-02'`), `p_execution_id`.

**Retorno (uma linha por conexão reivindicada):** `connection_id`, `nome`, `primeiro_nome`, `cargo`, `instituicao`, `cidade`, `profile_url`, `conversation_url`, `status`, `message_version_id`, `message_body`.

**Efeito colateral importante:** cria automaticamente um job de notificação `APPROVAL` no outbox (`notification_jobs`) para cada conexão reivindicada — o n8n **não precisa** (e não deve) montar/enviar a notificação diretamente a partir deste node; isso é feito pelo par `claim_notification_jobs`/`confirm_notification_delivery` (seção 3).

**Retry:** chamar de novo não reivindica a mesma conexão duas vezes (ela já saiu de `AGUARDANDO_D1`).

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.claim_due_connections(
    p_limit         => 50,
    p_workflow_name => 'WF-02',
    p_execution_id  => $1
);
```

---

## 3. Notificação Telegram (aprovação e entrega) — outbox durável

### `claim_notification_jobs`

**Finalidade:** reivindicar jobs de notificação pendentes (ou com claim expirado) e obter tudo que é necessário para montar e enviar a mensagem no Telegram — inclusive o `action_token` bruto, gerado **na hora**.

**Quando chamar:** logo após `claim_due_connections` (jobs `APPROVAL`) ou como um passo periódico/imediato que também pega jobs `DELIVERY` criados por `present_message_for_delivery`. Pode ser um único node reutilizado por WF-02 e WF-04.

**Parâmetros:** `p_limit` (obrigatório, positivo, máximo 200), `p_workflow_name` (default `'WF-NOTIFY'`), `p_execution_id`.

**Retorno (uma linha por job reivindicado):** `notification_job_id`, `job_type` (`'APPROVAL'` ou `'DELIVERY'`), `connection_id`, `message_version_id`, `nome`, `primeiro_nome`, `cargo`, `instituicao`, `cidade`, `profile_url`, `conversation_url`, `message_body`, **`raw_action_token`** (bruto, 48 chars hex — usar para montar `callback_data`, nunca persistir), `action_token_expires_at`, **`raw_claim_token`** (bruto — guardar só para a chamada de `confirm_notification_delivery` logo em seguida, nunca persistir), `claim_expires_at` (15 minutos — enviar ao Telegram e confirmar dentro desse prazo).

**Retry/reclaim:** se o worker cair entre reivindicar e confirmar, o job fica `CLAIMED` até `claim_expires_at` passar, e então volta a ser elegível para outro `claim_notification_jobs` — que gera um **novo** `raw_action_token`/`raw_claim_token` (os antigos deixam de funcionar). Isso pode gerar uma segunda mensagem no Telegram se a primeira efetivamente chegou antes do worker cair — ver nota de entrega duplicada abaixo.

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.claim_notification_jobs(
    p_limit         => 20,
    p_workflow_name => 'WF-NOTIFY',
    p_execution_id  => $1
);
```

Para cada linha retornada, montar a mensagem (usando `job_type` para escolher o template de aprovação ou de entrega) com os botões `a:A:<raw_action_token>`, `a:E:<raw_action_token>`, etc. (mesmo `raw_action_token` em todos os botões da mesma mensagem — só a letra da ação muda).

### `confirm_notification_delivery`

**Finalidade:** registrar que a mensagem foi de fato enviada ao Telegram, fechando o ciclo do outbox.

**Quando chamar:** imediatamente após o node do Telegram (`sendMessage`) responder com sucesso.

**Parâmetros:** `p_claim_token` (o `raw_claim_token` da chamada de `claim_notification_jobs`), `p_telegram_chat_id`, `p_telegram_message_id`, `p_workflow_name`, `p_execution_id`.

**Retorno:** `notification_job_id`, `connection_id`, `job_type`, `delivered_at`.

**Retry:** chamar de novo com o mesmo `p_claim_token` depois de já confirmado é um no-op seguro (devolve o `delivered_at` já registrado). Se o `claim_token` já foi rotacionado por um reclaim (ver acima), a chamada falha com "claim_token inválido" — nesse caso a mensagem enviada por este worker específico é considerada obsoleta (o job já foi/será processado por outro worker).

**Nota sobre entrega duplicada:** o banco garante processamento durável (a intenção de notificar nunca se perde), mas o Telegram **não tem garantia exactly-once** — é possível que o envio remoto realmente ocorra e o n8n caia antes de chamar `confirm_notification_delivery`. Nesse caso um segundo envio (com novo `action_token`) pode acontecer depois do reclaim. Isso é um comportamento aceito por desenho: a primeira mensagem fica com botões mortos (o token antigo nunca mais valida), e os callbacks que chegarem continuam seguros graças à idempotência de `approve_message`/`mark_message_sent`/`complete_followup`.

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.confirm_notification_delivery(
    p_claim_token         => $1,
    p_telegram_chat_id    => $2,
    p_telegram_message_id => $3,
    p_workflow_name       => 'WF-NOTIFY',
    p_execution_id        => $4
);
```

---

## 4. Callback de aprovação (WF-03)

### `approve_message`

**Finalidade:** processar o clique num dos 4 botões de aprovação.

**Quando chamar:** ao receber `callback_query` com `callback_data` prefixado `a:`. **Responda o callback do Telegram (`answerCallbackQuery`) antes de chamar esta função**, para encerrar o spinner do botão sem esperar o resultado da query.

**Parâmetros obrigatórios (todos):** `p_action_token` (extraído do `callback_data`), `p_decision` (`'APROVAR_E_PREPARAR'`, `'EDITAR'`, `'REFAZER'` ou `'DESCARTAR'`, mapeado da letra A/E/R/D), `p_actor` (identificador de quem decidiu), `p_callback_query_id`. Opcionais: `p_workflow_name` (default `'WF-03'`), `p_execution_id`.

**Retorno:** `approval_id`, `connection_id`, `decision`, `new_status`, `raw_edit_token` (só quando `decision='EDITAR'`), `raw_regeneration_token` + `regeneration_token_expires_at` (só quando `decision='REFAZER'`).

**Quando `decision='EDITAR'`:** monte a URL do n8n Form (WF-03-EDIT) com `raw_edit_token` na query string.

**Quando `decision='REFAZER'`:** monte o pacote de contexto enviado ao GPT incluindo `raw_regeneration_token` — o GPT devolve a nova mensagem via WF-03-REGEN (seção 6).

**Retry [v1.5.1]:** reexecutar com o mesmo `callback_query_id` e os mesmos `p_action_token`/`p_decision` é seguro (idempotente quanto a negócio — nunca cria um segundo `approval`, nunca repete a transição de status). **Importante para `EDITAR`/`REFAZER`: o `raw_edit_token`/`raw_regeneration_token` devolvido no retry NUNCA é o mesmo valor da primeira chamada** — o banco nunca persiste token bruto em nenhum lugar (nem em `callback_receipts`), então não há de onde devolver o valor antigo; em vez disso, se a conexão ainda estiver no estado que esperava aquele token (`AGUARDANDO_APROVACAO` para EDITAR, `REFAZER` para REFAZER), o banco emite um token **novo**, válido, e você deve usar esse (não o de uma chamada anterior). Se o fluxo já tiver avançado (ex.: o usuário já usou o link de edição antes do retry chegar), `raw_edit_token`/`raw_regeneration_token` voltam `NULL` — trate isso como "esta ação já não tem mais nada pendente para continuar", não como erro. Mesmo `callback_query_id` com decisão diferente falha claramente.

**Erros esperados:** `action_token inválido` (nunca existiu), `ja consumido` (clique duplicado físico, sem retry de callback_query_id), `expirado`, `callback_query_id já processado com conteúdo diferente` (conflito real).

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.approve_message(
    p_action_token      => $1,
    p_decision          => $2,
    p_actor             => $3,
    p_callback_query_id => $4,
    p_workflow_name     => 'WF-03',
    p_execution_id      => $5
);
```

### `save_message_edit` (WF-03-EDIT)

**Finalidade:** salvar a edição manual feita no Form, criando uma nova versão de mensagem.

**Quando chamar:** ao submeter o n8n Form de edição.

**Parâmetros:** `p_presented_edit_token` (da query string do Form), `p_new_message_body` (não vazio), `p_edited_by`, `p_workflow_name` (default `'WF-03-EDIT'`), `p_execution_id`.

**Retorno:** `connection_id`, `message_version_id`, `version`.

**Efeito colateral:** cria um novo job de notificação `APPROVAL` (a nova versão precisa ser reapresentada) — não retorna token diretamente; o próximo ciclo de `claim_notification_jobs` pega esse job.

**Retry:** o token é de uso único — reenviar o mesmo Form duas vezes falha na segunda ("edit_token inválido, expirado ou já consumido"). Trate isso como "já processado", não como erro de integração.

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.save_message_edit(
    p_presented_edit_token => $1,
    p_new_message_body     => $2,
    p_edited_by             => $3,
    p_workflow_name         => 'WF-03-EDIT',
    p_execution_id          => $4
);
```

---

## 5. Entrega manual assistida (WF-04)

### `present_message_for_delivery`

**Finalidade:** marcar a mensagem aprovada como pronta para entrega, criando o job de notificação `DELIVERY`.

**Quando chamar:** assim que `approve_message` retornar `new_status='APROVADO'`.

**Parâmetros:** `p_connection_id`, `p_message_version_id` (a versão vigente — deve bater exatamente, senão a função rejeita), `p_actor` (default `'sistema'`), `p_workflow_name` (default `'WF-04'`), `p_execution_id`.

**Retorno:** `connection_id`, `status`, `delivery_event_id`.

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.present_message_for_delivery(
    p_connection_id      => $1,
    p_message_version_id => $2,
    p_actor              => 'sistema',
    p_workflow_name      => 'WF-04',
    p_execution_id       => $3
);
```

### `mark_message_sent`

**Finalidade:** processar o clique em "Marcar como enviada" ou "Voltar e editar".

**Quando chamar:** ao receber `callback_query` com `callback_data` prefixado `a:S:` ou `a:B:`. Responda `answerCallbackQuery` antes de chamar.

**Parâmetros obrigatórios:** `p_action_token`, `p_action` (`'MARCAR_ENVIADA'` ou `'VOLTAR_EDITAR'`), `p_actor`, `p_callback_query_id`. **`p_first_followup_at` é obrigatório e precisa ser uma data/hora futura quando `p_action='MARCAR_ENVIADA'`** (calculada pelo n8n — o banco nunca inventa a cadência de follow-up). Opcionais: `p_workflow_name` (default `'WF-04'`), `p_execution_id`.

**Retorno:** `delivery_event_id`, `connection_id`, `new_status`, `followup_id` (preenchido só quando `MARCAR_ENVIADA`; `VOLTAR_EDITAR` nunca cria follow-up).

**Retry [v1.5.1]:** mesma disciplina de `approve_message` — mesmo `callback_query_id` + mesmo conteúdo é idempotente (devolve o mesmo `followup_id`, sem duplicar). **Isso vale mesmo que `p_first_followup_at` já tenha passado no momento do retry** (ex.: reentrega do Telegram que chega atrasada) — a checagem de "precisa ser uma data futura" só se aplica à primeira chamada; um retry reconhecido por `callback_query_id`+conteúdo idêntico nunca é rejeitado por essa checagem. Reenvie sempre o **mesmo** valor de `p_first_followup_at` que você calculou e enviou na primeira tentativa — um valor recalculado (ex.: `now() + intervalo` reavaliado na hora do retry) muda o conteúdo e é tratado como conflito, não como retry.

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.mark_message_sent(
    p_action_token       => $1,
    p_action             => $2,
    p_actor              => $3,
    p_callback_query_id  => $4,
    p_first_followup_at  => $5,
    p_workflow_name      => 'WF-04',
    p_execution_id       => $6
);
```

---

## 6. Regeneração (WF-03-REGEN)

### `save_regenerated_message`

**Finalidade:** receber a nova mensagem que o GPT gerou depois de uma decisão `REFAZER`.

**Quando chamar:** no webhook/GPT Action que recebe a resposta do GPT, validado contra `schemas/regeneration_request.schema.json`.

**Parâmetros:** `p_presented_regeneration_token` (do payload do GPT), `p_new_message_body` (não vazio), `p_actor` (default `'gpt'`), `p_workflow_name` (default `'WF-03-REGEN'`), `p_execution_id`.

**Retorno:** `connection_id`, `message_version_id`, `version`.

**Efeito colateral:** cria um novo job de notificação `APPROVAL` para a nova versão.

**Retry:** token de uso único — reenvio falha na segunda ("regeneration_token inválido, expirado ou já consumido"); trate como já processado.

**Erros esperados:** token inválido/expirado/consumido; status atual diferente de `REFAZER` (a conexão já saiu desse estado por outro caminho).

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.save_regenerated_message(
    p_presented_regeneration_token => $1,
    p_new_message_body             => $2,
    p_actor                        => 'gpt',
    p_workflow_name                => 'WF-03-REGEN',
    p_execution_id                 => $3
);
```

---

## 7. Follow-up (WF-05)

### `claim_due_followups`

**Finalidade:** reivindicar follow-ups vencidos (ou com claim expirado), com posse explícita via token.

**Quando chamar:** no Schedule Trigger do WF-05.

**Parâmetros:** `p_limit` (obrigatório, positivo, máximo 500), `p_workflow_name` (default `'WF-05'`), `p_execution_id`.

**Retorno (uma linha por follow-up reivindicado):** `followup_id`, `connection_id`, `sequence`, `scheduled_for`, `raw_claim_token` (bruto, 48 chars hex — guardar para `complete_followup`), `claim_expires_at` (1 hora).

**Retry/reclaim:** se o worker cair antes de concluir, o follow-up volta a ser elegível depois de `claim_expires_at` — reivindicado de novo por outra execução, com um **novo** `raw_claim_token` (o antigo deixa de funcionar). Um follow-up já concluído nunca volta a ser reivindicado.

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.claim_due_followups(
    p_limit         => 50,
    p_workflow_name => 'WF-05',
    p_execution_id  => $1
);
```

### `complete_followup`

**Finalidade:** processar o resultado do follow-up (resposta obtida manualmente por Anderson, ou callback `f:R:`/`f:N:` se o canal permitir clique direto).

**Quando chamar:** depois de `claim_due_followups`, ao registrar o resultado.

**Parâmetros obrigatórios:** `p_claim_token` (da chamada de `claim_due_followups`), `p_resultado` (`'RESPONDEU'` ou `'SEM_RESPOSTA'`), `p_actor`, `p_callback_query_id`. Opcionais: `p_notes`, `p_next_followup_at` (só relevante com `SEM_RESPOSTA` — data futura calculada pelo n8n; se ausente, a jornada se encerra), `p_workflow_name` (default `'WF-05'`), `p_execution_id`.

**Retorno:** `followup_id`, `connection_id`, `resultado`, `new_connection_status`, `next_followup_id`/`next_followup_sequence`/`next_followup_scheduled_for` (preenchidos só quando um próximo follow-up foi criado).

**Comportamento:** `RESPONDEU` sempre encerra a jornada (nunca cria próximo follow-up). `SEM_RESPOSTA` com `p_next_followup_at` cria o próximo ciclo (volta a `FOLLOWUP_PENDENTE`, reivindicável de novo por `claim_due_followups` quando chegar a hora). `SEM_RESPOSTA` sem `p_next_followup_at` encerra a jornada.

**Retry [v1.5.1]:** mesmo `callback_query_id` + mesmo conteúdo é idempotente, mesmo com o `claim_token` já invalidado pela primeira chamada. **Isso vale mesmo que `p_next_followup_at` já tenha passado no momento do retry** — a checagem de "precisa ser uma data futura" só se aplica à primeira chamada. Reenvie sempre o **mesmo** valor de `p_next_followup_at` da primeira tentativa (um valor recalculado muda o conteúdo e é tratado como conflito).

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.complete_followup(
    p_claim_token       => $1,
    p_resultado         => $2,
    p_actor             => $3,
    p_callback_query_id => $4,
    p_notes             => $5,
    p_next_followup_at  => $6,
    p_workflow_name     => 'WF-05',
    p_execution_id      => $7
);
```

---

## 8. Registro de erro (WF-90)

### `record_workflow_error`

**Finalidade:** registrar uma falha não tratada de qualquer workflow, com auditoria preservada mesmo se a transição para `ERRO` falhar.

**Quando chamar:** no Error Trigger do WF-90 (Error Workflow nativo do n8n, configurado nas settings de cada workflow).

**Parâmetros:** `p_connection_id` (nullable), `p_source_workflow`, `p_error_type`, `p_error_message` (todos obrigatórios exceto `p_connection_id`), `p_context` (jsonb, nunca com segredo), `p_previous_status`, `p_recommended_resume_status`, `p_retry_limit` (default 3, deve ser positivo), `p_execution_id` (recomendado sempre informar — habilita a deduplicação por execução).

**Retorno:** `workflow_error_id`, `transitioned_to_erro` (boolean), `transition_error` (texto do erro da transição, se ela falhou), `current_status` (status real relido do banco), `retry_count`, `retry_limit`, `retry_allowed`.

**Retry:** chamar de novo com o **mesmo `p_execution_id`** para o mesmo erro é idempotente — devolve o registro já existente, sem duplicar nem recontar `retry_count`.

**Retomada de `ERRO`:** sempre manual/administrativa (ver `MANUAL-STEPS.md`) — nenhum workflow deve tentar tirar uma conexão de `ERRO` sozinho.

**Exemplo:**
```sql
SELECT * FROM rufino_linkedin.record_workflow_error(
    p_connection_id             => $1,
    p_source_workflow           => $2,
    p_error_type                => $3,
    p_error_message             => $4,
    p_context                   => $5,
    p_previous_status           => $6,
    p_recommended_resume_status => $7,
    p_retry_limit               => 3,
    p_execution_id              => $8
);
```

---

## Funções internas (nunca chamar diretamente do n8n)

| Função | Por quê é interna |
|---|---|
| `transition_connection_status` | Núcleo da máquina de estados — só validada e chamada pelas 12 funções acima, que já aplicam as regras de negócio (token, callback, decisão) antes de transicionar. Retomada manual de `ERRO` é a única exceção, e mesmo essa exige uma sessão administrativa assumindo a role owner (`SET ROLE`), nunca a credencial do n8n. |
| `issue_action_token` | Gera/rotaciona o token de aprovação/entrega — só chamada por `claim_notification_jobs`, no momento exato em que o token vai ser usado. |
| `create_notification_job` | Cria/supera jobs no outbox — só chamada por `claim_due_connections`, `present_message_for_delivery`, `save_message_edit`, `save_regenerated_message` e `mark_message_sent` (ramo `VOLTAR_EDITAR`). |

Chamar qualquer uma das três diretamente com a credencial do n8n falha com `insufficient_privilege` (confirmado em `009_smoke_tests.sql`, itens 31 e 32).

---

---

## Adendo pré-conexão (ver ADDENDUM-prospecting-pre-connection-SPEC.md, commit df95326)

Cobre a etapa **anterior** ao aceite da conexão: `IDENTIFICADO → QUALIFICADO → CONVITE_PENDENTE → CONECTADO → ENCERRADO`. Nenhuma das 15 funções acima mudou de assinatura, retorno ou comportamento nesta rodada.

### `register_prospect`
Cadastra/reaproveita um perfil identificado (dedupe por URL canônica — `p_linkedin_profile_url` normalizado via `normalize_linkedin_url`, interna). Resolve/cria a escola sem fundir por nome quando a cidade é desconhecida. Se já existir uma `connections` row com a mesma URL canônica, o prospect nasce direto em `CONECTADO` (vínculo idempotente automático). Parâmetros: `p_linkedin_profile_url, p_nome, p_primeiro_nome, p_cargo_atual, p_cidade, p_escola_nome, p_rede, p_unidade, p_origem, p_workflow_name, p_execution_id`. Retorna `prospect_id, status, school_id, connection_id, already_existed`.

### `qualify_prospect`
`IDENTIFICADO → QUALIFICADO`. Exige `p_icp_tier IN ('P1','P2','P3')`; rejeita se o prospect não estiver em `IDENTIFICADO`. Parâmetros: `p_prospect_id, p_icp_tier, p_vinculo_decisorio, p_justificativa, p_actor, p_workflow_name, p_execution_id`.

### `get_daily_prospect_queue`
Só leitura. Lista prospects `QUALIFICADO`, ordenados por `icp_tier, created_at`, **nunca mais de 20** mesmo que `p_limit` seja maior (teto aplicado dentro da função). Não transiciona nada. Parâmetros: `p_limit DEFAULT 20, p_workflow_name, p_execution_id`.

### `mark_invite_sent`
`QUALIFICADO → CONVITE_PENDENTE`. Registra um convite **já enviado manualmente** no LinkedIn — não envia nada. Idempotente: segunda chamada no mesmo prospect devolve `already_sent=true` sem reescrever o timestamp nem duplicar evento. Parâmetros: `p_prospect_id, p_actor, p_workflow_name, p_execution_id`.

### `confirm_invite_accepted`
`CONVITE_PENDENTE → CONECTADO`. **Ponto de entrada da cadência pós-aceite já existente** — depois desta chamada, a pessoa está pronta para o fluxo normal do GPT/WF-01 (register_connection), com `p_data_aceite` correspondendo ao que seria `data_conexao`. Idempotente. Parâmetros: `p_prospect_id, p_data_aceite, p_actor, p_workflow_name, p_execution_id`.

### `close_prospect`
Qualquer estado → `ENCERRADO`, com `p_motivo IN ('RECUSADO','SEM_RESPOSTA_PROSPECCAO','DUPLICADO','FORA_DO_ICP','OUTRO')`. Idempotente com o mesmo motivo; rejeita reescrever com motivo diferente. Parâmetros: `p_prospect_id, p_motivo, p_actor, p_workflow_name, p_execution_id`.

### `link_prospect_to_connection`
Reconciliação no sentido inverso de `register_prospect`: chamar depois que `register_connection` (WF-01, inalterado) gravar uma conexão nova, para vincular de volta ao prospect que a originou (mesma URL canônica). **Nenhum workflow chama isto automaticamente ainda** — é um node Postgres a acrescentar ao WF-01 quando autorizado, ou uma reconciliação manual/periódica enquanto isso não acontece. Idempotente; rejeita com erro claro se o prospect já estiver vinculado a uma `connection_id` diferente (nunca sobrescreve). Parâmetros: `p_connection_id, p_workflow_name, p_execution_id`. Retorna `prospect_id, linked, previous_status, new_status` (`linked=false` e os demais `NULL` quando a conexão não tem prospect correspondente — caso normal para conexões fora do funil de prospecção).

### Internas do adendo (nunca chamadas pelo n8n)

| Função | Por quê é interna |
|---|---|
| `normalize_linkedin_url` | Normalização pura da URL (lower, sem www/esquema/query/barra final) — usada pelas funções acima para comparar `prospects`/`connections` na mesma forma. |
| `normalize_school_name` | Normalização pura de nome/cidade de escola (lower, espaços colapsados) para a resolução de `schools`. |

---

## Contagem final (derivada do SQL, `006_functions.sql`)

**24 funções totais** no schema `rufino_linkedin` — **19 executáveis pela role de aplicação** (12 da jornada pós-aceite + 7 do adendo pré-conexão), **5 internas** (3 da jornada pós-aceite + 2 do adendo). **14 tabelas** (11 pós-aceite + 3 do adendo: `schools`, `prospects`, `prospect_events`). Nenhuma das 24 funções tem `EXECUTE` concedido a `PUBLIC`.

Este é o contrato congelado do banco — qualquer mudança de assinatura, retorno ou comportamento aqui documentado exige nova revisão, não deve ser feita silenciosamente durante a construção dos workflows.
