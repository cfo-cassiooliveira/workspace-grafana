#!/usr/bin/env bash
# Teste estático do dashboard "Cadastro - Visão geral" (T10): confere o JSON provisionado contra as regras de
# negócio (só agregações, nenhum dado pessoal, estados tratados, drill-down sem credenciais).
# Complementa o scripts/lint-dashboards.sh (regras gerais). Usa o jq local ou a imagem pinada via Docker.
# Uso: ./tests/dashboards/cadastro-overview.test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
DASHBOARD="provisioning/dashboards/cadastro/overview.json"

# Executa o jq sobre o dashboard (os argumentos são repassados ao jq).
run_jq() {
  if command -v jq >/dev/null 2>&1; then
    jq "$@" "$DASHBOARD"
  else
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/w:ro" -w /w "$JQ_IMAGE" "$@" "$DASHBOARD"
  fi
}

fail=0
# check "<descrição>" '<filtro jq que deve devolver true>'
check() {
  local name="$1" filter="$2" result
  result="$(run_jq -r "$filter")"
  if [[ "$result" == "true" ]]; then echo "OK    $name"; else echo "FALHA $name"; fail=1; fi
}

# Campos que as consultas podem agrupar (terms). Qualquer campo novo exige revisão LGPD e entrar nesta lista.
ALLOWED_FIELDS='["level_name","service_name","http_status","message_template","timestamp"]'

check "uid é cadastro-overview" '.uid == "cadastro-overview"'
check "sem campo id" 'has("id") | not'
check "título em PT-BR" '.title == "Cadastro - Visão geral"'
check "editable false" '.editable == false'
check "nenhum painel do tipo logs" '[.. | objects | select(.type? == "logs")] | length == 0'
check "datasource só graylog-opensearch" \
  '[.. | objects | select(has("datasource")) | .datasource | select(.uid != "graylog-opensearch" and .uid != "-- Grafana --")] | length == 0'
check "todo painel tem título, descrição e noValue em PT-BR" \
  '[.panels[] | select((.title // "") == "" or (.description // "") == "" or ((.fieldConfig.defaults.noValue // "") == ""))] | length == 0'
check "toda métrica é count (sem raw_data/raw_document/logs)" \
  '[.panels[].targets[] | .metrics[] | select(.type != "count")] | length == 0'
check "toda consulta é lucene (sem PPL)" '[.panels[].targets[] | select(.queryType != "lucene")] | length == 0'
check "agrupamentos só por campos da lista permitida" \
  "[.panels[].targets[] | .bucketAggs[] | select(.type != \"date_histogram\") | .field | select(. as \$f | $ALLOWED_FIELDS | index(\$f) | not)] | length == 0"
check "toda consulta com agrupamento limita o tamanho (terms.size <= 10)" \
  '[.panels[].targets[] | .bucketAggs[] | select(.type == "terms") | select((.settings.size | tonumber) > 10)] | length == 0'
check "consultas e agrupamentos sem campo pessoal" \
  '[.panels[].targets[] | .. | strings | select(test("(^|[^a-z0-9_])(cpf|cnpj|e-?mail|masked_login|phone|celular|telefone|user_?name|preferred_username|login|name|full_message|message)([^a-z0-9_]|$)"; "i"))] | length == 0'
check "consultas restritas ao Cadastro (service_name:cadastro-*)" \
  '[.panels[].targets[] | select(.query | test("service_name:cadastro-")| not)] | length == 0'
check "ao menos um link de drill-down ao Graylog" \
  '[.links[]?, (.panels[].links[]?) | select(.url | startswith("http://localhost:9000/search?"))] | length >= 1'
check "links sem credenciais embutidas" '[.. | objects | select(has("url")) | .url | select(test("//[^/]*@|password|token"; "i"))] | length == 0'
check "intervalo padrão 6h e refresh 1m" '.time.from == "now-6h" and .refresh == "1m"'

check "stats (painéis 1-4) agregam por date_histogram (sem bucketAggs o /api/ds/query devolve 400) e somam o período"   '[.panels[] | select(.type == "stat")] | (length == 4) and all(.[]; (.targets | all(.[]; any(.bucketAggs[]?; .type == "date_histogram"))) and (.options.reduceOptions.calcs == ["sum"]))'
check "tabela de erros usa message_template (keyword), nunca MessageTemplate"   '([.. | strings | select(contains("MessageTemplate"))] | length == 0) and ([.panels[] | select(.type == "table") | .targets[] | .query, (.bucketAggs[] | .field)] | all(contains("message_template")))'
check "sem texto de rascunho [CONFIRMAR]" '[.. | strings | select(contains("CONFIRMAR"))] | length == 0'

# Rodada 3: taxa de erros, barras por nível e quebra de linha (regressões vistas na tela real).
check "taxa de erros (painel 6): junta pelo campo de tempo \"Time\" do quadro do OpenSearch e os alias dos alvos batem com os campos do cálculo" \
  '.panels[] | select(.id == 6) | (.transformations[0].options.byField == "Time") and (([.targets[].alias] | sort) == ["Erros","Total"]) and (([.transformations[1].options.binary.left.matcher.options, .transformations[1].options.binary.right.matcher.options] | sort) == ["Erros","Total"])'
# Alinhamento painel 6 x alerta cadastro-error-rate: ambos excluem o ruído dos health checks e do smoke (senão o painel mostra
# uma taxa alta que o alerta ignora de propósito).
check "taxa de erros (painel 6): Total e Erros excluem o ruído dos health checks e do smoke, como o alerta" \
  '.panels[] | select(.id == 6) | [.targets[].query] | (length == 2) and all(.[]; contains("NOT smoke_test:true") and contains("KeycloakHealthCheck") and contains("DefaultHealthCheckService"))'
for term in 'NOT smoke_test:true' 'KeycloakHealthCheck' 'DefaultHealthCheckService'; do
  if grep -qF "$term" provisioning/alerting/rules.yaml; then echo "OK    alerta cadastro-error-rate também exclui $term"; else echo "FALHA alerta cadastro-error-rate não exclui $term"; fail=1; fi
done
check "eventos por nível (painel 7): rowsToFields gera uma barra por nível, com cor por nível (error vermelho, warning amarelo)" \
  '.panels[] | select(.id == 7) | (.transformations[0].id == "rowsToFields") and ([.fieldConfig.overrides[] | select(.matcher.options == "error") | .properties[0].value.fixedColor] == ["red"]) and ([.fieldConfig.overrides[] | select(.matcher.options == "warning") | .properties[0].value.fixedColor] == ["yellow"]) and ((.fieldConfig.overrides | length) >= 4)'
check "tabela de erros quebra linha (modelos longos do Serilog)" '.panels[] | select(.id == 10) | .fieldConfig.defaults.custom.cellOptions.wrapText == true'
check "títulos dos cartões (largura 6) com até 18 caracteres (não truncam em 1440 px)" '[.panels[] | select(.type == "stat") | select(.title | length > 18)] | length == 0'
check "taxa de erros mantém o id 6 (referenciado pelo alerta cadastro-error-rate)" '[.panels[] | select(.id == 6 and .title == "Taxa de erros (%)")] | length == 1'
check "tabela de erros com altura para as linhas quebradas no mobile (h >= 11)" '.panels[] | select(.id == 10) | .gridPos.h >= 11'
check "volume por nível (painel 5) usa as mesmas cores do painel 7 (error vermelho, warning amarelo) e altura para 4 linhas de legenda" '.panels[] | select(.id == 5) | ([.fieldConfig.overrides[] | select(.matcher.options == "error") | .properties[0].value.fixedColor] == ["red"]) and ([.fieldConfig.overrides[] | select(.matcher.options == "warning") | .properties[0].value.fixedColor] == ["yellow"]) and (.gridPos.h >= 10)'

if [[ $fail -eq 0 ]]; then echo "cadastro-overview.test: APROVADO"; else echo "cadastro-overview.test: REPROVADO"; exit 1; fi
