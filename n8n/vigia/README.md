# WF-90 Vigia (guardrail da cadência)

O vigia roda dentro do n8n e não depende do Claude: mesmo sem esta conexão, o Anderson recebe o estado do
fluxo no Telegram. **O objetivo é que nenhuma falha passe em silêncio**, e não prometer que nada falha.

## O que vigia

| Quando | O quê | Envia |
|---|---|---|
| Dias úteis 8h40 (antes do WF-02/WF-05) | Relatório: aprovações e lembretes das 9h, botões esperando toque, falhas e pontos de atenção | Sempre. Se não chegar às 8h40, o próprio silêncio é o alarme (n8n, Postgres ou Telegram fora). |
| Dias úteis 15h | Mesmas checagens | Só se houver falha |
| Na hora | Error Trigger: qualquer execução de produção com erro no WF-01E, WF-02, WF-05, WF-NOTIFY ou WF-ROUTER | Sempre |

Falhas detectadas (🚨):
- WF-02 não reivindicou ninguém na última janela das 9h, havendo contatos vencidos que já existiam;
- WF-05 não enviou lembretes vencidos;
- botão de aprovação/entrega vencido (não há reenvio automático);
- contato esperando aprovação/entrega sem botão válido;
- notificação do Telegram presa há mais de 15 min (WF-NOTIFY);
- `workflow_errors` aberto ou contato em status `ERRO`.

Atenção (⚠️):
- aceite recente que vai passar de D+1 por causa do teto de 20;
- botões de aprovação, entrega ou follow-up que vencem em menos de 48h;
- nenhum aceite novo há 5 dias úteis (possível acionador do Apps Script parado);
- tabela de feriados acabando em menos de 60 dias.

## Arquivos

- `vigia-fatos.sql`: consulta somente leitura (credencial do app). Testada no Postgres local com o papel `n8n_rufino_linkedin_dev`.
- `vigia-avaliar.js`: decide o que é falha ou atenção (conhece os feriados). Testada com 6 cenários simulados.
- `wf-90-vigia.n8n.ts`: workflow, **gerado** por `node n8n/vigia/montar.js`. Editar só os dois arquivos acima.

## Implantação (cada item precisa de autorização)

1. Validar o código no n8n (`validate_workflow`), conferindo os parâmetros do nó de tabela de dados com `get_node_types`.
2. Criar o WF-90 inativo e testar com pin data (fatos simulados e o Error Trigger simulado). Teste simulado não
   substitui a primeira execução real.
3. Publicar o WF-90 **depois** da execução real das 9h de segunda 23/11. Antes disso ele acusaria, com razão, o
   lembrete do Leandro vencido desde 14/11, que só sai nessa execução.
4. Apontar `settings.errorWorkflow` do WF-01E, WF-02, WF-05, WF-NOTIFY e WF-ROUTER para o WF-90. É só configuração,
   sem mexer em nós; backup do `versionId` de cada um antes.
5. Primeiro relatório real: próximo dia útil às 8h40.

## Limites conhecidos

- Não vê o acionador do Apps Script diretamente; só infere pela falta de aceites. Fase 2 opcional: batimento diário
  do Apps Script para o n8n.
- Falha só em execução de teste/manual não dispara o Error Trigger (regra do n8n).
- Se o próprio WF-90 falhar, não há quem avise: por isso o relatório das 8h40 sai sempre.
