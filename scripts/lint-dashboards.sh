#!/usr/bin/env bash
# Lint dos dashboards JSON (provisioning/dashboards): uid único em kebab-case, sem "id", schemaVersion,
# datasource só por uid provisionado, título "<Sistema> - <Assunto>" em PT-BR, editable:false, sem painel "logs"
# e sem campos pessoais (LGPD) nas consultas: as pastas são lidas por Viewer, que só pode ver agregações.
# Uso: ./scripts/lint-dashboards.sh [diretório]   (padrão: provisioning/dashboards)
#      ./scripts/lint-dashboards.sh --self-test   (o bom passa; cada bad-<regra>[__variante].json de tests/fixtures falha por [regra])
# Usa o jq local ou, na falta dele, a imagem pinada ghcr.io/jqlang/jq via Docker (um único container por execução).
set -euo pipefail

cd "$(dirname "$0")/.."
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
# Datasources provisionados (uid), separados por vírgula: por padrão, os "uid:" dos YAML em provisioning/datasources
# (hoje graylog-opensearch e prometheus). Ex.: ALLOWED_DATASOURCE_UIDS="graylog-opensearch,outro".
provisioned_uids() { sed -n 's/^ *uid: *\([a-z0-9-]*\) *$/\1/p' provisioning/datasources/*.yaml | paste -sd, -; }
ALLOWED_DATASOURCE_UIDS="${ALLOWED_DATASOURCE_UIDS:-$(provisioned_uids)}"
[[ -n "$ALLOWED_DATASOURCE_UIDS" ]] || { echo "lint-dashboards: nenhum datasource em provisioning/datasources" >&2; exit 2; }
ALLOWED_JSON="[\"${ALLOWED_DATASOURCE_UIDS//,/\",\"}\"]"

# Roda as regras sobre os arquivos (caminhos relativos à raiz); devolve linhas "<arquivo>\t<violação>".
run_rules() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --argjson allowed "$ALLOWED_JSON" -f scripts/dashboard-lint.jq "$@"
  else
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/w:ro" -w /w "$JQ_IMAGE" \
      -r --argjson allowed "$ALLOWED_JSON" -f scripts/dashboard-lint.jq "$@"
  fi
}

# Lint de uma pasta. Imprime as violações; devolve 1 se houver alguma (inclusive uid duplicado ou JSON inválido).
lint_dir() {
  local dir="$1" fail=0 file msg
  local -a files
  mapfile -t files < <(find "$dir" -name '*.json' -type f | sort)
  declare -A seen=()
  if [[ ${#files[@]} -gt 0 ]]; then
    local out
    if ! out="$(run_rules "${files[@]}" 2>&1)"; then echo "  [json-invalid] $out"; return 1; fi
    while IFS=$'\t' read -r file msg; do
      [[ -z "$file" ]] && continue
      if [[ "$msg" == uid=* ]]; then
        if [[ -n "${seen[${msg#uid=}]:-}" ]]; then echo "  $file [uid-duplicate] uid \"${msg#uid=}\" já usado em ${seen[${msg#uid=}]}"; fail=1; fi
        seen[${msg#uid=}]="$file"
      else
        echo "  $file $msg"; fail=1
      fi
    done <<< "$out"
  fi
  echo "  (${#files[@]} dashboard(s) em $dir)"
  return $fail
}

self_test() {
  local fail=0 file rule out
  echo "== bom: deve passar"
  if lint_dir tests/fixtures/dashboards/good; then echo "OK   dashboard bom aprovado"; else echo "FALHA dashboard bom reprovado"; fail=1; fi
  echo "== ruins: cada um deve falhar pela regra do nome (bad-<regra>.json)"
  out="$(lint_dir tests/fixtures/dashboards/bad 2>&1 || true)"
  for file in tests/fixtures/dashboards/bad/*.json; do
    rule="$(basename "$file" .json)"; rule="${rule#bad-}"; rule="${rule%%__*}"   # bad-<regra>__<variante>.json também vale
    if grep -F "$file" <<< "$out" | grep -qF "[$rule]"; then echo "OK   $file reprovado por [$rule]"
    else echo "FALHA $file não foi reprovado por [$rule]"; fail=1; fi
  done
  # Unicidade de uid: dois arquivos com o mesmo uid na mesma pasta.
  out="$(lint_dir tests/fixtures/dashboards/duplicate 2>&1 || true)"
  if grep -qF "[uid-duplicate]" <<< "$out"; then echo "OK   uid duplicado reprovado por [uid-duplicate]"
  else echo "FALHA uid duplicado não detectado"; fail=1; fi
  if [[ $fail -eq 0 ]]; then echo "lint-dashboards self-test: APROVADO"; else echo "lint-dashboards self-test: REPROVADO"; return 1; fi
}

if [[ "${1:-}" == "--self-test" ]]; then self_test; exit $?; fi
if lint_dir "${1:-provisioning/dashboards}"; then echo "lint-dashboards: APROVADO"; else echo "lint-dashboards: REPROVADO"; exit 1; fi
