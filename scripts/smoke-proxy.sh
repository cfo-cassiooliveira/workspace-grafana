#!/usr/bin/env bash
# Smoke do opensearch-proxy (T23, ADR-0004): hardening do container e allowlist (rotas, métodos, índices do _msearch).
# Fala com o proxy a partir do container do Grafana (única rede com rota até ele). Exige Graylog + Grafana de pé; não grava nada.
# Uso: ./scripts/smoke-proxy.sh
# Os templates {{...}} do docker inspect são literais, não expansões do shell.
# shellcheck disable=SC2016
set -euo pipefail
exec < /dev/null
cd "$(dirname "$0")/.."
failures=0
check() { if [[ "$2" == true ]]; then echo "OK   $1"; else echo "FALHA $1"; failures=$((failures + 1)); fi; }
eq_if() { if [[ "$1" == "$2" ]]; then echo true; else echo false; fi; }

proxy="$(docker compose ps -q opensearch-proxy)"
grafana="$(docker compose ps -q grafana)"
[[ -n "$proxy" && -n "$grafana" ]] || { echo "FALHA opensearch-proxy/grafana não estão de pé"; exit 1; }
insp() { docker inspect -f "$1" "$proxy"; }

# Hardening do container.
check "proxy healthy" "$(eq_if "$(insp '{{.State.Health.Status}}')" healthy)"
check "usuário não-root (101)" "$(eq_if "$(insp '{{.Config.User}}')" 101:101)"
check "rootfs read-only" "$(eq_if "$(insp '{{.HostConfig.ReadonlyRootfs}}')" true)"
check "cap_drop ALL" "$(eq_if "$(insp '{{.HostConfig.CapDrop}}')" '[ALL]')"
check "no-new-privileges" "$([[ "$(insp '{{.HostConfig.SecurityOpt}}')" == *no-new-privileges* ]] && echo true || echo false)"
ports="$(insp '{{range $p,$b := .NetworkSettings.Ports}}{{if $b}}x{{end}}{{end}}')"
check "sem porta publicada no host" "$(eq_if "$ports" "")"
check "imagem por tag + digest" "$([[ "$(insp '{{.Config.Image}}')" =~ ^nginx:[0-9][^@]*@sha256:[0-9a-f]{64}$ ]] && echo true || echo false)"
nets="$(insp '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
check "proxy só nas redes logs-ro e logs-read" "$([[ "$nets" == *logs-ro* && "$nets" == *logs-read* && "$(wc -w <<< "$nets")" -eq 2 ]] && echo true || echo false)"
gnets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$grafana")"
check "Grafana NÃO está na logs-read (sem rota direta ao OpenSearch)" "$([[ "$gnets" != *logs-read* ]] && echo true || echo false)"

U=http://opensearch-ro:8080
# status METHOD PATH [content-type] [corpo]: código HTTP devolvido pelo proxy, visto do Grafana.
status() {
  local method="$1" path="$2" body="${3:-}"
  printf '%s' "$body" | docker exec -i "$grafana" curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" \
    -H 'Content-Type: application/x-ndjson' --data-binary @- "${U}${path}" || true
}
msearch() { status POST "${2:-/_msearch}" "$1"; }
expect() { check "$1 => $3" "$(eq_if "$2" "$3")"; }

expect "GET / (versão)" "$(status GET /)" 200
expect "GET /<pattern>/_mapping" "$(status GET '/cadastro_*/_mapping')" 200
expect "GET /<pattern>/_field_caps" "$(status GET '/cadastro_*,legado_*/_field_caps?fields=*')" 200
expect "POST /_msearch com índices do pattern" "$(msearch $'{"index":"cadastro_*,legado_*"}\n{"size":0}\n')" 200
expect "POST /<pattern>/_msearch (índice só na URL)" "$(msearch $'{}\n{"size":0}\n' '/cadastro_*/_msearch')" 200
for m in PUT DELETE PATCH; do expect "${m} /cadastro_x bloqueado" "$(status "$m" /cadastro_x '{}')" 403; done
expect "POST /_bulk bloqueado" "$(status POST /_bulk '{}')" 403
expect "GET /_cat/indices bloqueado" "$(status GET /_cat/indices)" 403
expect "GET /_cluster/health bloqueado" "$(status GET /_cluster/health)" 403
expect "GET /cadastro_*/_search bloqueado (só _msearch)" "$(status GET '/cadastro_*/_search')" 403
expect "GET /gl-events_0/_mapping bloqueado (fora do pattern)" "$(status GET /gl-events_0/_mapping)" 403
expect "GET /_mapping sem índice bloqueado" "$(status GET /_mapping)" 403
expect "DELETE /_msearch bloqueado" "$(status DELETE /_msearch)" 403
expect "_msearch com cabeçalho index fora do pattern" "$(msearch $'{"index":"gl-events_0"}\n{"size":0}\n')" 403
expect "_msearch com indices fora do pattern" "$(msearch $'{"indices":"top_queries-*"}\n{"size":0}\n' '/cadastro_*/_msearch')" 403
expect "_msearch sem índice em lugar nenhum (varreria tudo)" "$(msearch $'{}\n{"size":0}\n')" 403
expect "_msearch com lista mista (um índice fora)" "$(msearch $'{"index":["cadastro_*","gl-events_0"]}\n{"size":0}\n')" 403
expect "_msearch com exclusão/curinga fora do prefixo" "$(msearch $'{"index":"*"}\n{"size":0}\n')" 403
expect "_msearch com cluster remoto (cluster:índice)" "$(msearch $'{"index":"x:cadastro_*"}\n{"size":0}\n')" 403
expect "_msearch com chave desconhecida no cabeçalho" "$(msearch $'{"index":"cadastro_*","alias":"x"}\n{"size":0}\n')" 403
expect "_msearch com terms lookup em outro índice" "$(msearch $'{"index":"cadastro_*"}\n{"query":{"terms":{"level":{"index":"gl-events_0","id":"1","path":"priority"}}}}\n')" 403
expect "_msearch com wrapper (query em base64)" "$(msearch $'{"index":"cadastro_*"}\n{"query":{"wrapper":{"query":"e30="}}}\n')" 403
expect "_msearch NDJSON malformado" "$(msearch $'{"index":"cadastro_*"}\n')" 403
# Bypass do pareamento NDJSON (revisão 1): o OpenSearch pareia linhas em branco de outro jeito que o validador.
expect "_msearch com linha em branco no meio (pareamento divergente)" "$(msearch $'{"index":"cadastro_*"}\n{}\n\n{}\n{"indices":"*"}\n{}\n{}\n' '/cadastro_*/_msearch')" 403
expect "_msearch com linha em branco entre pares" "$(msearch $'{"index":"cadastro_*"}\n{"size":0}\n\n{"index":"cadastro_*"}\n{"size":0}\n')" 403
expect "_msearch com indices no corpo" "$(msearch $'{"index":"cadastro_*"}\n{"indices":"*"}\n')" 403
expect "_msearch com index como curinga puro em array" "$(msearch $'{"index":["*"]}\n{"size":0}\n')" 403
expect "_msearch com index como array de índices do pattern (válido)" "$(msearch $'{"index":["cadastro_*","legado_*"]}\n{"size":0}\n')" 200
expect "_msearch com última linha vazia e sem quebra final (válido)" "$(msearch $'{"index":"cadastro_*"}\n{"size":0}')" 200
expect "_msearch com source na URL" "$(msearch $'{"index":"cadastro_*"}\n{"size":0}\n' '/_msearch?source=x')" 403
expect "_msearch com source_content_type na URL" "$(msearch $'{"index":"cadastro_*"}\n{"size":0}\n' '/_msearch?source_content_type=application/json')" 403
expect "_msearch com argumento permitido (search_type)" "$(msearch $'{"index":"cadastro_*"}\n{"size":0}\n' '/_msearch?search_type=query_then_fetch')" 200
expect "_mapping com source na URL" "$(status GET '/cadastro_*/_mapping?source=x')" 403
expect "_field_caps com source na URL" "$(status GET '/cadastro_*/_field_caps?fields=*&source=x')" 403
expect "_field_caps POST com terms lookup em index_filter" "$(status POST '/cadastro_*/_field_caps?fields=*' '{"index_filter":{"terms":{"level":{"index":"gl-events_0","id":"1","path":"p"}}}}')" 403
expect "_field_caps POST com index_filter simples (válido)" "$(status POST '/cadastro_*/_field_caps?fields=*' '{"index_filter":{"range":{"timestamp":{"gte":"now-1d"}}}}')" 200
expect "_msearch com barra final (/_msearch/)" "$(msearch $'{"index":"cadastro_*"}\n{"size":0}\n' '/_msearch/')" 403
expect "caminho com // (//_cat/indices; o nginx normaliza e a allowlist nega)" "$(status GET //_cat/indices)" 403
expect "caminho com %2e (/%2e%2e/_cat/indices)" "$(status GET '/%2e%2e/_cat/indices')" 403
expect "caminho com %2f (/cadastro_*%2f..%2f_cat/indices; decodificado e negado)" "$(status GET '/cadastro_*%2f..%2f_cat/indices')" 403
expect "OPTIONS /_msearch bloqueado" "$(status OPTIONS /_msearch)" 403
head_status() { docker exec "$grafana" curl -s -o /dev/null -I -w '%{http_code}' --max-time 10 --path-as-is "${U}${1}" || true; }
expect "HEAD /_msearch bloqueado" "$(head_status /_msearch)" 403
expect "HEAD /cadastro_*/_mapping bloqueado" "$(head_status '/cadastro_*/_mapping')" 403
expect "corpo acima de 1 MB (413)" "$(msearch "$(head -c 1100000 /dev/zero | tr '\0' a)")" 413
[[ $failures -eq 0 ]] || { echo "smoke-proxy: ${failures} falha(s)"; exit 1; }
echo "smoke-proxy: APROVADO"
