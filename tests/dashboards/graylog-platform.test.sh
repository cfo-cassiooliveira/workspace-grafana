#!/usr/bin/env bash
# Teste estático do dashboard "Graylog - Plataforma" (T13): uid, ausência de painel logs e de campos pessoais,
# só agregações, painel "serviços sem log" com um alvo por serviço esperado e drill-down ao Graylog sem credenciais.
# Lista de serviços esperados: manter igual à de provisioning/dashboards/graylog/platform.json (documentada no README).
# Uso: ./tests/dashboards/graylog-platform.test.sh
# Usa o jq local ou, na falta dele, a imagem pinada ghcr.io/jqlang/jq via Docker (mesma do lint-dashboards.sh).
FILE="provisioning/dashboards/graylog/platform.json"
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

expect "uid graylog-platform e título em PT-BR" '.uid == "graylog-platform" and .title == "Graylog - Plataforma"'
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

# Serviços esperados (inline no filtro jq): quem não enviar log na janela aparece como "Sem logs".
expect "painel \"serviços sem log\": um alvo por serviço esperado, janela de 15 min e \"Sem logs\" quando vazio" '[.panels[] | select(.title | startswith("Serviços sem log"))] | length == 1 and (.[0] | .timeFrom == "15m" and .fieldConfig.defaults.noValue == "Sem logs" and ([.targets[].query | capture("^service_name:\"(?<s>[^\"]+)\" AND NOT smoke_test:true$").s] | sort) == (["cadastro-api","cadastro-web","legado-api","legado-web","keycloak-server","sonarqube","grafana"] | sort))'
expect "cobre volume por serviço, erros por serviço e taxa de erro por serviço" '(any(.panels[]; .title == "Volume de logs por serviço")) and (any(.panels[]; .title == "Erros por serviço")) and (any(.panels[]; .title | startswith("Taxa de erro por serviço")))'

expect "toda consulta exclui as fixtures do smoke (smoke_test:true mascara quedas reais por até 15 min)" '[.panels[].targets[].query] | (length > 0) and all(endswith("AND NOT smoke_test:true"))'
expect "taxa de erro por serviço: erros nulos viram 0 (reduceRow com nullValueMode zero antes da divisão) e sem NaN" '[.panels[] | select(.title | startswith("Taxa de erro por serviço")) | .transformations] | (length == 1) and (.[0] | (map(select(.id == "calculateField" and .options.mode == "reduceRow" and .options.nullValueMode == "zero" and .options.alias == "Erros")) | length == 1) and (map(select(.id == "calculateField" and .options.mode == "binary" and .options.binary.left.matcher.options == "Erros")) | length == 1))'
expect "tabela de taxa prioriza Taxa e Erros antes de Logs e define minWidth (mobile)" '[.panels[] | select(.title | startswith("Taxa de erro por serviço"))] | (length == 1) and (.[0] | (.transformations[] | select(.id == "organize") | .options.indexByName | (.["Taxa de erro"] < ."Count 1") and (.Erros < ."Count 1")) and (.fieldConfig.defaults.custom.minWidth > 0))'

# Rodada 3: a tabela cabe em 390 px (largura útil ~335 px) sem cortar o cabeçalho.
expect "tabela de taxa de erro: colunas com largura fixa somando <= 335 px e quebra de linha" '.panels[] | select(.type == "table") | (.fieldConfig.defaults.custom.cellOptions.wrapText == true) and ([.fieldConfig.overrides[].properties[] | select(.id == "custom.width") | .value] | (length == 4 and add <= 335)) and ([.fieldConfig.overrides[] | select(.matcher.options == "Taxa de erro") | .properties[] | select(.id == "custom.width") | .value][0] >= 120)'
expect "gráficos por serviço altos o bastante para a legenda no mobile (h >= 12)" '[.panels[] | select(.type == "timeseries") | select(.gridPos.h < 12)] | length == 0'
expect "cartão de serviços sem log esconde o texto da janela (hideTimeOverride) para o título não truncar no mobile" '[.panels[] | select(.title | startswith("Serviços sem log")) | .hideTimeOverride == true] == [true]'

if [[ $fail -eq 0 ]]; then echo "graylog-platform: APROVADO"; else echo "graylog-platform: REPROVADO"; exit 1; fi
