# Aviso: exports desatualizados

Os JSONs desta pasta são de 10–11/11/2026 (GATE 4) e **não correspondem** aos workflows publicados hoje.

- `WF-03-approval-callback.json`, `WF-04-delivery-callback.json` e `WF-05-followup.json` têm
  **Telegram Trigger próprio**. Importar e publicar qualquer um deles toma o webhook do bot e derruba
  todos os botões (o único trigger deve ser o WF-ROUTER).
- WF-02, WF-NOTIFY e WF-05 foram alterados em 19–20/11; o WF-ROUTER e o WF-01E não existem aqui.

Fonte de verdade: o histórico de versões do n8n (IDs em `n8n/AUDITORIA-2026-11-20.md`) e
`apps-script/linkedin-leads/` para o WF-01E. Exports atualizados devem ir para `n8n/workflows/`.
