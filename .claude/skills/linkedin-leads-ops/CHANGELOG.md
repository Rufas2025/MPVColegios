# Changelog: linkedin-leads-ops

## 1.1.0 (24/11/2026)

- `references/repertorio-ganchos.md`: ganchos da seção Experiência, perguntas, analogias do Anderson (guia
  impresso → GPS → Waze; celular feito para ligar; plano de aula), contexto de mercado e casos-modelo.
- Redes com contrato direto com a Eduinfo (Grupo Salta, Adventista) não recebem abordagem.
- Botão "Editar" quebrado: contorno e modelos de operação em `db/ops/`.

## 1.0.0 (20/11/2026)

Primeira versão, escrita depois da auditoria final (`n8n/AUDITORIA-2026-11-20.md`).

- Arquitetura em produção: Gmail → Apps Script → WF-01E → WF-02 → WF-NOTIFY → WF-ROUTER → WF-05.
- IDs de workflow, nomes de credencial, propriedades do Apps Script, estados e cadência.
- Tabela de diagnóstico por sintoma e consultas SQL de leitura (`references/diagnostico-sql.md`).
- Testes sem contato real, backup/rollback, lições aprendidas e checklist de 23/11/2026.
