#!/usr/bin/env bash
# Smoke da observabilidade do RabbitMQ (ADR-0005): scrape do broker e do coletor de logs, dashboards com dados e alertas.
# Pré-requisitos: broker de pé (projeto rabbitmq; cria a rede rabbitmq-metrics), stack de métricas subida COM o override
# (docker compose -f prometheus/docker-compose.metrics.yml -f prometheus/docker-compose.rabbitmq.yml up -d) e o Grafana de pé.
# Nunca reinicia o broker: o mutation check cria uma fila própria (smoke-consumer.grafana-<id>) na vhost dev com o usuário
# smoke-app, publica sem consumir, confere a regra "Fila com mensagens e sem consumidor" e remove a fila (também no trap).
# A senha do smoke-app é lida de ../rabbitmq/.env (só leitura) e vai ao cliente por variável de ambiente, nunca no argv.
# Uso (na raiz do projeto): ./scripts/smoke-rabbitmq.sh
set -euo pipefail
exec < /dev/null
cd "$(dirname "$0")/.."
BASE_URL="${GRAFANA_URL:-http://localhost:3000}"
RABBITMQ_ENV="${RABBITMQ_ENV:-../rabbitmq/.env}"
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
FIXTURE_IMAGE="workspace/grafana-amqp-fixture:local"
DASHBOARDS=(rabbitmq-overview rabbitmq-memory-allocators rabbitmq-log-shipper)
queue="smoke-consumer.grafana-$(date +%s)-${RANDOM}"
queue_created=false
failures=0
work="$(mktemp -d)"

check() { if [[ "$2" == true ]]; then echo "OK   $1"; else echo "FALHA $1"; failures=$((failures + 1)); fi; }
eq_if() { if [[ "$1" == "$2" ]]; then echo true; else echo false; fi; }
ok_if() { if "$@" >/dev/null 2>&1; then echo true; else echo false; fi; }
# O filtro por valor vai em FILTER_VALUE (env.FILTER_VALUE no jq); no container é repassado com -e.
jqs() { if command -v jq >/dev/null 2>&1; then jq "$@"; else docker run -i --rm -e FILTER_VALUE "$JQ_IMAGE" "$@"; fi; }

# Cliente AMQP descartável na rede workspace-messaging (a mesma dos clientes do broker). Uso: amqp fill|delete FILA [N]
amqp() {
  SMOKE_APP_PASSWORD="$smoke_password" timeout 120 docker run --rm -e SMOKE_APP_PASSWORD --network workspace-messaging \
    --read-only --cap-drop ALL --security-opt no-new-privileges --memory 128m "$FIXTURE_IMAGE" "$@"
}
cleanup() {
  if [[ "$queue_created" == true ]]; then amqp delete "$queue" >/dev/null 2>&1 || echo "AVISO fila ${queue} não foi removida (remova pela UI do broker)"; fi
  rm -rf "$work"
}
trap cleanup EXIT

set -a
# shellcheck disable=SC1091
source .env
set +a

# 0. Pré-requisitos.
grafana="$(docker compose ps -q grafana)"
prom="$(docker compose -f prometheus/docker-compose.metrics.yml ps -q prometheus 2>/dev/null || true)"
[[ -n "$grafana" ]] || { echo "FALHA container grafana não encontrado (docker compose up -d --build)"; exit 1; }
[[ -n "$prom" ]] || { echo "FALHA Prometheus não encontrado (suba o stack de métricas com o override do RabbitMQ)"; exit 1; }
health=starting
for _ in $(seq 1 40); do
  health="$(docker inspect -f '{{.State.Health.Status}}' "$grafana")"
  [[ "$health" == healthy ]] && break
  sleep 3
done
check "Grafana healthy" "$(eq_if "$health" healthy)"
check "rede rabbitmq-metrics existe (broker de pé)" "$(ok_if docker network inspect rabbitmq-metrics)"
[[ -f "$RABBITMQ_ENV" ]] || { echo "FALHA ${RABBITMQ_ENV} não encontrado (senha do smoke-app)"; exit 1; }
smoke_password="$(sed -n 's/^RABBITMQ_SMOKE_APP_PASSWORD=//p' "$RABBITMQ_ENV")"
[[ -n "$smoke_password" ]] || { echo "FALHA RABBITMQ_SMOKE_APP_PASSWORD vazio em ${RABBITMQ_ENV}"; exit 1; }

# 1. Rede: só o Prometheus entra na rabbitmq-metrics (o Grafana não) e nenhuma porta nova no host.
members="$(docker network inspect rabbitmq-metrics -f '{{range .Containers}}{{.Name}} {{end}}')"
check "Prometheus está na rede rabbitmq-metrics (override docker-compose.rabbitmq.yml)" \
  "$([[ "$members" == *grafana-metrics-prometheus* ]] && echo true || echo false)"
check "Grafana NÃO está na rede rabbitmq-metrics (lê só o Prometheus)" "$([[ "$members" != *grafana-grafana* ]] && echo true || echo false)"
check "Prometheus continua sem porta publicada no host" "$(eq_if "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$prom")" '{}')"

# 2. Alvos do Prometheus (até ~100 s após um restart).
prom_up() {
  local got=""
  for _ in $(seq 1 25); do
    got="$(docker exec "$prom" wget -qO- "http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22$1%22%7D" 2>/dev/null \
      | sed -n 's/.*"value":\[[0-9.]*,"\([^"]*\)"\].*/\1/p')"
    [[ "$got" == 1 ]] && break
    sleep 4
  done
  echo "$got"
}
check "alvo rabbitmq (rabbitmq:15692/metrics) UP no Prometheus" "$(eq_if "$(prom_up rabbitmq)" 1)"
check "alvo rabbitmq-log-shipper (log-shipper:2020/api/v2/metrics/prometheus) UP no Prometheus" "$(eq_if "$(prom_up rabbitmq-log-shipper)" 1)"

# 3. Grafana: sessão do break-glass (senha por stdin, nunca no argv) e API autenticada.
jar="${work}/admin.jar"
printf '{"user":"%s","password":"%s"}' "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD" \
  | curl -s -o /dev/null --max-time 10 -c "$jar" -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login"
gapi() {
  local method="$1" path="$2"
  shift 2
  curl -s --max-time 30 -X "$method" -b "$jar" -H "Origin: ${BASE_URL}" -H 'Content-Type: application/json' "$@" "${BASE_URL}${path}"
}
# Consulta PromQL instantânea pelo /api/ds/query (como o painel/regra faria). O corpo é montado pelo jq (escapa aspas e "\").
ds_instant() {
  local now
  now="$(date +%s)000"
  # shellcheck disable=SC2016  # $e/$from/$to são variáveis do jq, não do shell.
  jqs -nc --arg e "$1" --arg from "$((now - 300000))" --arg to "$now" \
    '{from: $from, to: $to, queries: [{refId: "A", datasource: {type: "prometheus", uid: "prometheus"}, expr: $e, instant: true, range: false}]}' \
    | gapi POST /api/ds/query --data-binary @-
}

# 4. Dashboards provisionados na pasta rabbitmq e TODAS as consultas executadas pelo Grafana, com as variáveis do dashboard
# resolvidas a partir do rabbitmq_identity_info real ($namespace vazio: o broker não roda em Kubernetes).
identity="$(ds_instant 'rabbitmq_identity_info{job="rabbitmq"}' | jqs -r '.results.A.frames[0].schema.fields[1].labels // {} | "\(.rabbitmq_cluster // "")|\(.rabbitmq_node // "")|\(.rabbitmq_endpoint // "")"')"
IFS='|' read -r cluster node endpoint <<< "$identity"
check "rabbitmq_identity_info lido pelo Grafana (cluster ${cluster:-?}, endpoint ${endpoint:-?})" "$([[ -n "$cluster" && -n "$node" ]] && echo true || echo false)"
check "Erlang-Distribution (11352) não provisionado: broker single-node sem séries erlang_vm_dist_* (ADR-0005)" \
  "$(eq_if "$(gapi GET '/api/search?query=Distribui' | jqs -r '[.[] | select(.type == "dash-db" and (.folderTitle // "") == "rabbitmq")] | length')" 0)"
for uid in "${DASHBOARDS[@]}"; do
  gapi GET "/api/dashboards/uid/${uid}" > "${work}/${uid}.json"
  check "dashboard ${uid} provisionado na pasta rabbitmq (somente leitura)" \
    "$(jqs -r '.meta.folderTitle == "rabbitmq" and .meta.provisioned == true and .dashboard.editable == false' < "${work}/${uid}.json")"
  now="$(date +%s)000"
  # Um corpo de /api/ds/query por alvo (linha JSON); variáveis do dashboard trocadas; $__rate_interval/$__range ficam com o Grafana.
  # shellcheck disable=SC2016  # $cluster/$node/... são variáveis do jq, não do shell.
  jqs -c --arg cluster "$cluster" --arg node "$node" --arg endpoint "$endpoint" --arg from "$((now - 1800000))" --arg to "$now" '
    [.dashboard.panels[] | ., (.panels[]?)] | .[] | select(.targets) | .title as $t | .targets[] | select((.expr // "") != "")
    | {title: $t, body: {from: $from, to: $to, queries: [{refId: "A", datasource: {type: "prometheus", uid: "prometheus"},
        expr: (.expr | gsub("\\$namespace"; "") | gsub("\\$rabbitmq_cluster"; $cluster) | gsub("\\$rabbitmq_node"; $node)
          | gsub("\\$endpoint"; $endpoint) | gsub("\\$memory_allocator"; "binary_alloc")),
        instant: (.instant // false), range: ((.instant // false) | not), format: (.format // "time_series"),
        intervalMs: 15000, maxDataPoints: 200}]}}' < "${work}/${uid}.json" > "${work}/${uid}.queries"
  # Corpos e títulos em arquivos separados (uma chamada de jq cada; o laço só chama o curl).
  jqs -c '.body' < "${work}/${uid}.queries" > "${work}/${uid}.bodies"
  jqs -r '.title' < "${work}/${uid}.queries" > "${work}/${uid}.titles"
  total=0; errors=0; with_data=0; empty_titles=""
  while IFS= read -r body && IFS= read -r title <&3; do
    total=$((total + 1))
    printf '%s' "$body" | gapi POST /api/ds/query -o "${work}/resp.json" -w '%{http_code}' --data-binary @- > "${work}/code" || true
    if [[ "$(cat "${work}/code")" != 200 ]] || grep -q '"error":' "${work}/resp.json"; then
      errors=$((errors + 1)); echo "     erro na consulta do painel \"${title}\""
    elif grep -qE '"values":\[\[[-0-9]' "${work}/resp.json"; then
      with_data=$((with_data + 1))
    else
      empty_titles="${empty_titles}${title}; "
    fi
  done < "${work}/${uid}.bodies" 3< "${work}/${uid}.titles"
  check "${uid}: ${total} consultas executadas pelo Grafana sem erro (${errors} com erro)" "$([[ $total -gt 0 && $errors -eq 0 ]] && echo true || echo false)"
  # Painéis sem dados são os de eventos que não ocorrem num broker ocioso (ex.: mensagens não roteadas); a maioria tem dados.
  check "${uid}: ${with_data}/${total} consultas devolvem dados (mínimo 70%)" "$([[ $total -gt 0 && $((with_data * 100 / total)) -ge 70 ]] && echo true || echo false)"
  [[ -z "$empty_titles" ]] || echo "     sem dados agora: ${empty_titles}"
done

# 5. Regras de alerta: carregadas por arquivo, rótulos, avaliação sem erro e alvos-fora em Normal (sem falso positivo).
rules="$(gapi GET /api/v1/provisioning/alert-rules)"
check "13 regras rabbitmq-* carregadas por arquivo na pasta rabbitmq, com project=rabbitmq e severity" \
  "$(jqs -r '[.[] | select(.uid | startswith("rabbitmq-"))] | length == 13 and all(.provenance == "file" and .labels.project == "rabbitmq" and (.labels.severity | IN("warning", "critical")) and .ruleGroup == "rabbitmq")' <<< "$rules")"
check "regras de alvo fora (broker e coletor) tratam ausência de série como alerta (noDataState Alerting)" \
  "$(jqs -r '[.[] | select(.uid == "rabbitmq-broker-down" or .uid == "rabbitmq-log-shipper-down") | select(.noDataState == "Alerting")] | length == 2' <<< "$rules")"
group_health() { gapi GET /api/prometheus/grafana/api/v1/rules | jqs -r '[.data.groups[]? | select(.name == "rabbitmq") | .rules[]?] | "\(length) \([.[] | select(.health != "ok")] | length)"'; }
health=""
for _ in $(seq 1 18); do
  health="$(group_health)"
  [[ "$health" == "13 0" ]] && break
  sleep 10
done
check "as 13 regras do RabbitMQ avaliam com saúde ok contra o Prometheus (${health:-?} = total/não-ok)" "$(eq_if "$health" "13 0")"
rule_state() { gapi GET /api/prometheus/grafana/api/v1/rules | FILTER_VALUE="$1" jqs -r '[.data.groups[]?.rules[]? | select(.name == env.FILTER_VALUE)][0].state // ""'; }
# Espera (até 2 min) a regra ficar em Normal; imprime o último estado lido.
wait_inactive() {
  local got=""
  for _ in $(seq 1 12); do
    got="$(rule_state "$1")"
    [[ "$got" == inactive ]] && break
    sleep 10
  done
  echo "$got"
}
for title in "RabbitMQ - Broker fora do ar" "RabbitMQ - Coletor de logs fora do ar"; do
  got="$(wait_inactive "$title")"
  check "\"${title}\" em Normal com o alvo no ar (sem falso positivo; obtido: ${got:-nenhum})" "$(eq_if "$got" inactive)"
done

# 6. Mutation check: estado real no broker (fila sem consumidor com mensagens) -> expressão da regra REAL acusa a fila ->
# regra fica Pending com uma instância para a fila -> fila removida -> expressão deixa de acusar.
rule_expr() { sed -n "/uid: $1\$/,/expr:/{s/^ *expr: '\\(.*\\)'\$/\\1/p}" provisioning/alerting/rules.yaml; }
no_consumer_expr="$(rule_expr rabbitmq-queue-without-consumer)"
dlq_expr="$(rule_expr rabbitmq-dlq-not-empty)"
growing_expr="$(rule_expr rabbitmq-queue-growing)"
check "expressões das regras reais extraídas do rules.yaml" "$([[ -n "$no_consumer_expr" && -n "$dlq_expr" && -n "$growing_expr" ]] && echo true || echo false)"
# Valor que a expressão devolve para a fila de teste ("" se ela não aparece).
expr_value_for_queue() {
  ds_instant "$1" | FILTER_VALUE="$queue" jqs -r '[.results.A.frames[]? | select(.schema.fields[1].labels.queue == env.FILTER_VALUE) | .data.values[1][0]][0] // ""'
}
wait_expr() {  # wait_expr EXPR ESPERADO ("" = ausente): espera até ~100 s
  local got=""
  for _ in $(seq 1 20); do
    got="$(expr_value_for_queue "$1")"
    [[ "$got" == "$2" ]] && break
    sleep 5
  done
  echo "$got"
}
check "antes: a regra \"sem consumidor\" não acusa a fila ${queue}" "$(eq_if "$(expr_value_for_queue "$no_consumer_expr")" "")"
# Sempre reconstrói (cache do Docker): imagem antiga com o cliente desatualizado não passa despercebida.
docker build -q -t "$FIXTURE_IMAGE" tests/rabbitmq >/dev/null
queue_created=true
check "5 mensagens publicadas pelo smoke-app numa fila nova, sem consumidor" "$(ok_if amqp fill "$queue" 5)"
check "a expressão da regra \"sem consumidor\" acusa a fila com 5 mensagens prontas" "$(eq_if "$(wait_expr "$no_consumer_expr" 5)" 5)"
check "controle: a DLQ e \"fila crescendo\" (limiar 100) NÃO acusam a fila de teste" \
  "$([[ -z "$(expr_value_for_queue "$dlq_expr")" && -z "$(expr_value_for_queue "$growing_expr")" ]] && echo true || echo false)"
instance_state() {
  gapi GET /api/prometheus/grafana/api/v1/rules \
    | FILTER_VALUE="$queue" jqs -r '[.data.groups[]?.rules[]? | select(.name == "RabbitMQ - Fila com mensagens e sem consumidor") | .alerts[]? | select(.labels.queue == env.FILTER_VALUE) | .state][0] // ""'
}
state=""
for _ in $(seq 1 24); do
  state="$(instance_state)"
  [[ "${state,,}" == pending* || "${state,,}" == alerting* ]] && break
  sleep 10
done
check "regra \"RabbitMQ - Fila com mensagens e sem consumidor\" abre instância Pending para a fila (for 10m; obtido: ${state:-nenhum})" \
  "$([[ "${state,,}" == pending* || "${state,,}" == alerting* ]] && echo true || echo false)"
deleted="$(ok_if amqp delete "$queue")"
[[ "$deleted" == true ]] && queue_created=false
check "fila de teste removida" "$deleted"
check "depois: a expressão deixa de acusar a fila removida" "$(eq_if "$(wait_expr "$no_consumer_expr" "")" "")"

if [[ $failures -ne 0 ]]; then echo "smoke-rabbitmq: REPROVADO (${failures} falha(s))"; exit 1; fi
echo "smoke-rabbitmq: APROVADO"
