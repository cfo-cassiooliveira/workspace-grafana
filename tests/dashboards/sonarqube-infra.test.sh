#!/usr/bin/env bash
# Teste estático do dashboard "SonarQube - Infra" (T13): uid, ausência de painel logs e de campos pessoais,
# só agregações (métrica count), datasource provisionado, estado vazio em PT-BR e drill-down ao Graylog sem credenciais.
# Uso: ./tests/dashboards/sonarqube-infra.test.sh
# Usa o jq local ou, na falta dele, a imagem pinada ghcr.io/jqlang/jq via Docker (mesma do lint-dashboards.sh).
FILE="provisioning/dashboards/sonarqube/infra.json"
set -euo pipefail

cd "$(dirname "$0")/../.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"

# Executa o jq sobre o dashboard com o filtro recebido; devolve "true"/"false".
check() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1" "$FILE"
  else
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/w:ro" -w /w "$JQ_IMAGE" -r "$1" "$FILE"
  fi
}

fail=0
# expect "<descrição>" '<filtro jq booleano>'
expect() {
  local result
  result="$(check "$2")"
  if [[ "$result" == "true" ]]; then echo "OK   $1"; else echo "FALHA $1"; fail=1; fi
}

[[ -f "$FILE" ]] || { echo "FALHA $FILE não existe"; exit 1; }

expect "uid sonarqube-infra e título em PT-BR" '.uid == "sonarqube-infra" and .title == "SonarQube - Infra"'
expect "sem id, editable:false, sem variáveis (YAGNI), atualização de 1 min" '(has("id") | not) and .editable == false and (.templating.list | length) == 0 and .refresh == "1m"'
expect "nenhum painel do tipo logs" '[.. | objects | select(.type? == "logs")] | length == 0'
expect "todo painel tem título e descrição" '(.panels | length) > 0 and all(.panels[]; (.title | length) > 0 and (.description | length) > 0)'
expect "todo painel usa o datasource graylog-opensearch" 'all(.panels[]; .datasource.uid == "graylog-opensearch" and all(.targets[]; .datasource.uid == "graylog-opensearch"))'
expect "só agregações: toda métrica é count (nunca raw_data/logs)" '[.panels[].targets[].metrics[]?.type] | (length > 0) and all(. == "count")'
expect "toda consulta tem agrupamento (date_histogram ou terms)" 'all(.panels[].targets[]; (.bucketAggs | length) > 0)'
expect "agrupamentos só por timestamp, level_name ou service_name" '[.panels[].targets[].bucketAggs[] | .field] | all(. == "timestamp" or . == "level_name" or . == "service_name")'
expect "nenhum campo pessoal nas consultas" '[.panels[].targets[] | (.query, (.bucketAggs[]? | .field // empty)) | strings | select(test("(^|[^a-z0-9])(cpf|cnpj|e-?mail|masked_login|phone|celular|telefone|user_?name|preferred_username|login|token|password|full_?name|first_?name|last_?name)([^a-z0-9]|$)"; "i"))] | length == 0'
expect "estado vazio em PT-BR em todos os painéis" 'all(.panels[]; (.fieldConfig.defaults.noValue | type == "string" and length > 0))'
expect "drill-down ao Graylog local sem credenciais" '[.links[].url] | (length > 0) and all(startswith("http://localhost:9000/") and (test("@") | not))'
expect "painéis sem coordenadas fora da grade de 24 colunas" 'all(.panels[]; .gridPos.x + .gridPos.w <= 24 and .gridPos.w > 0)'

expect "cobre erros (level <= 3), avisos (level 4) e reinícios (SonarQube is operational)" '(any(.panels[].targets[]; .query | contains("level:[0 TO 3]"))) and (any(.panels[].targets[]; .query | contains("level:4"))) and (any(.panels[].targets[]; .query | contains("SonarQube is operational")))'
expect "só os serviços sonarqube e sonarqube-db" '[.panels[].targets[].query | select(test("service_name:"))] | all(test("service_name:([(]sonarqube OR sonarqube-db[)]|sonarqube)( |$)"))'

expect "títulos dos stats de w=6 curtos (<= 20 caracteres) para não serem cortados" '[.panels[] | select(.type == "stat" and .gridPos.w <= 6) | .title | length] | all(. <= 20)'

if [[ $fail -eq 0 ]]; then echo "sonarqube-infra: APROVADO"; else echo "sonarqube-infra: REPROVADO"; exit 1; fi
