# CASO PILOTO 01 — Leandro (regra reutilizável "aceite → mensagem → D+1 → aprovação → acompanhamento")

**Status:** desenhado e testado **localmente** (PostgreSQL descartável). **Nenhuma linha gravada no banco real `rufino-linkedin-dev`. Nenhuma mensagem real enviada. Nenhum workflow ativado.**

## A regra reutilizável (não é código novo — é a composição do que já existe)

```
Conexão aceita no LinkedIn
    ↓
register_prospect  → IDENTIFICADO            (rastreio/dedupe por URL canônica; reaproveitado do adendo)
    ↓
qualify_prospect   → QUALIFICADO (Pn)         (classificação ICP; reaproveitado do adendo)
    ↓
register_connection (WF-01, já existente, contrato congelado) → cria `connections`, calcula scheduled_at = D+1 09:00 America/Sao_Paulo
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

**Faltam, para o registro real:** a data exata do aceite da conexão (não informada — só "aceita", sem data). Sem ela, `register_connection` não pode ser chamada de verdade (o parâmetro `data_conexao` é obrigatório e usado para calcular o D+1). No teste local abaixo, uma data de teste claramente marcada foi usada só para validar a mecânica.

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

Ver `tests/pilot_01_leandro_tests.sql` — roda a sequência completa acima com os dados reais do Leandro (data de aceite marcada como `TESTE — data de aceite nao confirmada`), e cobre explicitamente:
- idempotência de `register_prospect` (registrar o mesmo LinkedIn do Leandro duas vezes não duplica);
- cálculo de D+1 por `register_connection`;
- aprovação humana (`approve_message`, decisão `APROVAR_E_PREPARAR`);
- `mark_message_sent` e **prevenção de envio duplicado** (uma segunda tentativa de reivindicar/confirmar o mesmo job de notificação não duplica nem reenvia);
- **interrupção após resposta**: `complete_followup` com `RESPONDEU` encerra a conexão (`ENCERRADO`) e nenhum follow-up novo é criado depois disso.
