# CASO PILOTO 01 — Leandro (regra reutilizável "aceite → mensagem → D+1 → aprovação → acompanhamento")

**Status (atualizado 2026-11-11): aplicado e testado de ponta a ponta no banco real `rufino-linkedin-dev`.** Migrações `011`, `012` e `013` aplicadas. Leandro registrado de verdade (`connection_id = 0d315743-ff4f-43f9-8da7-7404f7a2585f`), passou por `AGUARDANDO_D1 → AGUARDANDO_APROVACAO → APROVADO → PRONTO_PARA_ENVIO` via execução real de WF-02/WF-NOTIFY/WF-03. **Nenhuma mensagem real foi enviada no LinkedIn. Nenhum workflow foi ativado (todas as execuções foram manuais/sob demanda). PROD não foi tocado.** Ver `D1-EXCEPTIONAL-PILOT-TEST-RESULTS.md` para o relato completo do teste de hoje, incluindo o bloqueio exato (credencial Telegram) e o procedimento de confirmação manual do envio pendente.

## A regra reutilizável (não é código novo — é a composição do que já existe)

```
Conexão aceita no LinkedIn
    ↓
register_prospect  → IDENTIFICADO            (rastreio/dedupe por URL canônica; reaproveitado do adendo)
    ↓
qualify_prospect   → QUALIFICADO (Pn)         (classificação ICP; reaproveitado do adendo)
    ↓
register_connection (WF-01, já existente, contrato estendido em 012 — ver N8N-INTEGRATION.md) → cria `connections`, calcula scheduled_at = D+1 no horário operacional configurável (`operational_config`, padrão 09:00 America/Sao_Paulo), grava origem auditável da data (`data_conexao_origem`/`data_conexao_confirmado_por`)
    ↓
link_prospect_to_connection → prospect vira CONECTADO, vinculado à connection real (reaproveitado do adendo)
    ↓
claim_due_connections (WF-02, já existente) → D+1 chegou → cria job de notificação (outbox)
    ↓
claim_notification_jobs + Telegram (WF-NOTIFY, já existente) → Anderson recebe a mensagem proposta
    ↓
approve_message (WF-03, já existente) → aprovação humana (Aprovar e preparar / Editar / Refazer / Descartar)
    ↓
mark_message_sent (WF-04, já existente) → Anderson confirma que enviou manualmente no LinkedIn; agenda o 1º follow-up
    ↓
claim_due_followups + complete_followup (WF-05, já existente) → acompanhamento da resposta (RESPONDEU encerra; SEM_RESPOSTA reagenda)
```

**Nada disso é infraestrutura nova.** Cada seta é uma função ou workflow que já existe e já foi testado em rodadas anteriores (GATE 4 + adendo pré-conexão). A única peça genuinamente pendente de implementação é o node Postgres de `link_prospect_to_connection` dentro do WF-01 (autorizado antes, ainda não feito — ver seção D do relatório final) — enquanto isso, esse passo é manual (uma chamada direta à função).

## Dados confirmados do Leandro (só o que foi dado — nada inventado)

| Campo | Valor |
|---|---|
| Nome | Leandro Henrique Ferreira da Silva |
| LinkedIn | `https://www.linkedin.com/in/ferreiraleandro1993/` |
| Cargo | Diretor de Unidade Escolar |
| Instituição | Rede de Ensino Colegium |
| Cidade | Belo Horizonte/MG |
| Histórico | Rede Elite de Ensino (anterior) → Colegium desde abril/2024 |
| Estado da conexão | Aceita; mensagem ainda não enviada |
| Classificação | P2, sujeita a validação |
| **Data de conexão (confirmada visualmente em linkedin.com/mynetwork/invite-connect/connections/)** | **11/11/2026** |
| **D+1 calculado** | **12/11/2026 09:00 America/Sao_Paulo** (horário operacional padrão; não é segunda/terça, sem ajuste de fim de semana) |
| **Origem auditável gravada** | `data_conexao_origem = 'linkedin_mynetwork_confirmacao_manual'`, `data_conexao_confirmado_por = 'anderson'` |

A data do aceite agora é conhecida com certeza — confirmada visualmente por Anderson na própria página do LinkedIn (`mynetwork/invite-connect/connections/`), não pela data de importação nem pela data da confirmação manual em si. Como o LinkedIn exibe a data sem horário, o horário do aceite não foi inventado: o D+1 usa o horário operacional configurável (`rufino_linkedin.operational_config`, hoje 09:00 America/Sao_Paulo) só para preparar a mensagem, nunca como horário real do aceite.

## Mensagem de boas-vindas (D+1) — texto final proposto

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
> Grande abraço,
> Rufino

Diferenças em relação ao texto de referência do usuário: removida a afirmação "caminhando para três anos" (o único dado confirmado é a data de início, abril/2024 — a contagem exata de anos não foi confirmada por print, então não foi afirmada como fato). Nenhuma proposta comercial, nenhum pedido de reunião, nenhuma informação fora da tabela acima.

## Ponto 6 — como o sistema identifica aceite e resposta reais no LinkedIn

**Resposta direta: não existe, e não foi simulada, nenhuma integração automática com o LinkedIn para detectar aceite de convite ou resposta a mensagem.** Isso nunca foi construído nesta jornada e continua fora de escopo (ver `linkedin-safety.md`/regras da skill: nenhuma automação da interface do LinkedIn). O que já existe, reaproveitado — não é algo novo para este piloto:

- **Aceite:** confirmado por Anderson, manualmente (é por isso que `confirm_invite_accepted`/`link_prospect_to_connection` existem como *registro* de um fato já observado, não como gatilho automático).
- **Resposta à mensagem:** confirmado por Anderson via Telegram, nos botões já existentes do WF-05 (`f:R` Respondeu / `f:N` Sem resposta) — chama `complete_followup`. Isso já é a "fila de mensagens prontas + confirmação manual" pedida no ponto 6; não foi preciso construir nada novo.

## O que foi testado localmente (não contra o banco real)

Dois arquivos de teste, deliberadamente separados para nunca misturar o dado real do Leandro com mecânica de teste:

**`tests/pilot_01_leandro_tests.sql`** — roda os passos [1]-[7] com os dados **reais** do Leandro e a data de conexão **real confirmada** (`2026-11-11`). Cobre:
- idempotência de `register_prospect` (registrar o mesmo LinkedIn do Leandro duas vezes não duplica);
- `qualify_prospect` → QUALIFICADO/P2;
- `register_connection` com os novos parâmetros de origem auditável (`linkedin_mynetwork_confirmacao_manual`/`anderson`) — calcula corretamente `scheduled_at = 2026-11-12 09:00 America/Sao_Paulo` (12:00 UTC);
- `link_prospect_to_connection` → prospect vira CONECTADO;
- `claim_due_connections` roda e **corretamente retorna 0 linhas**, porque hoje (11/11/2026) o D+1 (12/11/2026) ainda não chegou — isso é o comportamento certo, não uma falha;
- leitura da trilha de auditoria gravada (`data_conexao_origem`, `data_conexao_confirmado_por`, `scheduled_at`, `status`).

Este arquivo para intencionalmente aí: com a data real, o resto do pipeline (aprovação, envio, follow-up) só acontece de verdade a partir de 12/11/2026 09:00.

**`tests/pilot_01_mechanics_tests.sql`** — roda a mecânica completa do pipeline pós-D+1 com um contato **sintético** (não o Leandro) e uma data de conexão de teste no passado (`CURRENT_DATE - 5 dias`), para exercitar de ponta a ponta sem esperar dias reais:
- `claim_due_connections` reivindica a conexão sintética e cria o job de notificação;
- aprovação humana (`approve_message`, decisão `APROVAR_E_PREPARAR`);
- `mark_message_sent` e **prevenção de envio duplicado** (uma segunda tentativa de reivindicar/confirmar o mesmo job de notificação não duplica, e reuso do token de entrega é rejeitado com erro);
- **interrupção após resposta**: `complete_followup` com `RESPONDEU` encerra a conexão (`ENCERRADO`) e nenhum follow-up novo é criado depois disso.

Ambos os arquivos passaram limpos nesta rodada, contra uma réplica local fiel do estado real do banco DEV (base v1.5.1 + adendo de prospecção `011` + atualização da regra D+1 `012`).
