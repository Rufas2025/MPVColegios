#!/usr/bin/env bash
# =============================================================================
# run_delayed_retry_tests.sh
# Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.1, Correção 3
#
# Executa os dois testes de retry atrasado real (passagem de tempo de
# parede de verdade, não `now()` simulado dentro de uma transação) contra
# um banco PostgreSQL já com a migration 001-007 aplicada:
#   1. mark_message_sent com p_first_followup_at poucos segundos no
#      futuro, COMMIT, espera de verdade a data passar, retry idêntico.
#   2. complete_followup com p_next_followup_at poucos segundos no
#      futuro, COMMIT, espera de verdade a data passar, retry idêntico.
#
# Cada script SQL faz sua própria verificação (DO $verify$ ... RAISE
# EXCEPTION em caso de falha) e limpa os próprios dados ao final (os dados
# foram commitados de verdade, ao contrário de 009_smoke_tests.sql, que
# nunca sai de BEGIN...ROLLBACK).
#
# NUNCA rodar contra o banco real rufino-linkedin-dev — só contra um banco
# descartável.
#
# Uso:
#   PGDATABASE=rufino-linkedin-dev ./run_delayed_retry_tests.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSQL="${PSQL:-psql}"
DB="${PGDATABASE:-rufino-linkedin-dev}"

echo "=== Teste 1: retry atrasado de mark_message_sent (MARCAR_ENVIADA) ==="
"$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/delayed_retry_mark_message_sent.sql"
echo ""

echo "=== Teste 2: retry atrasado de complete_followup (SEM_RESPOSTA) ==="
"$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/delayed_retry_complete_followup.sql"
echo ""

echo "=== Todos os testes de retry atrasado passaram ==="
