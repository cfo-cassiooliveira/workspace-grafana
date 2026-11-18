#!/usr/bin/env bash
# Teste estático do dashboard "Plataforma - Saúde das APIs" (T17) e das regras de alerta de saúde das APIs:
# uid, datasource prometheus, filtro que exclui project="smoke", regras gravadas de disponibilidade 24h/7d/30d,
# estado UP/DOWN dos 4 endpoints e a distinção "API fora do ar" x "alvo não resolve (DNS)" nas regras.
# Uso: ./tests/dashboards/api-health.test.sh
# Usa o jq local ou, na falta dele, a imagem pinada ghcr.io/jqlang/jq via Docker (mesma do lint-dashboards.sh).
set -euo pipefail

cd "$(dirname "$0")/../.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
FILE="provisioning/dashboards/graylog/api-health.json"
RULES="provisioning/alerting/rules.yaml"
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FALHA $*"; fail=1; }

jqr() {
  if command -v jq >/dev/null 2>&1; then jq "$@" "$FILE"
  else MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/w:ro" -w /w "$JQ_IMAGE" "$@" "$FILE"; fi
}
# expect "descrição" "<filtro jq que devolve true>"
expect() {
  local res
  res="$(jqr -r "$2")" || { bad "$1 (jq falhou)"; return; }
  if [[ "$res" == "true" ]]; then ok "$1"; else bad "$1"; fi
}
# expect_grep "descrição" <padrão fixo> <arquivo>
expect_grep() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1"; fi; }

[[ -f "$FILE" ]] || { echo "FALHA arquivo ausente: $FILE"; exit 1; }
[[ -f "$RULES" ]] || { echo "FALHA arquivo ausente: $RULES"; exit 1; }

expect "uid api-health e título em PT-BR" '.uid == "api-health" and .title == "Plataforma - Saúde das APIs"'
expect "sem id, editable:false, sem variáveis, atualização de 1 min" '(has("id") | not) and .editable == false and (.templating.list | length) == 0 and .refresh == "1m"'
expect "todo painel tem título e descrição em PT-BR" '(.panels | length) > 0 and all(.panels[]; (.title | length) > 0 and (.description | length) > 0)'
expect "todo painel e alvo usam o datasource prometheus" 'all(.panels[]; .datasource.uid == "prometheus" and all(.targets[]; .datasource.uid == "prometheus"))'
expect "nenhum painel do tipo logs" '[.. | objects | select(.type? == "logs")] | length == 0'
expect "painéis só dos tipos stat/timeseries" 'all(.panels[]; .type == "stat" or .type == "timeseries")'
expect "toda consulta exclui as séries project=smoke (só séries reais)" 'all(.panels[].targets[]; .expr | contains("project!=\"smoke\""))'
expect "nenhuma consulta seleciona project=smoke" '[.panels[].targets[].expr | select(test("project=\"smoke\""))] | length == 0'
expect "painéis sem coordenadas fora da grade de 24 colunas" 'all(.panels[]; .gridPos.x + .gridPos.w <= 24 and .gridPos.w > 0)'
expect "todo painel tem estado vazio (noValue) em PT-BR" 'all(.panels[]; .fieldConfig.defaults.noValue | type == "string" and length > 0)'
expect "estado UP/DOWN mapeado de probe_success (1 = UP, 0 = DOWN)" \
  '[.panels[] | select(.targets[0].expr | startswith("probe_success")) | select(.fieldConfig.defaults.mappings[]?.options["1"]?.text == "UP")] | length >= 1'
expect "disponibilidade 24h, 7d e 30d usa as regras gravadas project_endpoint:probe_success:avg_over_time{24h,7d,30d}" \
  '[.panels[].targets[].expr] | (any(startswith("project_endpoint:probe_success:avg_over_time24h"))) and (any(startswith("project_endpoint:probe_success:avg_over_time7d"))) and (any(startswith("project_endpoint:probe_success:avg_over_time30d")))'
expect "latência (probe_duration_seconds) em segundos" \
  'any(.panels[]; (.targets[0].expr | test("probe_duration_seconds")) and .fieldConfig.defaults.unit == "s")'
expect "mostra se o alvo resolve (probe_ip_addr_hash), distinguindo DNS de API fora" \
  'any(.panels[]; (.targets[0].expr | contains("probe_ip_addr_hash")) and ([.fieldConfig.defaults.mappings[]?.options["0"]?.text] | any(. == "Não resolve")))'

expect "histórico de estado destaca o DOWN: cor por limiar (vermelho abaixo de 1), linha grossa e legenda com mínimo" '[.panels[] | select(.title | startswith("Histórico do estado"))] | (length == 1) and (.[0] | .fieldConfig.defaults.color.mode == "thresholds" and .fieldConfig.defaults.thresholds.steps[0].color == "red" and .fieldConfig.defaults.thresholds.steps[1].color == "green" and .fieldConfig.defaults.custom.lineWidth >= 3 and (.options.legend.calcs | index("min") != null))'

# Regras de alerta (YAML): duas regras de saúde, com rótulo failure_kind distinto, e o mesmo filtro de séries reais.
expect_grep "regra api-down (API fora do ar) existe" "uid: api-down" "$RULES"
expect_grep "regra api-target-unresolved (DNS) existe" "uid: api-target-unresolved" "$RULES"
expect_grep "rótulo failure_kind: api_down" "failure_kind: api_down" "$RULES"
expect_grep "rótulo failure_kind: dns" "failure_kind: dns" "$RULES"
expect_grep "API fora = probe_success 0 com IP resolvido (probe_ip_addr_hash > 0)" 'probe_ip_addr_hash{job="api-health",endpoint="ready",project!="smoke"} > 0)' "$RULES"
expect_grep "DNS = probe_success 0 com IP zerado (probe_ip_addr_hash == 0)" 'probe_ip_addr_hash{job="api-health",endpoint="ready",project!="smoke"} == 0)' "$RULES"
expect_grep "regras de saúde leem o datasource prometheus" "datasourceUid: prometheus" "$RULES"

# Rodada 3: uma série por alvo (project/endpoint); instances antigos não duplicam a legenda.
expect "latência e histórico agregam por project e endpoint (max by)" '[.panels[] | select(.type == "timeseries") | .targets[0].expr | select(startswith("max by (project, endpoint) ("))] | length == 2'
expect "histórico com altura para a legenda em tabela (h >= 10)" '[.panels[] | select(.title | startswith("Histórico do estado")) | select(.gridPos.h >= 10)] | length == 1'

if [[ $fail -eq 0 ]]; then echo "api-health: APROVADO"; else echo "api-health: REPROVADO"; exit 1; fi
