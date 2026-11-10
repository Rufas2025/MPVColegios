# ADENDO — Prospecção pré-conexão (GATE 1, desenho) — Rufino LinkedIn Intelligence

**Status:** especificação aprovada para desenho (GATE 1). **Nenhum SQL gerado ou executado. Nenhum workflow alterado. Nenhum convite ou mensagem enviado.** Este documento é o menor adendo de schema/regra de negócio necessário para cobrir a etapa anterior ao aceite da conexão, reaproveitando integralmente o banco, as funções e os workflows já existentes (v1.6.0) — nenhuma arquitetura nova.

**Nota operacional:** este container reiniciou desde a rodada do GATE 4 nesta mesma conversa; a instalação local da skill (`/root/.claude/skills/rufino-linkedin-n8n-ops`, v1.6.0) não está presente neste filesystem — só uma cópia sincronizada e desatualizada (v1.3.6) existe aqui. O repositório Git (`gate4/workflows/dev/`, `db/migrations/dev/`) persistiu normalmente e foi usado como fonte de verdade real para este adendo (11 tabelas, 15 funções, enum de status, convenções de hardening — todos confirmados lendo `db/migrations/dev/003_tables.sql`/`004_constraints_and_indexes.sql`/`006_functions.sql` nesta sessão, não de memória). A reinstalação da skill v1.6.0 completa neste container fica pendente — recomendo tratá-la à parte, fora do escopo deste adendo.

## 1. O que já existe e não muda

- Schema `rufino_linkedin`, 11 tabelas, 15 funções `SECURITY DEFINER` (12 públicas, 3 internas), contrato congelado em `db/migrations/dev/N8N-INTEGRATION.md`.
- `connections.status` cobre exclusivamente a jornada **pós-aceite**: `NOVO, AGUARDANDO_ANALISE, AGUARDANDO_D1, AGUARDANDO_APROVACAO, APROVADO, REFAZER, DESCARTADO, PRONTO_PARA_ENVIO, ENVIADO, RESPONDEU, SEM_RESPOSTA, FOLLOWUP_PENDENTE, ENCERRADO, ERRO`.
- `connections.data_conexao` já é `NOT NULL` — ou seja, hoje é estruturalmente impossível registrar alguém em `connections` antes do aceite acontecer. Esse é exatamente o vão que este adendo cobre, **sem alterar `connections`**.
- Os 9 workflows do GATE 4 (WF-01 a WF-05, WF-03-EDIT, WF-03-REGEN, WF-90, WF-NOTIFY) continuam intocados.

## 2. Novo conceito: `prospects` (pré-conexão)

Uma pessoa identificada antes do aceite nunca é gravada em `connections`. Ela vive em duas tabelas novas, no mesmo schema `rufino_linkedin`, seguindo a mesma convenção de hardening das 11 existentes (RLS como defesa adicional, zero escrita direta pela role do n8n, só as funções abaixo escrevem).

### 2.1 `rufino_linkedin.prospects`

| Coluna | Tipo | Regra |
|---|---|---|
| `prospect_id` | `uuid` PK | `gen_random_uuid()` |
| `linkedin_profile_url` | `text` NOT NULL | **chave de dedupe** — normalizada (minúsculas, sem barra final, sem query string) antes de qualquer escrita; `UNIQUE` |
| `nome`, `primeiro_nome` | `text` NOT NULL | igual ao padrão de `connections` |
| `cargo_atual` | `text` | nullable — campo "pendente de validação" quando não houver dado suficiente (nunca inventado) |
| `cidade` | `text` | nullable, mesma regra |
| `vinculo_decisorio` | `text` | nullable — texto curto de justificativa (ex.: "CEO, decisor financeiro") |
| `icp_tier` | `text` | nullable até qualificar; `CHECK (icp_tier IN ('P1','P2','P3'))` |
| `school_id` | `uuid` | FK → `schools.school_id`, nullable até resolvido |
| `status` | `text` NOT NULL | `CHECK (status IN ('IDENTIFICADO','QUALIFICADO','CONVITE_PENDENTE','CONECTADO','ENCERRADO'))` |
| `origem` | `text` NOT NULL | ex.: `'icp_reference_manual'`, `'composio_pendente_validacao'`, `'looper_pendente_validacao'`, `'manual_anderson'` |
| `convite_enviado_em` | `timestamptz` | nullable, setado só por `mark_invite_sent` |
| `convite_aceito_em` | `timestamptz` | nullable, setado só por `confirm_invite_accepted` |
| `motivo_encerramento` | `text` | nullable; `CHECK (motivo_encerramento IN ('RECUSADO','SEM_RESPOSTA_PROSPECCAO','DUPLICADO','FORA_DO_ICP','OUTRO'))` quando `status='ENCERRADO'` |
| `connection_id` | `uuid` | FK → `connections.connection_id`, nullable — só preenchido depois que a jornada pós-aceite (WF-01) registrar essa mesma pessoa (ver §5) |
| `lock_version` | `integer` NOT NULL DEFAULT 0 | concorrência otimista, mesmo padrão de `connections` |
| `created_at`, `updated_at` | `timestamptz` | padrão |

### 2.2 `rufino_linkedin.schools` (resolve "vincular sem duplicar")

| Coluna | Tipo | Regra |
|---|---|---|
| `school_id` | `uuid` PK | |
| `nome` | `text` NOT NULL | como informado |
| `nome_normalizado` | `text` NOT NULL | minúsculas, sem acento, espaços colapsados — `UNIQUE`; é a chave real de dedupe |
| `rede` | `text` | nullable — nome da rede/mantenedora, quando aplicável |
| `created_at`, `updated_at` | `timestamptz` | padrão |

`register_prospect` (abaixo) resolve `school_id` por `nome_normalizado`: se já existe, reusa; se não, cria — nunca duplica uma escola por causa de capitalização/acentuação diferente.

### 2.3 `rufino_linkedin.prospect_events` (histórico, espelha `connection_status_history`)

| Coluna | Tipo |
|---|---|
| `prospect_event_id` | `uuid` PK |
| `prospect_id` | `uuid` FK NOT NULL |
| `event_type` | `text` NOT NULL — `IDENTIFICADO`/`QUALIFICADO`/`CONVITE_ENVIADO`/`CONVITE_ACEITO`/`ENCERRADO`/`ERRO` |
| `detalhe` | `jsonb` | contexto não sensível (nunca token/segredo) |
| `actor` | `text` NOT NULL | quem/o que disparou (`'anderson'`, `'sistema'`, `'composio:<fonte>'`, `'looper:<fonte>'`) |
| `source_workflow`, `execution_id` | `text` | mesma disciplina de auditoria das 15 funções existentes |
| `created_at` | `timestamptz` | |

## 3. Extensão mínima fora de `prospects`/`schools`

- **Reaproveitar o outbox existente**, não criar um novo: `notification_jobs.job_type` ganha um terceiro valor possível, `'PROSPECT_QUEUE'`, ao lado de `'APPROVAL'`/`'DELIVERY'` já existentes — uma única mudança de `CHECK constraint`, zero tabela nova, zero workflow novo. A fila diária (§4) é publicada nesse outbox e consumida pelo **mesmo** `WF-NOTIFY` já existente, com uma terceira rota no `switch` (hoje tem 2 saídas, passaria a ter 3) — mudança de workflow fica para quando isso for autorizado a ser implementado, não agora.
- **Métrica de "reuniões" no relatório diário (item 8):** não existe hoje nenhum conceito de reunião no schema. Menor adendo possível: uma única coluna nullable, `connections.reuniao_agendada_em timestamptz`, preenchida manualmente por Anderson (via Telegram ou direto no banco) — nunca inferida automaticamente. Alternativa avaliada e descartada: tabela `meetings` nova — rejeitada por violar "menor adendo possível" quando um campo nullable já basta para o relatório pedido.

## 4. Funções novas (mesma convenção das 15 existentes — `SECURITY DEFINER`, `search_path` qualificado, nomes qualificados, `REVOKE EXECUTE FROM PUBLIC` + `GRANT` só para a role de aplicação, zero SQL dinâmico, chamadas via um único node Execute Query cada)

1. **`register_prospect(p_linkedin_profile_url, p_nome, p_primeiro_nome, p_cargo_atual, p_cidade, p_escola_nome, p_rede, p_origem, p_workflow_name, p_execution_id)`**
   Normaliza a URL; `INSERT ... ON CONFLICT (linkedin_profile_url) DO NOTHING` (idêntico ao padrão de `register_connection`); resolve/cria `schools` por `nome_normalizado`; grava evento `IDENTIFICADO`. Retorna `prospect_id`, `status`, `school_id`, `already_existed`. **Nunca** aceita `cargo_atual`/`cidade` quando a chamada não tiver esse dado — nulo fica nulo, nunca inventado.

2. **`qualify_prospect(p_prospect_id, p_icp_tier, p_vinculo_decisorio, p_justificativa, p_actor, p_workflow_name, p_execution_id)`**
   Exige `status='IDENTIFICADO'` (rejeita se já qualificado/encerrado, evitando reclassificação acidental); valida `icp_tier IN ('P1','P2','P3')`; transiciona para `QUALIFICADO`; grava evento com a justificativa em `detalhe`.

3. **`get_daily_prospect_queue(p_limit, p_workflow_name, p_execution_id)`** — **somente leitura, não escreve nada**
   `SELECT` em `prospects` com `status='QUALIFICADO'`, ordenado por `icp_tier, created_at`, limitado a `LEAST(p_limit, 20)` — o teto de 20 é aplicado **dentro da função**, não confiado ao chamador. Não transiciona status, não marca nada como enviado — é só a lista de candidatos do dia. **Não presume que os 20 podem ser enviados** — a decisão de quantos convites de fato enviar, dentro dos limites reais do LinkedIn, é 100% humana (Anderson), fora desta função.

4. **`mark_invite_sent(p_prospect_id, p_actor, p_workflow_name, p_execution_id)`**
   Exige `status='QUALIFICADO'` (idempotente: se já `CONVITE_PENDENTE`, retorna o estado atual com `already_sent=true` em vez de erro — protege contra duplo clique/retry); transiciona para `CONVITE_PENDENTE`; grava `convite_enviado_em=now()`; evento `CONVITE_ENVIADO`. Esta função só registra um convite que **Anderson já enviou manualmente dentro do LinkedIn** — ela não envia nada.

5. **`confirm_invite_accepted(p_prospect_id, p_data_aceite, p_actor, p_workflow_name, p_execution_id)`**
   Exige `status='CONVITE_PENDENTE'` (rejeita fora de ordem — não dá para aceitar um convite que não foi marcado como enviado); transiciona para `CONECTADO`; grava `convite_aceito_em`; evento `CONVITE_ACEITO`. **Este é o ponto de entrada da cadência existente** (§5) — mas a função em si não chama `register_connection`; só sinaliza que a pessoa está pronta para a jornada pós-aceite.

6. **`close_prospect(p_prospect_id, p_motivo, p_actor, p_workflow_name, p_execution_id)`**
   De qualquer estado para `ENCERRADO`; exige `p_motivo` em `('RECUSADO','SEM_RESPOSTA_PROSPECCAO','DUPLICADO','FORA_DO_ICP','OUTRO')`; idempotente (`ENCERRADO→ENCERRADO` com o mesmo motivo é no-op, motivo diferente é rejeitado — nunca reescreve silenciosamente a razão de encerramento).

**Deliberadamente fora do escopo deste adendo** (fica para quando a implementação for autorizada): a função de conveniência que vincularia `prospects.connection_id` automaticamente quando o WF-01 registrar a conexão — hoje a chave de idempotência de `register_connection` é o `connection_id` que o GPT escolhe, não a URL do perfil, então esse vínculo exige uma pequena consulta por `profile_url`, não uma mudança de contrato de `register_connection`. Registrado aqui como item pendente, não bloqueante.

## 5. Como a cadência existente é acionada (item 7)

Sem alterar `WF-01`: quando `confirm_invite_accepted` grava `CONECTADO`, isso é o sinal (hoje, uma notificação manual/Telegram; no futuro, uma nova rota do outbox) de que o GPT Rufino LinkedIn Intelligence pode analisar o perfil agora que a conexão foi aceita e produzir o payload completo de intake — exatamente o mesmo contrato (`schemas/connection.schema.json`) que `WF-01` já espera, com `data_conexao = convite_aceito_em`. A partir daí, **toda a jornada pós-aceite roda exatamente como está hoje**: D+1, aprovação humana no Telegram, edição/regeneração, entrega manual assistida, follow-up — nenhuma delas muda. Parada imediata em resposta/recusa já é comportamento nativo de `complete_followup`/`approve_message` (decisão `DESCARTADO`), preservado sem mudança.

## 6. Pontos de integração Composio/Looper (documentados, não validados)

Nenhuma capacidade real foi confirmada nesta sessão — nenhum dos dois conectores está acessível. Isto é o que o schema acima **permitiria**, uma vez que as capacidades reais sejam validadas:

- **Composio** — ponto de integração hipotético: alimentar `register_prospect`/`qualify_prospect` com perfis descobertos por uma automação que o Composio já executa de forma autorizada (ex.: uma busca/filtragem dentro de uma ferramenta legítima que ele conecta) — nunca scraping do LinkedIn em nome desta skill. `origem='composio_pendente_validacao'` marca explicitamente que o dado chegou por essa via até a validação acontecer.
- **Looper** — mesmo tratamento: ponto de integração hipotético em `register_prospect`, `origem='looper_pendente_validacao'`, sem nenhuma suposição sobre o que a ferramenta realmente faz.
- **Hard rule preservada:** nenhuma função deste adendo envia convite, mensagem, clique ou qualquer ação na interface do LinkedIn. `mark_invite_sent` e `confirm_invite_accepted` **registram fatos que já aconteceram fora do sistema**, sempre confirmados por um humano — nunca disparam a ação.

## 7. Caso concreto: Paulo Henrique (do print do usuário)

Conforme relatado: convite já enviado, aceite pendente. Mapeamento direto, **sem gravar nada ainda** (sem acesso ao banco neste container/sessão):
- `register_prospect(...)` → `IDENTIFICADO`
- `qualify_prospect(...)` → `QUALIFICADO` (se os dados do print bastarem para uma classificação P1/P2/P3; senão, fica pendente de validação, sem inventar cargo/escola)
- `mark_invite_sent(...)` → `CONVITE_PENDENTE`, `convite_enviado_em` = data do print

Antes de gravar de fato (quando o MCP do n8n/acesso ao banco voltar), confirmar com Anderson se o estado ainda é `CONVITE_PENDENTE` ou se já mudou desde o print — a instrução original já previa essa confirmação, preservada aqui.

## 8. Critérios de teste (para quando a implementação for autorizada — GATE 3/4 equivalentes deste adendo)

- `register_prospect` chamado duas vezes com a mesma URL (variando maiúsculas/barra final) → segunda chamada retorna `already_existed=true`, nenhuma linha nova em `prospects` nem em `schools`.
- Duas instituições com nomes "Colégio Alfa" e "colégio  alfa" (espaços/caixa diferentes) → resolvem para o mesmo `school_id`.
- `qualify_prospect` com `icp_tier` fora de `P1/P2/P3` → rejeitado.
- `get_daily_prospect_queue(p_limit=500)` → nunca retorna mais de 20 linhas.
- `mark_invite_sent` chamado duas vezes em sequência no mesmo prospect → segunda chamada é no-op idempotente (`already_sent=true`), não duplica `convite_enviado_em`.
- `confirm_invite_accepted` chamado num prospect ainda `QUALIFICADO` (sem convite marcado) → rejeitado.
- `close_prospect` sem `p_motivo` válido → rejeitado; chamado duas vezes com motivos diferentes → segunda chamada rejeitada (não reescreve o motivo original).
- Nenhuma das 6 funções novas aceita escrita direta de tabela pela role do n8n (mesma auditoria estática já aplicada às 15 funções existentes).
- Todas as 6 revogadas de `PUBLIC`, `GRANT EXECUTE` só para a role de aplicação — mesmo padrão.
- Relatório diário (view/consulta sobre `prospects`+`prospect_events`+`connections.reuniao_agendada_em`) bate com uma fixture conhecida (N convites enviados, M pendentes, K aceites, etc.) antes de ser considerado correto.

## 9. O que este adendo explicitamente não faz

Não gera nem executa SQL. Não cria tabela/função/workflow real. Não envia convite ou mensagem. Não ativa nada. Não decide sozinho quantos dos 20 perfis diários podem realmente receber convite — isso depende dos limites reais do LinkedIn, que só Anderson pode avaliar e autorizar por lote.
