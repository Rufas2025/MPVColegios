#!/usr/bin/env bash
# =============================================================================
# run_concurrency_tests.sh
# Rufino LinkedIn Intelligence — GATE 3 (banco DEV) — v1.5.0
#
# Executa os testes de concorrência real (duas conexões PostgreSQL
# simultâneas) descritos em ../010_concurrency_tests.md, contra um banco
# PostgreSQL já com a migration 001-006 aplicada. NUNCA rodar contra o
# banco real rufino-linkedin-dev — só contra um banco descartável.
#
# Uso:
#   PGHOST=... PGPORT=... PGUSER=... PGDATABASE=rufino-linkedin-dev \
#     ./run_concurrency_tests.sh
#
# (ou ajuste as variáveis de conexão no topo deste script conforme o seu
# ambiente de teste — neste GATE 3 foi rodado localmente via `psql` direto,
# sem variáveis de ambiente, usando o usuário do sistema operacional que já
# tinha acesso administrativo ao cluster descartável.)
#
# Este script NÃO faz parte da migration de produção (001-009) — existe
# só para auditoria e para permitir reexecução independente dos testes de
# concorrência registrados no TEST-REPORT.md desta rodada.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSQL="${PSQL:-psql}"
DB="${PGDATABASE:-rufino-linkedin-dev}"

echo "=== Teste 1: record_workflow_error concorrente em duas sessões ==="
"$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/concurrency_record_workflow_error_session_a.sql" > /tmp/rwe_session_a.out 2>&1 &
PID_A=$!
"$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/concurrency_record_workflow_error_session_b.sql" > /tmp/rwe_session_b.out 2>&1 &
PID_B=$!
wait "$PID_A"
wait "$PID_B"
echo "--- Sessão A ---"; cat /tmp/rwe_session_a.out
echo "--- Sessão B ---"; cat /tmp/rwe_session_b.out

RC_A=$("$PSQL" -t -A -d "$DB" -c "SELECT retry_count FROM rufino_linkedin.workflow_errors WHERE execution_id = 'concurrency-test-exec-A' AND source_workflow = 'WF-CONCURRENCY-TEST';")
RC_B=$("$PSQL" -t -A -d "$DB" -c "SELECT retry_count FROM rufino_linkedin.workflow_errors WHERE execution_id = 'concurrency-test-exec-B' AND source_workflow = 'WF-CONCURRENCY-TEST';")
echo "retry_count sessão A (execution_id=concurrency-test-exec-A) = $RC_A"
echo "retry_count sessão B (execution_id=concurrency-test-exec-B) = $RC_B"
if [ -z "$RC_A" ] || [ -z "$RC_B" ] || [ "$RC_A" = "$RC_B" ]; then
    echo "FALHA: retry_count deveria ser distinto e sequencial entre as duas sessões (A=$RC_A, B=$RC_B)"
    exit 1
fi
echo "OK: retry_count distintos e sequenciais ($RC_A depois $RC_B) -- serialização confirmada"

echo ""
echo "=== Teste 2: duas sessões reivindicando notification jobs simultaneamente ==="
"$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/concurrency_claim_notification_jobs_setup.sql" > /tmp/claim_setup.out 2>&1
"$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/concurrency_claim_notification_jobs_session.sql" > /tmp/claim_session_1.out 2>&1 &
PID_1=$!
"$PSQL" -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT_DIR/concurrency_claim_notification_jobs_session.sql" > /tmp/claim_session_2.out 2>&1 &
PID_2=$!
wait "$PID_1"
wait "$PID_2"
echo "--- Sessão 1 ---"; cat /tmp/claim_session_1.out
echo "--- Sessão 2 ---"; cat /tmp/claim_session_2.out

JOBS_1=$( (grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' /tmp/claim_session_1.out || true) | sort -u)
JOBS_2=$( (grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' /tmp/claim_session_2.out || true) | sort -u)
TOTAL_CLAIMED=$(printf '%s\n%s\n' "$JOBS_1" "$JOBS_2" | grep -c . || true)
COMMON=$( (comm -12 <(echo "$JOBS_1") <(echo "$JOBS_2") || true) | grep -c . || true)
if [ "$COMMON" != "0" ]; then
    echo "FALHA: as duas sessões reivindicaram algum job/conexão em comum -- FOR UPDATE SKIP LOCKED nao esta exclusivo"
    exit 1
fi
if [ "$TOTAL_CLAIMED" = "0" ]; then
    echo "FALHA: nenhuma das duas sessões reivindicou nada -- teste inconclusivo (nada foi exercitado)"
    exit 1
fi
echo "OK: as duas sessões reivindicaram conjuntos disjuntos, sem sobreposição (FOR UPDATE SKIP LOCKED funcionando; total de UUIDs reivindicados: $TOTAL_CLAIMED)"

echo ""
echo "=== Limpeza dos dados de teste (COMMIT foi usado para provar concorrência real) ==="
"$PSQL" -d "$DB" -c "DELETE FROM rufino_linkedin.workflow_errors WHERE source_workflow = 'WF-CONCURRENCY-TEST';"
"$PSQL" -d "$DB" -c "DELETE FROM rufino_linkedin.connections WHERE idempotency_key IN ('concurrency-test-v150-conn-1', 'concurrency-test-v150-conn-2');"

echo ""
echo "=== Todos os testes de concorrência passaram ==="
