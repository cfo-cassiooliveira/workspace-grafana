#!/usr/bin/env bash
# Teste do dashboard "Keycloak - Autenticação" (T12): uid, ausência de painel logs/campos pessoais/masked_login
# e somente agregações. Usa o jq local ou a imagem jq pinada via Docker (a mesma do lint-dashboards.sh).
# Uso: ./tests/dashboards/keycloak-authentication.test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
FILE="provisioning/dashboards/keycloak/authentication.json"
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FALHA $*"; fail=1; }

jqr() {
  if command -v jq >/dev/null 2>&1; then jq "$@" "$FILE"
  else MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/w:ro" -w /w "$JQ_IMAGE" "$@" "$FILE"; fi
}
# expect "descrição" "<filtro jq que devolve true>"
expect() {
  local desc="$1" res
  res="$(jqr -r "$2")" || { bad "$desc (jq falhou)"; return; }
  if [[ "$res" == "true" ]]; then ok "$desc"; else bad "$desc"; fi
}

[[ -f "$FILE" ]] || { echo "FALHA arquivo ausente: $FILE"; exit 1; }
expect "uid é keycloak-authentication" '.uid == "keycloak-authentication"'
expect "título é Keycloak - Autenticação" '.title == "Keycloak - Autenticação"'
expect "editable false e sem id" '(.editable == false) and (has("id") | not)'
expect "tem painéis" '(.panels | length) > 0'
expect "nenhum painel do tipo logs" '[.. | objects | select(.type? == "logs")] | length == 0'
expect "nenhum campo pessoal/masked_login nas consultas" \
  '[.panels[].targets[]? | .. | strings | select(test("masked_login|e-?mail|user_?name|preferred_username|ip_?addr|(^|[^a-z])ip([^a-z]|$)|cpf|cnpj|user_id"; "i"))] | length == 0'
expect "somente agregações: todo alvo tem bucketAggs e só métrica count" \
  '[.panels[].targets[]? | select(((.bucketAggs // []) | length) == 0 or ([.metrics[]?.type] | all(. == "count") | not))] | length == 0'
expect "painéis só dos tipos stat/timeseries/table" '[.panels[].type] | all(. == "stat" or . == "timeseries" or . == "table")'
expect "todos os painéis usam o datasource graylog-opensearch" '[.panels[].datasource.uid] | all(. == "graylog-opensearch")'
expect "todos os painéis têm noValue em PT-BR" '[.panels[].fieldConfig.defaults.noValue // ""] | all(startswith("Sem "))'
expect "cobre sucesso, falha, rajada, tipo, cliente e realm" \
  '[.panels[].title] | join("|") | ascii_downcase | [contains("sucesso"), contains("falha"), contains("rajada"), contains("tipo"), contains("cliente"), contains("realm")] | all'
expect "link de drill-down ao Graylog sem credenciais" \
  '[.links[].url] | any(test("^http://localhost:9000/") and (test("@") | not) and (test("password|token|secret"; "i") | not))'

expect "links do Graylog usam relative= (e não from=) como nos demais dashboards" '[.links[].url | select(startswith("http://localhost:9000/"))] | (length > 0) and all(contains("relative=21600") and (contains("from=") | not))'
expect "tabelas (tipo, cliente, realm) quebram linha e reservam largura mínima da 1ª coluna (sem truncar RESET_PASSWORD_ERROR/UUID)" '[.panels[] | select(.type == "table")] | (length == 3) and all(.[]; (.fieldConfig.defaults.custom.cellOptions.wrapText == true) and (.fieldConfig.overrides[0].properties[0].id == "custom.minWidth") and (.fieldConfig.overrides[0].properties[0].value >= 180))'

# Rodada 3: a coluna de contagem não pode ser cortada em 1440 px.
expect "tabelas por tipo/cliente/realm: coluna Eventos com largura fixa e 1ª coluna com mínimo <= 200" '[.panels[] | select(.type == "table")] | (length == 3) and all(.[]; ([.fieldConfig.overrides[] | select(.matcher.options == "Eventos") | .properties[] | select(.id == "custom.width") | .value] | .[0] >= 80) and (.fieldConfig.overrides[0].properties[0].value <= 200))'

if [[ $fail -eq 0 ]]; then echo "keycloak-authentication: APROVADO"; else echo "keycloak-authentication: REPROVADO"; exit 1; fi
