#!/usr/bin/env bash
# Importa os dashboards OFICIAIS do RabbitMQ do grafana.com numa revisão FIXADA (ADR-0005) e os grava em
# provisioning/dashboards/rabbitmq/, ajustados ao padrão do projeto: datasource fixo uid "prometheus" (sem a variável
# DS_PROMETHEUS nem __inputs/__requires), uid kebab-case, título "<Sistema> - <Assunto>" em PT-BR, sem "id", editable:false.
# O SHA-256 do JSON baixado é conferido: revisão adulterada ou trocada no grafana.com falha antes de gravar.
# Uso (na raiz do projeto, com acesso à internet): ./scripts/import-rabbitmq-dashboards.sh
# Para subir de revisão: troque revisão e SHA-256 na tabela, rode o script, ./scripts/lint-dashboards.sh e os smokes.
# Erlang-Distribution (11352 rev 10) fica de fora de propósito: no broker single-node não há série erlang_vm_dist_* (ADR-0005).
set -euo pipefail

cd "$(dirname "$0")/.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
OUT_DIR="provisioning/dashboards/rabbitmq"
# id|revisão|sha256 do download|uid|título|arquivo
DASHBOARDS=(
  "10991|15|f98a21fe50c85c1da41d1a9a429d04aa5b137c9025753945f1b53e8f6fc1e6a2|rabbitmq-overview|RabbitMQ - Visão geral|overview.json"
  "11350|8|ff1069bff741af131fee76dbc1e111ffe9127c8691008fffd2a3696c0f779570|rabbitmq-memory-allocators|RabbitMQ - Alocadores de memória Erlang|memory-allocators.json"
)

# Transformação (jq): remove metadados de importação e a variável de datasource; troca "${DS_PROMETHEUS}" pelo uid provisionado.
# shellcheck disable=SC2016  # "$" literal do jq, não expansão do shell.
TRANSFORM='del(.__inputs, .__requires, .__elements, .id)
  | .uid = $uid | .title = $title | .editable = false
  | .description = "Dashboard oficial do RabbitMQ (grafana.com \($id), revisão \($rev)), importado por scripts/import-rabbitmq-dashboards.sh; só o datasource, uid e título foram ajustados."
  | .templating.list |= map(select(.type != "datasource"))
  | walk(if type == "string" and . == "${DS_PROMETHEUS}" then "prometheus" else . end)'

jq_run() {
  if command -v jq >/dev/null 2>&1; then jq "$@"; else docker run -i --rm "$JQ_IMAGE" "$@"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT_DIR"
for entry in "${DASHBOARDS[@]}"; do
  IFS='|' read -r id rev sha uid title file <<< "$entry"
  curl -sfL --max-time 60 -o "${work}/${id}.json" "https://grafana.com/api/dashboards/${id}/revisions/${rev}/download"
  got="$(sha256sum "${work}/${id}.json" | cut -c1-64)"
  [[ "$got" == "$sha" ]] || { echo "FALHA ${id} rev ${rev}: SHA-256 ${got} difere do fixado ${sha}" >&2; exit 1; }
  jq_run --arg uid "$uid" --arg title "$title" --arg id "$id" --arg rev "$rev" "$TRANSFORM" < "${work}/${id}.json" > "${OUT_DIR}/${file}"
  if grep -q 'DS_PROMETHEUS' "${OUT_DIR}/${file}"; then echo "FALHA ${file}: sobrou referência a DS_PROMETHEUS" >&2; exit 1; fi
  echo "OK   ${id} rev ${rev} -> ${OUT_DIR}/${file} (uid ${uid})"
done
