# README-IMPORT.md — GATE 4 - Rufino LinkedIn Intelligence (DEV)

## O que já está pronto na instância

8 dos 9 workflows do GATE 4 já foram criados **ao vivo, inativos**, na instância `rufino-linkedin-dev-n8n.snfrzv.easypanel.host`:

- WF-02 - Scheduler D+1 (`CxLUUmLpj3mA0nfz`)
- WF-NOTIFY - Telegram Outbox (`xmshrOsfUkWSBfnG`)
- WF-03 - Approval Callback (`eomHxG6ODD8pMvMp`)
- WF-03-EDIT - Edit Message (`V0neji0AlG5INqKz`)
- WF-03-REGEN - Regenerate Message (`poBq03kSHdpPJN34`)
- WF-04 - Delivery Callback (`J1CFdbxNhICh9MEP`)
- WF-05 - Follow-up (`W36Y8pew9wwaCb6d`)
- WF-90 - Error Handler (`ASUyxPvFJUmRoWO9`)

Você pode abri-los diretamente em `https://rufino-linkedin-dev-n8n.snfrzv.easypanel.host/workflow/<ID>`. Os JSONs em `WF-*.json` neste diretório são exports reais desses workflows (obtidos via `get_workflow_details` depois da criação), não reconstruções manuais — use-os apenas se precisar reimportar ou como referência.

## O único item pendente: WF-01 - Intake

Já existe um workflow placeholder chamado `WF-01 - Intake - Rufino LinkedIn DEV` (id `7qclFIAJGlRPODH8`) na instância, mas o MCP não tem acesso habilitado nele. Para importar o conteúdo gerado (`WF-01-intake.json`, validado e pronto):

1. Abra o workflow `WF-01 - Intake - Rufino LinkedIn DEV` no editor do n8n.
2. No card do workflow (ou em Settings → habilitar acesso MCP), habilite "Enable MCP access" — isso permite automações futuras via MCP nesse workflow específico.
3. Duas opções para aplicar o conteúdo:
   - **Opção A (recomendada):** selecione tudo no canvas (Ctrl+A), delete, e cole o conteúdo de `WF-01-intake.json` (Ctrl+V com o JSON copiado) para reconstruir os nós.
   - **Opção B:** use "Import from File" apontando para `WF-01-intake.json`, depois copie os nós para dentro do workflow existente (evitando duplicar o workflow em si).
4. Depois de colado, vincule manualmente:
   - O nó **Register Connection (Postgres)** à credencial `Rufino LinkedIn DEV` (id `DgnSAHo0I8CRFwci`) — o JSON já traz esse ID, então normalmente o n8n reconhece automaticamente.
   - O nó **Intake Webhook** a uma credencial Header Auth (ainda não existe — crie-a antes, ver `CREDENTIAL-BINDING.md`).
5. Confirme que o workflow permanece **inativo** antes de sair da tela.

## Ordem sugerida para testes manuais (GATE 4)

1. Crie a credencial Telegram Bot e a credencial Header Auth (ver `CREDENTIAL-BINDING.md`).
2. Preencha os placeholders de texto (chat IDs, URL do form) em cada workflow.
3. Importe/finalize o WF-01 conforme acima.
4. Ligue os workflows **um de cada vez**, manualmente, começando pelo WF-90 (Error Handler) e configurando-o como Error Workflow dos demais, se desejar esse padrão.
5. Rode uma execução manual do WF-01 com um payload de teste (sem apontar para o LinkedIn real) e confirme o registro em `rufino_linkedin.connections`.
6. Siga a cadeia: WF-02 → WF-NOTIFY → WF-03/WF-03-EDIT/WF-03-REGEN → WF-04 → WF-05, testando manualmente cada callback antes de ativar o próximo elo.

## O que NÃO foi feito (por design, conforme escopo do GATE 4)

- Nenhum workflow foi ativado.
- Nenhuma mensagem real foi enviada ao Telegram.
- Nenhuma chamada real foi feita ao LinkedIn ou ao GPT.
- Nenhuma credencial foi criada ou alterada.
- Nenhuma tabela ou função PostgreSQL foi alterada — o contrato de `N8N-INTEGRATION.md` v1.5.1 permanece congelado e intocado.
