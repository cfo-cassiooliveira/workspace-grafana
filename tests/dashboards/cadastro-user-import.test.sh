#!/usr/bin/env bash
# Teste estático do dashboard "Cadastro - Importação em lote" (spec 002 do rabbitmq, O1): filas reais da importação no
# vhost dev, só métricas que o scrape do broker já expõe (nenhuma métrica nova na aplicação) e estados tratados.
# Complementa o scripts/lint-dashboards.sh (regras gerais). Usa o jq local ou a imagem pinada via Docker.
# Uso: ./tests/dashboards/cadastro-user-import.test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
DASHBOARD="provisioning/dashboards/cadastro/user-import.json"
[[ -f "$DASHBOARD" ]] || { echo "FALHA arquivo ausente: $DASHBOARD"; exit 1; }

run_jq() {
  if command -v jq >/dev/null 2>&1; then
    jq "$@" "$DASHBOARD"
  else
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/w:ro" -w /w "$JQ_IMAGE" "$@" "$DASHBOARD"
  fi
}

fail=0
# check "<descrição>" '<filtro jq que deve devolver true>' (EXPRS = todas as expressões PromQL)
check() {
  local name="$1" filter="$2" result
  result="$(run_jq -r "def EXPRS: [.panels[].targets[].expr]; $filter")"
  if [[ "$result" == "true" ]]; then echo "OK    $name"; else echo "FALHA $name"; fail=1; fi
}

check "uid, título em PT-BR, editable false, sem id" \
  '.uid == "cadastro-user-import" and .title == "Cadastro - Importação em lote" and .editable == false and (has("id") | not)'
check "datasource só prometheus (ou o embutido do Grafana)" \
  '[.. | objects | select(has("datasource")) | .datasource | select(.uid != "prometheus" and .uid != "-- Grafana --")] | length == 0'
check "nenhum painel do tipo logs" '[.. | objects | select(.type? == "logs")] | length == 0'
check "todo painel tem título, descrição e estado vazio em PT-BR" \
  'all(.panels[]; (.title | length) > 0 and (.description | length) > 0 and .fieldConfig.defaults.noValue == "Sem dados")'
check "ids de painel únicos" '[.panels[].id] | length == (unique | length)'
check "títulos dos cartões com até 18 caracteres" '[.panels[] | select(.type == "stat" and (.title | length > 18))] | length == 0'
check "toda consulta usa job rabbitmq" 'EXPRS | length > 0 and all(contains("job=\"rabbitmq\""))'
check "toda consulta fixa o vhost dev (vhost ou queue_vhost)" 'EXPRS | all(contains("vhost=\"dev\""))'
check "só as três filas da importação, pelo nome exato" \
  '[EXPRS[] | scan("queue=\"([^\"]*)\"") | .[0]] | unique == ["cadastro.user-import-lines","cadastro.user-import-lines.dlq","cadastro.user-import-lines.retry"]'
check "só métricas já expostas pelo rabbitmq_prometheus (nenhuma métrica da aplicação)" \
  '[EXPRS[] | scan("([a-z_]+)[{]") | .[0]] | unique == ["rabbitmq_queue_consumers","rabbitmq_queue_exchange_messages_published_total","rabbitmq_queue_messages_acked_total","rabbitmq_queue_messages_delivered_ack_total","rabbitmq_queue_messages_ready","rabbitmq_queue_messages_unacked"]'
# A métrica agregada por exchange não depende de canal aberto (a por canal some quando o publicador desconecta).
check "publicadas vêm da métrica agregada e somam as exchanges; todas filtram por vhost" \
  'EXPRS | all(contains(",vhost=\"dev\"") and (if contains("published_total") then startswith("sum(rate(rabbitmq_queue_exchange_messages_published_total{") else true end))'
# shellcheck disable=SC2016  # $__rate_interval é variável do Grafana, não do shell.
check "contadores sempre com rate" \
  '[EXPRS[] | select(contains("_total"))] | length == 4 and all(contains("rate(") and contains("[$__rate_interval]"))'
check "cartões de prontas, não confirmadas, consumidores e DLQ" \
  '[.panels[] | select(.type == "stat") | .title] == ["Prontas","Não confirmadas","Consumidores","Na DLQ"]'
check "cartões ficam vermelhos no problema (0 consumidores; 1 ou mais na DLQ)" \
  '(.panels[] | select(.title == "Consumidores") | .fieldConfig.defaults.thresholds.steps == [{"color":"red","value":null},{"color":"green","value":1}]) and (.panels[] | select(.title == "Na DLQ") | .fieldConfig.defaults.thresholds.steps == [{"color":"green","value":null},{"color":"red","value":1}])'

if [[ $fail -eq 0 ]]; then echo "cadastro-user-import.test: APROVADO"; else echo "cadastro-user-import.test: REPROVADO"; exit 1; fi
