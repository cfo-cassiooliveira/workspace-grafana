#!/usr/bin/env bash
# Teste estático da observabilidade do RabbitMQ (ADR-0005): dashboards oficiais importados (revisão fixada, datasource
# provisionado, sem variável de datasource), dashboard do coletor de logs, jobs do Prometheus, override de rede e as 13 regras.
# Uso: ./tests/dashboards/rabbitmq.test.sh
# Usa o jq local ou, na falta dele, a imagem pinada ghcr.io/jqlang/jq via Docker (mesma do lint-dashboards.sh).
set -euo pipefail

cd "$(dirname "$0")/../.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
DIR="provisioning/dashboards/rabbitmq"
RULES="provisioning/alerting/rules.yaml"
PROM="prometheus/prometheus.yml"
OVERRIDE="prometheus/docker-compose.rabbitmq.yml"
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FALHA $*"; fail=1; }

# Todos os dashboards num único jq (um container só, se não houver jq local): objeto {arquivo: dashboard}.
all_json() {
  if command -v jq >/dev/null 2>&1; then jq -n '[inputs | {(input_filename | split("/") | last): .}] | add' "$DIR"/*.json
  else MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/w:ro" -w /w "$JQ_IMAGE" \
    -n '[inputs | {(input_filename | split("/") | last): .}] | add' "$DIR"/*.json; fi
}
jqs() { if command -v jq >/dev/null 2>&1; then jq "$@"; else docker run -i --rm "$JQ_IMAGE" "$@"; fi; }
for f in "$DIR/overview.json" "$DIR/memory-allocators.json" "$DIR/log-shipper.json" "$RULES" "$PROM" "$OVERRIDE"; do
  [[ -f "$f" ]] || { echo "FALHA arquivo ausente: $f"; exit 1; }
done
data="$(all_json)"
# expect "descrição" "<filtro jq sobre {arquivo: dashboard} que devolve true>"
expect() {
  local res
  res="$(jqs -r "$2" <<< "$data")" || { bad "$1 (jq falhou)"; return; }
  if [[ "$res" == "true" ]]; then ok "$1"; else bad "$1"; fi
}
expect_grep() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1"; fi; }
expect_no_grep() { if grep -qF -- "$2" "$3"; then bad "$1"; else ok "$1"; fi; }

# Dashboards
expect "três dashboards, uids e títulos esperados" \
  '(keys == ["log-shipper.json","memory-allocators.json","overview.json"]) and .["overview.json"].uid == "rabbitmq-overview" and .["overview.json"].title == "RabbitMQ - Visão geral" and .["memory-allocators.json"].uid == "rabbitmq-memory-allocators" and .["log-shipper.json"].uid == "rabbitmq-log-shipper" and .["log-shipper.json"].title == "RabbitMQ - Coletor de logs"'
expect "importados sem metadados de importação (__inputs/__requires) nem id, editable:false" \
  'all(.[]; (has("__inputs") or has("__requires") or has("__elements") or has("id")) | not) and all(.[]; .editable == false)'
expect "nenhuma variável do tipo datasource (o uid é fixo: prometheus)" 'all(.[]; all(.templating.list[]?; .type != "datasource"))'
expect "nenhuma referência a \${DS_PROMETHEUS} sobrou" '[.. | strings | select(contains("DS_PROMETHEUS"))] | length == 0'
expect "todo datasource de painel/alvo/variável é o prometheus (ou o embutido do Grafana)" \
  '[.. | objects | select(has("datasource")) | .datasource | select(type != "object" or ((.uid != "prometheus") and (.uid != "grafana") and (.uid != "-- Grafana --")))] | length == 0'
expect "origem registrada na descrição (id e revisão do grafana.com)" \
  '(.["overview.json"].description | contains("10991") and contains("15")) and (.["memory-allocators.json"].description | contains("11350") and contains("8"))'
expect "nenhum painel do tipo logs" '[.. | objects | select(.type? == "logs")] | length == 0'
expect "coletor de logs: backlog, retentativas esgotadas, descartes e up do job rabbitmq-log-shipper" \
  '[.["log-shipper.json"].panels[].targets[].expr] | (any(contains("fluentbit_storage_fs_chunks"))) and (any(contains("fluentbit_output_retries_failed_total"))) and (any(contains("fluentbit_output_dropped_records_total"))) and (any(startswith("max(up{job=\"rabbitmq-log-shipper\"}")))'
expect "coletor de logs: todo painel com descrição e estado vazio em PT-BR" \
  'all(.["log-shipper.json"].panels[]; (.description | length) > 0 and .fieldConfig.defaults.noValue == "Sem dados")'

# Prometheus e rede
expect_grep "job rabbitmq em rabbitmq:15692" '- targets: ["rabbitmq:15692"]' "$PROM"
expect_grep "job rabbitmq-log-shipper com o caminho do Fluent Bit" 'metrics_path: /api/v2/metrics/prometheus' "$PROM"
expect_grep "alvo log-shipper:2020" '- targets: ["log-shipper:2020"]' "$PROM"
expect_grep "override entra na rede externa rabbitmq-metrics" 'external: true' "$OVERRIDE"
expect_no_grep "override não publica porta no host" 'ports:' "$OVERRIDE"
expect_no_grep "compose base de métricas NÃO depende da rede do broker" 'rabbitmq-metrics' prometheus/docker-compose.metrics.yml

# Regras (YAML): grupo próprio, 13 regras, rótulos e filtros.
# Trecho do grupo rabbitmq: da linha "name: rabbitmq" até o próximo grupo (ou o fim do arquivo).
group="$(awk '/^    name: /{in_group = ($2 == "rabbitmq")} /^  - orgId:/{in_group = 0} in_group' "$RULES")"
count="$(grep -c '^      - uid: rabbitmq-' <<< "$group" || true)"
if [[ "$count" == 13 ]]; then ok "13 regras no grupo rabbitmq"; else bad "13 regras no grupo rabbitmq (achou ${count})"; fi
expect_grep "grupo na pasta rabbitmq" "    folder: rabbitmq" "$RULES"
if [[ "$(grep -c '^          project: rabbitmq$' <<< "$group")" == 13 ]]; then ok "toda regra com project: rabbitmq"; else bad "toda regra com project: rabbitmq"; fi
for uid in rabbitmq-broker-down rabbitmq-queue-growing rabbitmq-queue-without-consumer rabbitmq-dlq-not-empty rabbitmq-retry-stuck rabbitmq-memory-high \
  rabbitmq-memory-alarm rabbitmq-disk-low rabbitmq-disk-alarm rabbitmq-log-shipper-down rabbitmq-log-shipper-backlog \
  rabbitmq-log-shipper-output-failure rabbitmq-log-shipper-dropping; do
  expect_grep "regra ${uid}" "uid: ${uid}" "$RULES"
done
expect_grep "broker fora: up == 0 OU série ausente" 'sum(absent(up{job="rabbitmq"}) or vector(0)) + sum(count(up{job="rabbitmq"} == 0) or vector(0))' "$RULES"
expect_grep "sem consumidor exclui as DLQs e as filas de retry" 'queue!~".*\\.(dlq|retry)"} > 0 and on(vhost, queue) rabbitmq_queue_consumers{job="rabbitmq"} == 0' "$RULES"
expect_grep "fila crescendo exclui as DLQs" 'deriv(rabbitmq_queue_messages_ready{job="rabbitmq",queue!~".*\\.dlq"}[15m]) > 0' "$RULES"
expect_grep "DLQ só nas filas *.dlq" 'rabbitmq_queue_messages_ready{job="rabbitmq",queue=~".*\\.dlq"}) > 0' "$RULES"
expect_grep "alarmes de memória e disco do broker" 'rabbitmq_alarms_free_disk_space_watermark{job="rabbitmq"} == 1' "$RULES"
expect_grep "alarme de memória do broker" 'rabbitmq_alarms_memory_used_watermark{job="rabbitmq"} == 1' "$RULES"
# O Grafana 13.3 recusa a regra (e derruba o provisioning inteiro) se __dashboardUid__ vier sem __panelId__.
if [[ "$(grep -c '__dashboardUid__: ' <<< "$group")" == 13 && "$(grep -c '__panelId__: "[0-9]*"' <<< "$group")" == 13 ]]; then ok "toda regra com __dashboardUid__ E __panelId__"
else bad "toda regra com __dashboardUid__ E __panelId__ (o Grafana não sobe sem o par)"; fi
if [[ "$(grep -c 'noDataState: Alerting' <<< "$group")" == 2 ]]; then ok "só as regras de alvo fora tratam ausência como alerta"; else bad "só as regras de alvo fora tratam ausência como alerta"; fi

if [[ $fail -eq 0 ]]; then echo "rabbitmq: APROVADO"; else echo "rabbitmq: REPROVADO"; exit 1; fi
