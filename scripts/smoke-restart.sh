#!/usr/bin/env bash
# Smoke de idempotência (H1): reiniciar o Grafana não duplica nem perde estado provisionado.
# Compara, antes e depois de `docker compose restart grafana`, os dashboards (uid), pastas, datasources,
# regras de alerta e usuários; confere que não há uid duplicado e que o provisioning não registra erros.
# Só reinicia o container (mantém volume e o override de logging com que foi subido). Dados 100% sintéticos.
# Uso (na raiz do projeto, com o Grafana de pé): ./scripts/smoke-restart.sh
set -euo pipefail
exec < /dev/null

cd "$(dirname "$0")/.."
BASE_URL="${GRAFANA_URL:-http://localhost:3000}"
failures=0
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

check() {
  local description="$1" ok="$2"
  if [[ "$ok" == "true" ]]; then echo "OK   ${description}"; else echo "FALHA ${description}"; failures=$((failures + 1)); fi
}
eq_if() { if [[ "$1" == "$2" ]]; then echo true; else echo false; fi; }

[[ -f .env ]] || { echo "Falta o .env (rode ./scripts/generate-env.sh)." >&2; exit 2; }
set -a
# shellcheck disable=SC1091
source .env
set +a

container="$(docker compose ps -q grafana)"
[[ -n "$container" ]] || { echo "FALHA container grafana não encontrado"; exit 1; }

wait_healthy() {
  local state="starting" id
  for _ in $(seq 1 60); do
    id="$(docker compose ps -q grafana)"
    state="$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo starting)"
    [[ "$state" == "healthy" ]] && return 0
    sleep 3
  done
  return 1
}

# Login por stdin (senha fora do argv) e leitura autenticada.
login() {
  printf '{"user":"%s","password":"%s"}' "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD" \
    | curl -s -o /dev/null --max-time 10 -c "${work_dir}/jar" -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login"
}
api() { curl -s --max-time 20 -b "${work_dir}/jar" "${BASE_URL}$1"; }

# Retrato do estado: uma linha por recurso, ordenado (sem jq: usa sed/grep sobre o JSON).
snapshot() {
  login
  {
    api "/api/search?type=dash-db&limit=5000" | { grep -o '"uid":"[^"]*"' || true; } | sed 's/^/dashboard /'
    api "/api/folders?limit=1000" | { grep -o '"uid":"[^"]*"' || true; } | sed 's/^/folder /'
    api "/api/datasources" | { grep -o '"uid":"[^"]*"' || true; } | sed 's/^/datasource /'
    # Só o uid da própria regra (logo após o "id"): o "uid" dos datasources dentro de data/model se repete e não conta.
    api "/api/v1/provisioning/alert-rules" | { grep -o '"id":[0-9]*,"uid":"[^"]*"' || true; } | sed 's/^"id":[0-9]*,//; s/^/alert /'
    api "/api/users?perpage=1000" | { grep -o '"login":"[^"]*"' || true; } | sed 's/^/user /'
  } | sort
}

check "container healthy antes do reinício" "$(wait_healthy && echo true || echo false)"
snapshot > "${work_dir}/before.txt"
dash_before="$(grep -c '^dashboard ' "${work_dir}/before.txt" || true)"
if [[ "$dash_before" -gt 0 ]]; then echo "OK   há dashboards para comparar (${dash_before})"; else echo "AVISO nenhum dashboard provisionado ainda (T10+): a comparação cobre só pastas, datasources e usuários"; fi
check "há datasource provisionado para comparar" "$([[ "$(grep -c '^datasource ' "${work_dir}/before.txt" || true)" -gt 0 ]] && echo true || echo false)"

docker compose restart grafana >/dev/null 2>&1
check "container healthy após o reinício" "$(wait_healthy && echo true || echo false)"
snapshot > "${work_dir}/after.txt"

check "estado idêntico após o reinício (dashboards, pastas, datasources, alertas, usuários)" \
  "$(diff -q "${work_dir}/before.txt" "${work_dir}/after.txt" >/dev/null 2>&1 && echo true || echo false)"
check "nenhum uid duplicado após o reinício" "$(eq_if "$(sort "${work_dir}/after.txt" | uniq -d | wc -l | tr -d ' ')" 0)"
check "contagem de dashboards inalterada (${dash_before})" "$(eq_if "$(grep -c '^dashboard ' "${work_dir}/after.txt" || true)" "$dash_before")"

# Só o log desde o reinício (o anterior já foi conferido pelo smoke-test).
since_logs="$(docker logs --since 2m "$(docker compose ps -q grafana)" 2>&1 || true)"
errors="$(grep -E '"level":"(error|eror)"' <<< "$since_logs" | grep -c 'provisioning' || true)"
check "provisioning sem erros após o reinício" "$(eq_if "$errors" 0)"
check "login do break-glass continua funcionando após o reinício" \
  "$(eq_if "$(api /api/user | grep -c '"isGrafanaAdmin":true' || true)" 1)"

if [[ "$failures" -gt 0 ]]; then echo "smoke-restart: ${failures} falha(s)"; exit 1; fi
echo "smoke-restart: APROVADO"
