#!/usr/bin/env bash
# Varredura de usuários descartáveis "e2e.grafana.*" (só os deste projeto; o keycloak tem os seus e2e.*) que podem sobrar no Keycloak (e no Grafana) após kill -9/queda do Docker,
# quando o trap do e2e.sh não chegou a rodar. Sem argumento só LISTA (nomes, nunca segredos); com --delete remove.
# Uso (na raiz do projeto, Keycloak e Grafana de pé): ./scripts/sweep-e2e-users.sh [--delete]
set -euo pipefail

cd "$(dirname "$0")/.."
BASE_URL="${GRAFANA_URL:-http://localhost:3000}"
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-http://localhost:8180}"
KEYCLOAK_REALM="workspace"
PREFIX="e2e.grafana."
delete=false
case "${1:-}" in
  "") ;;
  --delete) delete=true ;;
  *) echo "uso: $0 [--delete]" >&2; exit 2 ;;
esac

set -a
# shellcheck disable=SC1091
source .env
set +a

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
probe_ids=()
sso_probe_logins=()
automation_secret=""
# shellcheck source=lib/keycloak-admin.sh
source scripts/lib/keycloak-admin.sh

kc_load_automation_secret
[[ -n "$automation_secret" && -n "$(kc_token)" ]] || { echo "Admin API do Keycloak inacessível (Keycloak de pé e ../keycloak/.env)." >&2; exit 2; }

# A busca do Keycloak é por substring; o filtro abaixo exige o prefixo exato no início do username.
mapfile -t found < <(kc_admin GET "/users?search=${PREFIX}&max=200" | grep -o '"id":"[^"]*","username":"[^"]*"' \
  | sed 's/"id":"\([^"]*\)","username":"\([^"]*\)"/\1 \2/' | awk -v p="$PREFIX" 'index($2, p) == 1')

if [[ ${#found[@]} -eq 0 ]]; then echo "Nenhum usuário ${PREFIX}* no Keycloak."; exit 0; fi
for entry in "${found[@]}"; do
  uid="${entry%% *}"
  name="${entry#* }"
  if [[ "$delete" == true ]]; then
    kc_admin DELETE "/users/${uid}" >/dev/null && echo "removido: ${name}"
    sso_probe_logins+=("$name")
  else
    echo "encontrado: ${name}"
  fi
done
if [[ "$delete" == true ]]; then remove_sso_users_from_grafana; else echo "Nada removido; rode com --delete para apagar."; fi
