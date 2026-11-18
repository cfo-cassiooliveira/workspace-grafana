#!/usr/bin/env bash
# E2E do SSO e do hardening do Grafana (Playwright + axe-core no container oficial; só o Docker é necessário) [T15].
# Uso (na raiz do projeto): ./scripts/e2e.sh [argumentos do "playwright test"]
# Pré-requisitos: Keycloak (../keycloak, com ../keycloak/.env) e Grafana de pé, SEM o Graylog (não rodam juntos), e as redes
# externas do compose do Grafana. Sem o OpenSearch, os painéis mostram o estado de erro/vazio (o E2E confere que a página não quebra).
# Usuários descartáveis e:*, criados pela Admin API do Keycloak (funções de scripts/lib/keycloak-admin.sh, as mesmas do smoke)
# e removidos no trap, inclusive em falha, junto com os usuários que o login SSO criou no Grafana. Senhas aleatórias seguem
# por variável de ambiente (-e NOME, sem valor no argv) e nunca são impressas. Capturas de tela vão para tests/e2e/.artifacts/.
set -euo pipefail

PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v1.64.1-noble@sha256:2f05f8a734509a7b3f26a912639488ee08f58a7b292d14d62271bcff9038768f"
cd "$(dirname "$0")/.."
# No Git Bash (Windows) o Docker precisa do caminho no formato C:/...; "pwd -W" só existe lá.
host_dir="$(pwd -W 2>/dev/null || pwd)"
BASE_URL="${GRAFANA_URL:-http://localhost:3000}"
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-http://localhost:8180}"
KEYCLOAK_REALM="workspace"

set -a
# shellcheck disable=SC1091
source .env
set +a

work_dir="$(mktemp -d)"
probe_ids=()
sso_probe_logins=()
automation_secret=""
# shellcheck source=lib/keycloak-admin.sh
source scripts/lib/keycloak-admin.sh

# shellcheck disable=SC2329 # chamada pelo trap EXIT
cleanup() {
  local uid
  for uid in "${probe_ids[@]}"; do kc_admin DELETE "/users/${uid}" >/dev/null 2>&1 || true; done
  remove_sso_users_from_grafana
  rm -rf "$work_dir"
}
trap cleanup EXIT

curl -fs -o /dev/null --max-time 10 "${BASE_URL}/api/health" || { echo "Grafana fora do ar em ${BASE_URL} (docker compose up -d)." >&2; exit 2; }
kc_load_automation_secret
[[ -n "$automation_secret" && -n "$(kc_token)" ]] || { echo "Admin API do Keycloak inacessível (Keycloak de pé e ../keycloak/.env)." >&2; exit 2; }

# O Keycloak limita o username a 30 caracteres.
suffix="$(( $(date +%s) % 100000 ))"
declare -A roles=([VIEWER]=grafana-viewer [EDITOR]=grafana-editor [NOROLE]="" [ENDUSER]=user [ADMIN]=admin)
for key in VIEWER EDITOR NOROLE ENDUSER ADMIN; do
  name="e2e.grafana.$(tr '[:upper:]' '[:lower:]' <<< "$key").${suffix}"
  make_probe_user "$name" "${roles[$key]}"
  [[ -n "$probe_uid" ]] || { echo "Falha ao criar o usuário descartável ${key}." >&2; exit 2; }
  export "E2E_${key}_USER=${name}"
  export "E2E_${key}_PASSWORD=$(cat "${work_dir}/${name}.pw")"
done

# Linux: a rede do host dá acesso direto às portas. Docker Desktop: o global-setup encaminha localhost:3000/8180 ao host.
if [[ "$(uname -s)" == "Linux" ]]; then
  network_args=(--network host)
else
  network_args=(-e E2E_FORWARD_HOST=host.docker.internal)
fi

rm -rf tests/e2e/.artifacts
mkdir -p tests/e2e/.artifacts
status=0
MSYS_NO_PATHCONV=1 docker run --rm --ipc=host \
  "${network_args[@]}" \
  -e E2E_VIEWER_USER -e E2E_VIEWER_PASSWORD -e E2E_EDITOR_USER -e E2E_EDITOR_PASSWORD \
  -e E2E_NOROLE_USER -e E2E_NOROLE_PASSWORD -e E2E_ENDUSER_USER -e E2E_ENDUSER_PASSWORD \
  -e E2E_ADMIN_USER -e E2E_ADMIN_PASSWORD \
  -v "${host_dir}/tests/e2e:/e2e" \
  -v grafana-e2e-node-modules:/e2e/node_modules \
  -v "${host_dir}/docker-compose.yml:/repo/docker-compose.yml:ro" \
  -w /e2e \
  "$PLAYWRIGHT_IMAGE" \
  bash -c 'npm ci --no-audit --no-fund --loglevel=error && npx playwright test "$@"' -- "$@" || status=$?
exit "$status"
