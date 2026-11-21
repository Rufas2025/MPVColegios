# WF-90 Vigia (guardrail da cadência)

O vigia roda dentro do n8n e não depende do Claude: mesmo sem esta conexão, o Anderson recebe o estado do
fluxo no Telegram. **O objetivo é que nenhuma falha passe em silêncio**, e não prometer que nada falha.

## O que vigia

| Quando | O quê | Envia |
|---|---|---|
| Dias úteis 8h40 (antes do WF-02/WF-05) | Relatório: aprovações e lembretes das 9h, botões esperando toque, falhas e pontos de atenção | Sempre. Se não chegar às 8h40, o próprio silêncio é o alarme (n8n, Postgres ou Telegram fora). |
| Dias úteis 15h | Mesmas checagens | Só se houver falha |
| Na hora | Error Trigger: qualquer execução de produção com erro no WF-01E, WF-02, WF-05, WF-NOTIFY ou WF-ROUTER | Sempre |

Regra de volume (Anderson, 21/11/2026): **o D+1 manda**. 20/dia é referência, não teto: se a fila do dia tiver 32 ou 42,
sai tudo no D+1. O `p_limit` do WF-02 fica em 100 só como trava contra enxurrada por erro.

Falhas detectadas (🚨):
- fila do dia acima da trava de 100 (alguém sairia do D+1; conferir duplicação antes de subir);
- WF-02 não reivindicou ninguém na última janela das 9h, havendo contatos vencidos que já existiam;
- WF-05 não enviou lembretes vencidos;
- botão de aprovação/entrega vencido (não há reenvio automático);
- contato esperando aprovação/entrega sem botão válido;
- notificação do Telegram presa há mais de 15 min (WF-NOTIFY);
- `workflow_errors` aberto ou contato em status `ERRO`.

Atenção (⚠️):
- aceites novos acima de 20/dia em 3 dos últimos 10 dias úteis (sugere subir a referência para 30) ou acima de 30 (rever a régua);
- botões de aprovação, entrega ou follow-up que vencem em menos de 48h;
- nenhum aceite novo há 5 dias úteis (possível acionador do Apps Script parado);
- tabela de feriados acabando em menos de 60 dias.

## Arquivos

- `vigia-fatos.sql`: consulta somente leitura (credencial do app). Testada no Postgres local com o papel `n8n_rufino_linkedin_dev`.
- `vigia-avaliar.js`: decide o que é falha ou atenção (conhece os feriados). Testada com 10 cenários simulados.
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

## Quando o Claude perde o acesso ao n8n (incidente de 21/11/2026)

O fluxo de produção (Apps Script → webhook → n8n → Postgres → Telegram) **não passa pelo conector do Claude**.
O conector serve só para o Claude consultar e alterar workflows. Se ele cair, a cadência continua rodando, e o
relatório das 8h40 segue sendo a fonte de verdade.

Diagnóstico em 21/11, a partir de ~13h (Brasília):
- Os dois conectores n8n da conta caíram ao mesmo tempo com o mesmo erro da ponte de conectores do Claude
  (502/503). Um deles é a instância Rufino DEV e o outro é a instância crm nar, que é outro servidor.
- Ao mesmo tempo, a instância Rufino DEV respondia normal: `/healthz` 200, endpoint MCP 401 sem token em 0,6 s,
  webhook de aceites 403 sem token. Houve um único POST lento (~14h), que não se repetiu.
- Conclusão: a falha está na ponte entre a sessão do Claude e os conectores, não no n8n nem no fluxo.

Checagem rápida (sem credencial; só mostra se o n8n está de pé):
```
H=https://rufino-linkedin-dev-n8n.snfrzv.easypanel.host
curl -s -o /dev/null -w '%{http_code}\n' $H/healthz          # 200
curl -s -o /dev/null -w '%{http_code}\n' $H/mcp-server/http  # 401 (endpoint do MCP vivo, pede token)
```

O que fazer:
1. Reconectar o conector em claude.ai → Configurações → Conectores e abrir uma sessão nova (conectores são lidos
   quando a sessão começa).
2. Caminho reserva, opcional: uma chave da API do n8n (Settings → n8n API) salva como segredo do ambiente do
   Claude (nunca no chat nem no repositório). Com ela, o Claude lê e publica workflows pela API REST sem depender
   da ponte de conectores.
3. Mudança de produção marcada para antes das 9h que não pôde ser aplicada: avisar o Anderson antes das 9h de
   que vale a configuração antiga naquele dia.
