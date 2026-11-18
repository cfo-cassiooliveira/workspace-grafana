#!/usr/bin/env bash
# Teste estático do dashboard "Legado - Visão geral" (T11): uid, ausência de painel logs e de campos pessoais,
# só agregações (métrica count), datasource provisionado, estado vazio em PT-BR e drill-down ao Graylog sem credenciais.
# Uso: ./tests/dashboards/legado-overview.test.sh
# Usa o jq local ou, na falta dele, a imagem pinada ghcr.io/jqlang/jq via Docker (mesma do lint-dashboards.sh).
set -euo pipefail

cd "$(dirname "$0")/../.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
FILE="provisioning/dashboards/legado/overview.json"

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

expect "uid legado-overview e título em PT-BR" '.uid == "legado-overview" and .title == "Legado - Visão geral"'
expect "sem id, editable:false" '(has("id") | not) and .editable == false'
expect "nenhum painel do tipo logs" '[.. | objects | select(.type? == "logs")] | length == 0'
expect "tem painéis e todos têm título e descrição em PT-BR" '(.panels | length) > 0 and all(.panels[]; (.title | length) > 0 and (.description | length) > 0)'
expect "todo painel usa o datasource graylog-opensearch" 'all(.panels[]; .datasource.uid == "graylog-opensearch" and all(.targets[]; .datasource.uid == "graylog-opensearch"))'
expect "só agregações: toda métrica é count" '[.panels[].targets[].metrics[]?.type] | (length > 0) and all(. == "count")'
expect "toda consulta agrega por date_histogram (nunca documentos brutos)" 'all(.panels[].targets[]; any(.bucketAggs[]?; .type == "date_histogram"))'
expect "agrupamentos (terms) só por nível ou status" '[.panels[].targets[].bucketAggs[]? | select(.type == "terms") | .field] | all(. == "level_name" or . == "StatusCode")'
expect "nenhum campo pessoal nas consultas" '[.panels[].targets[] | (.query, (.bucketAggs[]? | .field // empty)) | strings | select(test("(^|[^a-z0-9])(cpf|cnpj|e-?mail|masked_login|phone|celular|telefone|user_?name|preferred_username|login|token|password|full_?name|first_?name|last_?name)([^a-z0-9]|$)"; "i"))] | length == 0'
expect "estado vazio em PT-BR em todos os painéis" 'all(.panels[]; .fieldConfig.defaults.noValue == "Sem dados no período selecionado")'
expect "cobre login falho e API interna por status" '(any(.panels[].targets[]; .query | contains("Sign-in failed"))) and (any(.panels[].targets[]; (.bucketAggs[]? | .field) == "StatusCode"))'
expect "drill-down ao Graylog local sem credenciais" '[.links[].url] | (length > 0) and all(startswith("http://localhost:9000/") and (test("@") | not))'
expect "links dos painéis também sem credenciais" '[.panels[].links[]?.url] | all(startswith("http://localhost:9000/") and (test("@") | not))'
expect "sem variáveis (YAGNI) e atualização de 1 min" '(.templating.list | length) == 0 and .refresh == "1m"'

expect "RequestPath com a barra escapada (sem escape o Lucene lê /.../ como regex)" '[.panels[].targets[].query | select(contains("RequestPath:"))] | (length > 0) and all(contains("RequestPath:\\/api\\/v1\\/internal*"))'
expect "logins falhos e recusas só da API (excluem eventos do navegador: ClientEvent)" '[.panels[].targets[].query | select(contains("Sign-in failed") or contains("signature rejected"))] | (length == 3) and all(contains("AND NOT _exists_:ClientEvent"))'
expect "links de logins falhos/recusas também excluem o navegador" '[.panels[].links[]?.url | select(contains("Sign-in") or contains("signature"))] | (length == 3) and all(contains("NOT%20_exists_%3AClientEvent"))'
expect "link da API interna com a barra escapada" '[.panels[].links[]?.url | select(contains("RequestPath"))] | (length == 1) and all(contains("RequestPath%3A%5C%2Fapi%5C%2Fv1%5C%2Finternal*"))'

# Rodada 3: títulos dos cartões (largura 6) cabem em 1440 px.
expect "títulos dos cartões (largura 6) com até 17 caracteres (não truncam em 1440 px)" '[.panels[] | select(.type == "stat") | select(.title | length > 17)] | length == 0'

if [[ $fail -eq 0 ]]; then echo "legado-overview: APROVADO"; else echo "legado-overview: REPROVADO"; exit 1; fi
