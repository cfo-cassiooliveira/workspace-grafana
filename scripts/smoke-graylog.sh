#!/usr/bin/env bash
# Smoke test do envio dos logs do Grafana ao Graylog (T08), com o Graylog real de pé (Keycloak derrubado):
#   1) sobe o Grafana com o override docker-compose.graylog.yml (driver GELF, tag grafana);
#   2) gera eventos reais: login falho do break-glass e login falho com um e-mail descartável;
#   3) confere no Graylog service_name:grafana, stream "Grafana - Infra" e nível (warn), SEM login/e-mail em claro
#      em nenhum campo, inclusive full_message (a T03 só havia testado com JSON sintético);
#   4) o smoke principal (partes 1) não recria o container nem tira o driver GELF.
# Não rode junto do Keycloak nem de outros smokes de infra. Segredos não são impressos (credencial do Graylog por -K).
# Uso (na raiz do projeto, com o Graylog de pé e as redes externas criadas): ./scripts/smoke-graylog.sh
set -euo pipefail
exec < /dev/null

cd "$(dirname "$0")/.."

BASE_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAYLOG_URL="${GRAYLOG_URL:-http://127.0.0.1:9000}"
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.graylog.yml)
failures=0
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

check() {
  local description="$1" ok="$2"
  if [[ "$ok" == "true" ]]; then echo "OK   ${description}"; else echo "FALHA ${description}"; failures=$((failures + 1)); fi
}
contains() { if grep -qF -- "$2" <<< "$1"; then echo true; else echo false; fi; }

[[ -f .env ]] || { echo "Falta o .env (rode ./scripts/generate-env.sh)." >&2; exit 2; }
[[ -f ../graylog/.env ]] || { echo "Falta ../graylog/.env: suba o projeto graylog antes." >&2; exit 2; }
set -a
# shellcheck disable=SC1091
source .env
set +a
# Mesmo usuário do provisioner do Graylog (admin, GRAYLOG_ROOT_PASSWORD); vai para um arquivo -K, nunca para o argv.
graylog_password="$({ grep -m1 '^GRAYLOG_ROOT_PASSWORD=' ../graylog/.env || true; } | cut -d= -f2- | tr -d '\r')"
[[ -n "$graylog_password" ]] || { echo "GRAYLOG_ROOT_PASSWORD não encontrado em ../graylog/.env." >&2; exit 2; }
(umask 077; printf 'user = "admin:%s"\n' "$graylog_password" > "${work_dir}/graylog.curlrc")

# Busca no Graylog (últimos 10 min) com todos os campos que poderiam carregar login/e-mail; devolve o JSON cru.
# $1 = consulta Lucene (sem aspas duplas soltas; use \\\" para frases).
graylog_search() {
  curl -s --max-time 20 -K "${work_dir}/graylog.curlrc" -H "X-Requested-By: smoke-graylog" -H 'Content-Type: application/json' \
    -X POST "${GRAYLOG_URL}/api/search/messages" \
    --data "{\"query\": \"$1\", \"timerange\": {\"type\": \"relative\", \"range\": 600}, \"size\": 50, \"fields\": [\"message\", \"full_message\", \"service_name\", \"level_name\", \"logger\", \"streams\", \"tag\", \"user\", \"email\", \"login\", \"username\", \"uname\", \"remote_addr\", \"error\"]}"
}
# Espera (até ~60 s, o índice é near real-time) a consulta devolver o marcador; imprime a resposta.
await_graylog() {
  local query="$1" marker="$2" result
  for _ in $(seq 1 30); do
    result="$(graylog_search "$query")"
    if grep -qF -- "$marker" <<< "$result"; then echo "$result"; return 0; fi
    sleep 2
  done
  echo ""
}
# Login falho (senha errada) pela API do Grafana. A senha errada é constante; o usuário vem por argumento.
failed_login() {
  printf '{"user":"%s","password":"wrong-password-smoke"}' "$1" \
    | curl -s -o /dev/null --max-time 10 -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login" || true
}

echo "== Preparação"
check "Graylog responde em ${GRAYLOG_URL}" "$([[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K "${work_dir}/graylog.curlrc" "${GRAYLOG_URL}/api/system")" == 200 ]] && echo true || echo false)"

echo "== 1) Grafana com o override GELF"
"${COMPOSE[@]}" up -d --build >/dev/null 2>&1 || { echo "FALHA docker compose up com o override"; exit 1; }
container="$(docker compose ps -q grafana)"
for _ in $(seq 1 40); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$container")" == healthy ]] && break
  sleep 3
done
check "Grafana healthy com o override" "$([[ "$(docker inspect -f '{{.State.Health.Status}}' "$container")" == healthy ]] && echo true || echo false)"
check "driver de log é gelf, udp://127.0.0.1:12201, tag grafana" \
  "$([[ "$(docker inspect -f '{{.HostConfig.LogConfig.Type}} {{index .HostConfig.LogConfig.Config "gelf-address"}} {{index .HostConfig.LogConfig.Config "tag"}}' "$container")" == "gelf udp://127.0.0.1:12201 grafana" ]] && echo true || echo false)"

echo "== 2) Eventos reais: logins falhos e requisição autenticada com erro"
probe_email="smoke.graylog.$(date +%s)${RANDOM}@smoke.invalid"
probe_local="${probe_email%@*}"
failed_login "$GRAFANA_ADMIN_USER"
failed_login "$probe_email"
# O Grafana só grava o login ("uname") no log de requisições com erro feitas já autenticadas: 404 como break-glass.
printf '{"user":"%s","password":"%s"}' "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD" \
  | curl -s -o /dev/null --max-time 10 -c "${work_dir}/bg.jar" -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login"
curl -s -o /dev/null --max-time 10 -b "${work_dir}/bg.jar" "${BASE_URL}/api/dashboards/uid/smoke-graylog-inexistente"
sleep 2
# Pré-condição do teste de LGPD: o login do break-glass está mesmo em claro no JSON bruto do stdout do Grafana.
check "pré-condição: o login do break-glass aparece no JSON bruto do Grafana (campo uname)" \
  "$(contains "$(docker logs --since 2m "$container" 2>&1)" "\"uname\":\"${GRAFANA_ADMIN_USER}\"")"

echo "== 3) No Graylog"
result="$(await_graylog 'service_name:grafana AND logger:context AND message:\"Request Completed\"' 'Request Completed')"
check "requisições do Grafana (logins falhos, 401/404) chegaram ao Graylog com service_name:grafana" \
  "$([[ -n "$result" && "$(contains "$result" '"grafana"')" == true ]] && echo true || echo false)"
check "evento no stream 'Grafana - Infra'" "$(contains "$result" 'Grafana - Infra')"
check "nível lido do JSON do Grafana (info -> level_name information) e logger context" \
  "$([[ "$(contains "$result" '"information"')" == true && "$(contains "$result" '"context"')" == true ]] && echo true || echo false)"
# LGPD: nenhum campo (message, full_message, user, email, login...) com o e-mail ou o login do break-glass em claro.
all_grafana="$(graylog_search 'service_name:grafana')"
check "há logs do Grafana para a varredura de LGPD" "$(contains "$all_grafana" 'service_name')"
check "e-mail descartável não aparece em claro em nenhum campo (inclui full_message)" \
  "$([[ "$(contains "$all_grafana" "$probe_email")" == false && "$(contains "$all_grafana" "$probe_local")" == false ]] && echo true || echo false)"
check "login do break-glass não aparece em claro em nenhum campo (inclui full_message)" \
  "$([[ "$(contains "$all_grafana" "$GRAFANA_ADMIN_USER")" == false ]] && echo true || echo false)"
# Pesquisa direta no índice pelos valores em claro: nada deve ser encontrado (campos indexados, não só a exibição).
clear_hits="$(graylog_search "service_name:grafana AND (\\\"${probe_email}\\\" OR \\\"${GRAFANA_ADMIN_USER}\\\")")"
check "pesquisa pelo e-mail/login em claro no Graylog não retorna eventos do Grafana" \
  "$([[ -n "$clear_hits" && "$(contains "$clear_hits" '"datarows":[]')" == true ]] && echo true || echo false)"

echo "== 4) Smoke principal não recria o container nem tira o driver GELF"
before_id="$container"
main_smoke=false
if ./scripts/smoke-test.sh --skip-sso --skip-datasource --skip-alerts --skip-metrics >/dev/null 2>&1; then main_smoke=true; fi
check "smoke principal (parte 1) passou com o override ativo" "$main_smoke"
after_id="$(docker compose ps -q grafana)"
check "container é o mesmo depois do smoke principal (não foi recriado)" "$([[ "$before_id" == "$after_id" ]] && echo true || echo false)"
check "driver GELF continua ativo depois do smoke principal" \
  "$([[ "$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$after_id")" == gelf ]] && echo true || echo false)"

if [[ $failures -ne 0 ]]; then echo "smoke-graylog: ${failures} falha(s)"; exit 1; fi
echo "smoke-graylog: APROVADO"
