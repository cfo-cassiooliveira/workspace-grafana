#!/usr/bin/env bash
# Smoke test ponta a ponta do Grafana. Parte 1 (T02): imagem, saúde e hardening. Parte 2 (T06): SSO Keycloak (config, PKCE, fluxo real).
# Parte 3 (T07): datasource Graylog/OpenSearch (saúde via proxy, agregação com a fixture GELF, bloqueio de escrita/índices fora do pattern ao Viewer).
# Parte 4a (T14, alertas como código; exige o Graylog: GELF HTTP) e 4b (T17, health das APIs; exige o stack grafana-metrics de pé):
# --skip-alerts / --skip-metrics. 4a leva alguns minutos (a regra de taxa de erros usa janela de 5 min para voltar ao normal).
# A parte 2 exige o Keycloak de pé e ../keycloak/.env (só leitura); a parte 3 exige o Graylog de pé (GELF HTTP em 127.0.0.1:12202).
# Keycloak e Graylog não rodam juntos: use --skip-sso com o Graylog e --skip-datasource com o Keycloak (sem flag, todas as
# partes rodam e a que estiver sem o serviço falha, de propósito).
# Segredos (client_secret do SSO, token, senhas) nunca vão no argv: só por arquivo 0600 em tmp (grep -f, curl -K) ou stdin.
# Parte 3: os riscos do Viewer (ADR-0001) são ASSERTIVAS de bloqueio pelo opensearch-proxy (ADR-0004); acesso concedido ou resultado
# inconclusivo (5xx, rede) é FALHA. Riscos conhecidos que sobram (ex.: parte 4b) NÃO reprovam, mas são contados e listados no resumo.
# Uso (na raiz do projeto, com o stack de pé): ./scripts/smoke-test.sh [--skip-sso] [--skip-datasource] [--skip-alerts] [--skip-metrics]
# Não recria o container: testa a stack como foi subida (com ou sem docker-compose.graylog.yml).
set -euo pipefail

cd "$(dirname "$0")/.."
BASE_URL="${GRAFANA_URL:-http://localhost:3000}"
GELF_HTTP_URL="${GELF_HTTP_URL:-http://127.0.0.1:12202/gelf}"
failures=0
RUN_SSO=true
RUN_DATASOURCE=true
RUN_ALERTS=true
RUN_METRICS=true
for arg in "$@"; do
  case "$arg" in
    --skip-sso) RUN_SSO=false ;;
    --skip-datasource) RUN_DATASOURCE=false ;;
    --skip-alerts) RUN_ALERTS=false ;;
    --skip-metrics) RUN_METRICS=false ;;
    *) echo "uso: $0 [--skip-sso] [--skip-datasource] [--skip-alerts] [--skip-metrics]"; exit 2 ;;
  esac
done

# Estado temporário compartilhado pelas partes 2 e 3 (sessões, senhas descartáveis) e usuários criados nos dois sistemas.
work_dir="$(mktemp -d)"
probe_ids=()          # usuários descartáveis do Keycloak (parte 2)
grafana_probe_ids=()  # usuários descartáveis locais do Grafana (parte 3)
sso_probe_logins=()   # logins dos usuários do Keycloak que o login SSO cria no Grafana (removidos no cleanup)
open_gaps=()          # riscos conhecidos (ADR-0001) ainda abertos, contados no resumo final
cleanup() {
  local uid
  if declare -F kc_admin >/dev/null; then
    for uid in "${probe_ids[@]}"; do kc_admin DELETE "/users/${uid}" >/dev/null 2>&1 || true; done
  fi
  for uid in "${grafana_probe_ids[@]}"; do
    curl -s -o /dev/null --max-time 10 -X DELETE -b "${work_dir}/grafana-admin.jar" -H "Origin: ${BASE_URL}" "${BASE_URL}/api/admin/users/${uid}" || true
  done
  remove_sso_users_from_grafana
  cleanup_metrics_smoke
  rm -rf "$work_dir"
}
# Descartáveis da parte 4b (Prometheus e alvo falsos, datasource, pasta e regras temporárias); definida cedo para o trap.
SMOKE_API="smoke-grafana-api"
SMOKE_PROM="smoke-grafana-prom"
SMOKE_DS_UID="smoke-prometheus"
SMOKE_FOLDER_UID="smoke-alerts-tmp"
cleanup_metrics_smoke() {
  local jar="${work_dir}/alerts-admin.jar"
  docker rm -f "$SMOKE_API" "$SMOKE_PROM" >/dev/null 2>&1 || true
  [[ -f "$jar" ]] || return 0
  curl -s -o /dev/null --max-time 10 -X DELETE -b "$jar" -H "Origin: ${BASE_URL}" "${BASE_URL}/api/folders/${SMOKE_FOLDER_UID}?forceDeleteRules=true" || true
  curl -s -o /dev/null --max-time 10 -X DELETE -b "$jar" -H "Origin: ${BASE_URL}" "${BASE_URL}/api/datasources/uid/${SMOKE_DS_UID}" || true
}
# Funções compartilhadas com o e2e.sh (Admin API do Keycloak, usuários descartáveis, limpeza dos usuários SSO no Grafana).
# shellcheck source=lib/keycloak-admin.sh
source scripts/lib/keycloak-admin.sh
trap cleanup EXIT

check() {
  local description="$1" ok="$2"
  if [[ "$ok" == "true" ]]; then echo "OK   ${description}"; else echo "FALHA ${description}"; failures=$((failures + 1)); fi
}
# ok_if comando...: converte o status do comando para "true"/"false".
ok_if() { if "$@" >/dev/null 2>&1; then echo true; else echo false; fi; }
# eq_if a b: "true" se forem iguais.
eq_if() { if [[ "$1" == "$2" ]]; then echo true; else echo false; fi; }
# Status HTTP (000 se não conectar).
http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }

set -a
# shellcheck disable=SC1091
source .env
set +a

container="$(docker compose ps -q grafana)"
[[ -n "$container" ]] || { echo "FALHA container grafana não encontrado (rode docker compose up -d --build)"; exit 1; }

# 1. Saúde: espera o healthcheck do compose (até ~2 min).
health="starting"
for _ in $(seq 1 40); do
  health="$(docker inspect -f '{{.State.Health.Status}}' "$container")"
  [[ "$health" == "healthy" ]] && break
  sleep 3
done
check "container healthy (healthcheck /api/health)" "$(eq_if "$health" healthy)"

body="$(curl -s --max-time 10 "${BASE_URL}/api/health" || true)"
check "/api/health: database ok" "$(ok_if grep -q '"database": "ok"' <<< "$body")"

# 2. Versão em execução == tag fixada no Dockerfile (tag + digest).
pinned="$(sed -n 's#^FROM grafana/grafana:\([0-9][0-9.]*\)@sha256:[0-9a-f]\{64\}$#\1#p' Dockerfile)"
check "Dockerfile fixa tag e digest (FROM grafana/grafana:<versão>@sha256:...)" "$([[ -n "$pinned" ]] && echo true || echo false)"
check "versão em execução == tag fixada (${pinned:-?})" "$(ok_if grep -q "\"version\": \"${pinned:-x}\"" <<< "$body")"

# 3. Plugin do OpenSearch instalado na versão pinada por ARG do Dockerfile.
plugin_version="$(sed -n 's/^ARG OPENSEARCH_PLUGIN_VERSION=//p' Dockerfile)"
plugin_json="$(MSYS_NO_PATHCONV=1 docker exec "$container" cat /opt/grafana-plugins/grafana-opensearch-datasource/plugin.json 2>/dev/null || true)"
check "plugin grafana-opensearch-datasource ${plugin_version:-?} instalado" \
  "$(ok_if grep -q "\"version\": \"${plugin_version:-x}\"" <<< "$plugin_json")"

# 4. Acesso: anônimo negado, credencial padrão recusada, sign-up desligado, break-glass funciona.
check "anônimo em /api/dashboards/home = 401" "$(eq_if "$(http_status "${BASE_URL}/api/dashboards/home")" 401)"
check "anônimo em /api/org = 401" "$(eq_if "$(http_status "${BASE_URL}/api/org")" 401)"
login_status() {
  # Corpo pela entrada padrão: a senha do break-glass não aparece no argv (ps/proc).
  printf '{"user":"%s","password":"%s"}' "$1" "$2" \
    | http_status -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login"
}
check "login admin/admin falha (401)" "$(eq_if "$(login_status admin admin)" 401)"
# Senha descartável gerada na hora: o cadastro deve ser recusado, e nenhuma credencial fixa fica no repositório.
signup_pw="Pw-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
signup_status="$(printf '{"email":"smoke@invalid.test","name":"smoke","password":"%s"}' "$signup_pw" \
  | http_status -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/api/user/signup")"
check "sign-up desligado (/api/user/signup = 401)" "$(eq_if "$signup_status" 401)"
check "login do break-glass (.env) funciona" "$(eq_if "$(login_status "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD")" 200)"

# 5. Cabeçalhos de segurança na página de login.
headers="$(curl -sI --max-time 10 "${BASE_URL}/login" || true)"
check "cabeçalho Content-Security-Policy presente" "$(ok_if grep -qi '^content-security-policy:' <<< "$headers")"
check "CSP restritiva: sem 'unsafe-eval', sem curinga em img-src e com frame-ancestors 'none'" \
  "$(csp="$(grep -i '^content-security-policy:' <<< "$headers" || true)"; [[ -n "$csp" && "$csp" != *unsafe-eval* && "$csp" != *'img-src *'* && "$csp" == *"frame-ancestors 'none'"* ]] && echo true || echo false)"
check "página de login carrega (formulário presente no HTML)" "$(ok_if grep -q '<title>Grafana' <<< "$(curl -s --max-time 10 "${BASE_URL}/login")")"
check "plugins somente leitura para o usuário do Grafana (root:root, sem escrita de grupo/outros)" \
  "$([[ "$(MSYS_NO_PATHCONV=1 docker exec "$container" stat -c '%U:%G %a' /opt/grafana-plugins)" == "root:root 755" ]] && echo true || echo false)"
check "X-Content-Type-Options: nosniff" "$(ok_if grep -qi '^x-content-type-options: nosniff' <<< "$headers")"
check "X-Frame-Options: deny (allow_embedding off)" "$(ok_if grep -qi '^x-frame-options: deny' <<< "$headers")"

# 6. Rede e processo: porta só em 127.0.0.1, usuário não-root, sem telemetria, logs JSON.
check "porta 3000 publicada só em 127.0.0.1" "$(eq_if "$(docker compose port grafana 3000)" "127.0.0.1:3000")"
check "processo não roda como root" "$([[ "$(docker exec "$container" id -u)" != "0" ]] && echo true || echo false)"
env_dump="$(docker exec "$container" env)"
for kv in GF_ANALYTICS_REPORTING_ENABLED=false GF_ANALYTICS_CHECK_FOR_UPDATES=false GF_AUTH_ANONYMOUS_ENABLED=false \
  GF_USERS_ALLOW_SIGN_UP=false GF_PLUGINS_PREINSTALL_DISABLED=true GF_LOG_CONSOLE_FORMAT=json; do
  check "configuração ${kv}" "$(ok_if grep -qx "$kv" <<< "$env_dump")"
done
logs="$(docker logs "$container" 2>&1)"
first_log="$(head -1 <<< "$logs")"
check "logs do Grafana em JSON no stdout" "$([[ "$first_log" == \{* ]] && echo true || echo false)"
check "sem download de plugins pré-instalados no start" "$([[ "$logs" != *backgroundinstaller* ]] && echo true || echo false)"

# 7. Provisioning de dashboards (T05): provider carregado sem erro e lint dos JSON versionados.
prov_errors="$(grep -E '"level":"(error|eror)"' <<< "$logs" | grep -c 'provisioning' || true)"
check "provisioning de dashboards sem erros nos logs" "$(eq_if "$prov_errors" 0)"
check "lint-dashboards.sh aprovado" "$(ok_if ./scripts/lint-dashboards.sh </dev/null)"

if [[ "$RUN_SSO" == true ]]; then
# 8. SSO Keycloak (T06): configuração, discovery pelo back-channel e redirecionamento com PKCE S256.
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-http://localhost:8180}"
KEYCLOAK_REALM="workspace"
for kv in GF_AUTH_GENERIC_OAUTH_ENABLED=true GF_AUTH_GENERIC_OAUTH_USE_PKCE=true GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT=true \
  GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=false GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC=false \
  GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=false GF_USERS_AUTO_ASSIGN_ORG_ROLE=None \
  GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION=8h GF_AUTH_LOGIN_MAXIMUM_LIFETIME_DURATION=12h; do
  check "configuração ${kv}" "$(ok_if grep -qx "$kv" <<< "$env_dump")"
done
role_path="$(grep '^GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=' <<< "$env_dump" | cut -d= -f2- || true)"
check "role_attribute_path mapeia grafana-viewer/grafana-editor/admin, sem papel padrão e sem GrafanaAdmin" \
  "$([[ "$role_path" == *"'grafana-viewer') && 'Viewer'"* && "$role_path" == *"'grafana-editor') && 'Editor'"* \
    && "$role_path" == *"'admin') && 'Admin'"* && "$role_path" != *"|| 'Viewer'"* && "$role_path" != *GrafanaAdmin* ]] && echo true || echo false)"
check "client_secret do SSO não aparece em texto em arquivos versionados" \
  "$(secret_file="${work_dir}/client-secret.pat"; (umask 077; printf '%s\n' "${KC_GRAFANA_CLIENT_SECRET:-}" > "$secret_file")
    [[ -n "${KC_GRAFANA_CLIENT_SECRET:-}" ]] && ! grep -rqF -f "$secret_file" -- docker-compose.yml provisioning Dockerfile README.md CLAUDE.md docs scripts tests 2>/dev/null && echo true || echo false)"
check "segredo do SSO injetado no container pelo .env (não está na imagem)" \
  "$(ok_if grep -q '^GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=.' <<< "$env_dump")"
discovery="$(docker exec "$container" curl -s --max-time 10 "http://keycloak:8080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" || true)"
check "discovery do Keycloak alcançável de dentro do container (keycloak:8080)" "$(ok_if grep -q '"issuer"' <<< "$discovery")"
check "issuer do discovery é a URL pública do navegador (${KEYCLOAK_PUBLIC_URL})" \
  "$(ok_if grep -q "\"issuer\":\"${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}\"" <<< "$discovery")"
check "end_session_endpoint publicado (logout encerra a sessão no Keycloak)" "$(ok_if grep -q '"end_session_endpoint"' <<< "$discovery")"
check "provedor generic_oauth ativo na página de login do Grafana" \
  "$(ok_if grep -q "generic_oauth" <<< "$(curl -s --max-time 10 "${BASE_URL}/login")")"
location="$(curl -s -D - -o /dev/null --max-time 10 "${BASE_URL}/login/generic_oauth" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)"
check "/login/generic_oauth redireciona ao auth_url público do Keycloak" \
  "$([[ "$location" == "${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth?"* ]] && echo true || echo false)"
check "redirecionamento usa code_challenge_method=S256, response_type=code, state e o client grafana" \
  "$([[ "$location" == *code_challenge_method=S256* && "$location" == *response_type=code* && "$location" == *client_id=grafana* \
    && "$location" == *code_challenge=* && "$location" == *state=* ]] && echo true || echo false)"
check "redirect_uri do SSO é o exato http://localhost:3000/login/generic_oauth" \
  "$([[ "$location" == *"redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Flogin%2Fgeneric_oauth"* ]] && echo true || echo false)"

# 9. Fluxo real (navegador simulado por curl) com usuários descartáveis criados e removidos pela Admin API.
# O segredo da conta de serviço do Keycloak vem do .env do keycloak (nunca é copiado para o do grafana nem exibido).
kc_load_automation_secret
# Cabeçalho Location da primeira resposta, sem seguir redirecionamentos. Uso: location_of JAR URL [curl...]
location_of() {
  local jar="$1" url="$2"
  shift 2
  curl -s -D - -o /dev/null -c "$jar" -b "$jar" --max-time 15 "$@" "$url" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1
}
# Primeiro action="..." do formulário HTML lido da entrada padrão.
form_action() { { grep -o 'action="[^"]*"' || true; } | head -1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g'; }

# sso_login USUÁRIO: Grafana -> formulário do Keycloak -> callback. Sessão em $work_dir/<usuário>.jar.
# Ecoa o destino final do callback ("/" = entrou; /login... = negado) ou "keycloak-recusou"/"sem-formulario".
sso_login() {
  local name="$1" jar="${work_dir}/$1.jar" loc action
  loc="$(location_of "$jar" "${BASE_URL}/login/generic_oauth")"
  action="$(curl -s -c "$jar" -b "$jar" --max-time 15 "$loc" | form_action)"
  [[ -n "$action" ]] || { echo "sem-formulario"; return 0; }
  loc="$(location_of "$jar" "$action" -X POST --data-urlencode "username=${name}" --data-urlencode "password@-" < "${work_dir}/${name}.pw")"
  [[ "$loc" == "${BASE_URL}/login/generic_oauth?"* ]] || { echo "keycloak-recusou"; return 0; }
  location_of "$jar" "$loc"
}
# org_role USUÁRIO: papel na organização vista pela sessão ("" se não autenticado/sem organização).
org_role() {
  { curl -s --max-time 10 -b "${work_dir}/$1.jar" "${BASE_URL}/api/user/orgs" | grep -o '"role":"[^"]*"' || true; } | head -1 | cut -d'"' -f4
}
is_server_admin() { if curl -s --max-time 10 -b "${work_dir}/$1.jar" "${BASE_URL}/api/user" | grep -q '"isGrafanaAdmin":true'; then echo true; else echo false; fi; }
logged_in() { [[ "$1" != keycloak-* && "$1" != sem-* && "$1" != *"/login"* && -n "$1" ]] && echo true || echo false; }

if [[ -z "$automation_secret" || -z "$(kc_token)" ]]; then
  check "Admin API do Keycloak acessível (../keycloak/.env com KC_AUTOMATION_CLIENT_SECRET e Keycloak de pé) para o fluxo real" false
else
  # O Keycloak limita o username a 30 caracteres: sufixo curto para não colidir com execuções interrompidas.
  suffix="$(( $(date +%s) % 100000 ))"
  viewer="smoke.grafana.viewer.${suffix}"; editor="smoke.grafana.editor.${suffix}"
  norole="smoke.grafana.norole.${suffix}"; enduser="smoke.grafana.enduser.${suffix}"
  created=true
  make_probe_user "$viewer" grafana-viewer; [[ -n "$probe_uid" ]] || created=false
  make_probe_user "$editor" grafana-editor; [[ -n "$probe_uid" ]] || created=false
  make_probe_user "$norole"; [[ -n "$probe_uid" ]] || created=false
  make_probe_user "$enduser" user; [[ -n "$probe_uid" ]] || created=false
  check "usuários descartáveis criados pela Admin API (viewer, editor, sem role, usuário final)" "$created"

  result="$(sso_login "$viewer")"
  check "grafana-viewer entra no Grafana pelo Keycloak" "$(logged_in "$result")"
  check "grafana-viewer vira Viewer (e não Server Admin)" \
    "$([[ "$(org_role "$viewer")" == Viewer && "$(is_server_admin "$viewer")" == false ]] && echo true || echo false)"
  viewer_write="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -b "${work_dir}/${viewer}.jar" -H 'Content-Type: application/json' \
    -H "Origin: ${BASE_URL}" -d '{"dashboard":{"title":"smoke-viewer-write"},"overwrite":false}' "${BASE_URL}/api/dashboards/db")"
  check "Viewer não grava dashboards (403)" "$(eq_if "$viewer_write" 403)"

  result="$(sso_login "$editor")"
  check "grafana-editor entra e vira Editor (e não Server Admin)" \
    "$([[ "$(logged_in "$result")" == true && "$(org_role "$editor")" == Editor && "$(is_server_admin "$editor")" == false ]] && echo true || echo false)"

  result="$(sso_login "$norole")"
  check "usuário sem role grafana-* é negado (sem sessão no Grafana)" "$([[ "$result" != keycloak-* && "$result" != sem-* && -z "$(org_role "$norole")" ]] && echo true || echo false)"
  result="$(sso_login "$enduser")"
  check "usuário final do Cadastro (role user) é negado" "$([[ "$result" != keycloak-* && "$result" != sem-* && -z "$(org_role "$enduser")" ]] && echo true || echo false)"

  # O admin do realm exige OTP no Keycloak (sem como automatizar aqui): a role chega no claim e o login real é coberto no E2E (T15).
  make_probe_user "smoke.grafana.admin.${suffix}" admin; admin_uid="$probe_uid"
  grafana_client_id="$(kc_admin GET "/clients?clientId=grafana" | json_id || true)"
  admin_token="$(kc_admin GET "/clients/${grafana_client_id}/evaluate-scopes/generate-example-access-token?scope=openid&userId=${admin_uid}" || true)"
  check "token do admin do realm traz a role admin no claim roles (mapeada para Admin)" \
    "$(ok_if grep -q '"roles":\[[^]]*"admin"' <<< "$admin_token")"

  # Logout: o Grafana redireciona ao end_session do Keycloak e a sessão local deixa de valer.
  logout_loc="$(location_of "${work_dir}/${viewer}.jar" "${BASE_URL}/logout")"
  check "logout do Grafana redireciona ao end_session do Keycloak com post_logout_redirect_uri exato" \
    "$([[ "$logout_loc" == "${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/logout?"* \
      && "$logout_loc" == *"post_logout_redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Flogin"* ]] && echo true || echo false)"
  check "após o logout a sessão do Grafana não vale mais (/api/user = 401)" \
    "$(eq_if "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -b "${work_dir}/${viewer}.jar" "${BASE_URL}/api/user")" 401)"
  # Confirma o end_session no Keycloak (se ele pedir) e prova que um novo acesso volta a pedir credenciais.
  logout_action="$(curl -s -c "${work_dir}/${viewer}.jar" -b "${work_dir}/${viewer}.jar" --max-time 15 "$logout_loc" | form_action)"
  if [[ -n "$logout_action" ]]; then
    curl -s -o /dev/null -c "${work_dir}/${viewer}.jar" -b "${work_dir}/${viewer}.jar" --max-time 15 -X POST "$logout_action" --data-urlencode "confirmLogout=Logout"
  fi
  relogin_loc="$(location_of "${work_dir}/${viewer}.jar" "${BASE_URL}/login/generic_oauth")"
  relogin_page="$(curl -s -c "${work_dir}/${viewer}.jar" -b "${work_dir}/${viewer}.jar" --max-time 15 "$relogin_loc")"
  check "sessão do Keycloak encerrada: novo acesso volta a pedir usuário e senha" "$(ok_if grep -q 'name="username"' <<< "$relogin_page")"
fi
fi  # fim da parte 2 (SSO)

# UID do datasource provisionado: usado pela parte 3 e também pela 4a, que roda com --skip-datasource.
DS_UID="graylog-opensearch"
if [[ "$RUN_DATASOURCE" == true ]]; then
# 10. Datasource Graylog/OpenSearch (T07). Usa o break-glass do .env e um Viewer local descartável (mesmo papel do SSO).
# Sessão por cookie (login por stdin: a senha não aparece no argv). Uso: grafana_session JAR USUÁRIO ARQUIVO_DE_SENHA
grafana_session() {
  printf '{"user":"%s","password":"%s"}' "$2" "$(cat "$3")" \
    | curl -s -o /dev/null --max-time 10 -c "$1" -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login"
}
# Chamada autenticada com cookie e Origin (exigido pelo Grafana em métodos não seguros). Uso: gapi JAR MÉTODO CAMINHO [curl...]
gapi() {
  local jar="$1" method="$2" path="$3"
  shift 3
  curl -s --max-time 20 -X "$method" -b "$jar" -H "Origin: ${BASE_URL}" -H 'Content-Type: application/json' "$@" "${BASE_URL}${path}"
}
# Consulta de agregação (contagem agrupada por terms) pelo /api/ds/query, como o painel faria.
# Uso: ds_aggregate JAR "<lucene>" <campo> [<índice no payload>] [status]; imprime o JSON da resposta (com "status", mais uma linha final com o HTTP).
ds_aggregate() {
  local jar="$1" lucene="$2" field="$3" index="${4:-}" now from extra=""
  local curl_extra=()
  [[ "${5:-}" != status ]] || curl_extra=(-w "
%{http_code}")
  now="$(date +%s)000"; from=$((now - 3600000))
  [[ -z "$index" ]] || extra="\"index\":\"${index}\",\"database\":\"${index}\","
  printf '{"from":"%s","to":"%s","queries":[{"refId":"A","datasource":{"type":"grafana-opensearch-datasource","uid":"%s"},%s"query":"%s","queryType":"lucene","metrics":[{"type":"count","id":"1"}],"bucketAggs":[{"type":"terms","id":"2","field":"%s","settings":{"size":"10","order":"desc","orderBy":"_count","min_doc_count":"1"}}],"timeField":"timestamp"}]}' \
    "$from" "$now" "$DS_UID" "$extra" "$lucene" "$field" | gapi "$jar" POST /api/ds/query --data-binary @- "${curl_extra[@]}"
}
# Asserção de bloqueio (ADR-0004): state = open | closed | unknown. closed = OK; open (acesso concedido) ou unknown
# (5xx, rede, resposta inesperada) = FALHA: inconclusivo nunca declara o bloqueio.
denied() {
  local description="$1" state="$2"
  case "$state" in
    closed) echo "OK   ${description}" ;;
    open) echo "FALHA ${description} (acesso concedido: o opensearch-proxy não bloqueou)"; failures=$((failures + 1)) ;;
    *) echo "FALHA ${description} (resultado inconclusivo)"; failures=$((failures + 1)) ;;
  esac
}
# Estado do risco pelo status HTTP: 2xx = acesso concedido (open); 401/403/404/405 = bloqueio esperado (closed); resto = unknown.
gap_state_from_status() {
  case "$1" in
    2??) echo open ;;
    401 | 403 | 404 | 405) echo closed ;;
    *) echo unknown ;;
  esac
}

admin_pw="${work_dir}/grafana-admin.pw"; (umask 077; printf '%s' "$GRAFANA_ADMIN_PASSWORD" > "$admin_pw")
grafana_session "${work_dir}/grafana-admin.jar" "$GRAFANA_ADMIN_USER" "$admin_pw"
check "sessão do break-glass aberta para a parte 3" "$(eq_if "$(gapi "${work_dir}/grafana-admin.jar" GET /api/user | grep -c '"isGrafanaAdmin":true' || true)" 1)"

# 10.1 Configuração provisionada: sem credencial, somente leitura na UI, só os index patterns permitidos, sem PPL.
ds_json="$(gapi "${work_dir}/grafana-admin.jar" GET "/api/datasources/uid/${DS_UID}")"
check "datasource ${DS_UID} provisionado (tipo grafana-opensearch-datasource, readOnly)" \
  "$([[ "$ds_json" == *'"type":"grafana-opensearch-datasource"'* && "$ds_json" == *'"readOnly":true'* ]] && echo true || echo false)"
check "datasource sem credenciais (basicAuth off e nenhum segredo guardado)" \
  "$([[ "$ds_json" == *'"basicAuth":false'* && "$ds_json" == *'"secureJsonFields":{}'* ]] && echo true || echo false)"
ds_pattern="$(sed -n 's/^ *database: "\(.*\)"$/\1/p' provisioning/datasources/graylog-opensearch.yaml | head -1)"
check "datasource restrito ao index pattern do YAML, sem internos do Graylog/OpenSearch nem curinga total" \
  "$([[ -n "$ds_pattern" && "$ds_json" == *"\"database\":\"${ds_pattern}\""* && "$ds_pattern" != *gl-* && "$ds_pattern" != *top_queries* \
    && "$ds_pattern" != *'.plugins'* && "$ds_pattern" != '*' && "$ds_pattern" != *,'*',* ]] && echo true || echo false)"
check "PPL desligado no datasource (PPL contornaria o index pattern)" "$([[ "$ds_json" == *'"pplEnabled":false'* ]] && echo true || echo false)"
health_json="$(gapi "${work_dir}/grafana-admin.jar" GET "/api/datasources/uid/${DS_UID}/health")"
check "GET /api/datasources/uid/${DS_UID}/health = OK" "$(ok_if grep -q '"status":"OK"' <<< "$health_json")"

# 10.2 Fixture GELF sintética (sem dado pessoal) enviada ao Graylog por HTTP e agregada pelo datasource.
run_id="grafana-smoke-$(date +%s)-$RANDOM"
sent=true
for fixture in tests/fixtures/gelf/*.json; do
  code="$(sed "s/__RUN_ID__/${run_id}/g" "$fixture" | http_status -H 'Content-Type: application/json' --data-binary @- "$GELF_HTTP_URL")"
  [[ "$code" == 202 ]] || sent=false
done
check "fixtures GELF enviadas ao Graylog (HTTP 202; Graylog de pé em 127.0.0.1:12202)" "$sent"
by_service="" by_level=""
for _ in $(seq 1 30); do
  by_service="$(ds_aggregate "${work_dir}/grafana-admin.jar" "correlation_id:${run_id}" service_name)"
  [[ "$by_service" == *'"values":[["cadastro-api","legado-api"],[2,1]]'* ]] && break
  sleep 2
done
by_level="$(ds_aggregate "${work_dir}/grafana-admin.jar" "correlation_id:${run_id}" level)"
check "agregação por service_name devolve a fixture (cadastro-api=2, legado-api=1)" \
  "$([[ "$by_service" == *'"values":[["cadastro-api","legado-api"],[2,1]]'* ]] && echo true || echo false)"
check "agregação por level devolve a fixture (níveis 3, 4 e 6, um evento cada)" \
  "$(level_re='^\[\[[346],[346],[346]\],\[1,1,1\]\]'
    level_values="${by_level##*\"values\":}"
    [[ "$level_values" =~ $level_re && "$level_values" == *3* && "$level_values" == *4* && "$level_values" == *6* ]] && echo true || echo false)"

# 10.3 Viewer x índices (risco residual do ADR-0001): o Viewer só consegue o que o datasource permite?
viewer_login="smoke-ds-viewer-$((RANDOM % 10000))"
viewer_pw="${work_dir}/grafana-viewer.pw"; (umask 077; printf '%s-Aa1' "$(openssl rand -hex 12)" > "$viewer_pw")
viewer_id="$(printf '{"name":"Smoke DS Viewer","login":"%s","email":"%s@smoke.invalid","password":"%s"}' "$viewer_login" "$viewer_login" "$(cat "$viewer_pw")" \
  | gapi "${work_dir}/grafana-admin.jar" POST /api/admin/users --data-binary @- | { grep -o '"id":[0-9]*' || true; } | head -1 | cut -d: -f2)"
if [[ -n "$viewer_id" ]]; then
  grafana_probe_ids+=("$viewer_id")
  printf '{"role":"Viewer"}' | gapi "${work_dir}/grafana-admin.jar" PATCH "/api/org/users/${viewer_id}" --data-binary @- >/dev/null
  grafana_session "${work_dir}/grafana-viewer.jar" "$viewer_login" "$viewer_pw"
  viewer_jar="${work_dir}/grafana-viewer.jar"
  check "Viewer consulta agregações pelo /api/ds/query (dentro do index pattern)" \
    "$([[ "$(ds_aggregate "$viewer_jar" "correlation_id:${run_id}" service_name)" == *'"values":[["cadastro-api","legado-api"],[2,1]]'* ]] && echo true || echo false)"
  # Os 4 riscos do ADR-0001 foram fechados pelo opensearch-proxy (ADR-0004): agora são ASSERTIVAS de bloqueio.
  # "index" no corpo substitui o pattern no plugin, mas o proxy valida o índice de cada cabeçalho do _msearch (403).
  override="$(ds_aggregate "$viewer_jar" "*" event_definition_type gl-events_0 status)"
  override_status="${override##*$'\n'}"
  override_body="${override%$'\n'*}"
  override_state=unknown
  if [[ "$override_body" == *aggregation-v1* ]]; then override_state=open                                   # leu o índice fora do pattern
  elif [[ "$override_status" =~ ^(400|401|403|404)$ || "$override_body" == *'"error"'* ]]; then override_state=closed
  fi
  denied "Viewer NÃO lê índice fora do pattern (gl-events_0) pelo /api/ds/query com o campo index no corpo (HTTP ${override_status:-?})" "$override_state"
  indices="$(ds_aggregate "$viewer_jar" "*" _index)"
  check "agregação por _index do Viewer SEM o campo index só lista índices do pattern" \
    "$([[ "$indices" == *'"values":[['* && "$indices" != *gl-events* && "$indices" != *top_queries* && "$indices" != *.plugins* ]] && echo true || echo false)"
  # O proxy genérico de datasource repassa o caminho ao opensearch-proxy, que só aceita a allowlist.
  proxy_status="$(http_status -b "$viewer_jar" "${BASE_URL}/api/datasources/proxy/uid/${DS_UID}/_cat/indices")"
  denied "Viewer NÃO lista índices por /api/datasources/proxy (GET _cat/indices, HTTP ${proxy_status})" "$(gap_state_from_status "$proxy_status")"
  # Escrita: tenta criar e apagar um índice descartável FORA do pattern; se o PUT passar (regressão), apaga no fim pelo break-glass.
  probe_index="smoke-write-probe-${RANDOM}${RANDOM}"
  put_status="$(http_status -X PUT -b "$viewer_jar" -H "Origin: ${BASE_URL}" "${BASE_URL}/api/datasources/proxy/uid/${DS_UID}/${probe_index}")"
  denied "Viewer NÃO cria índice por /api/datasources/proxy (PUT, HTTP ${put_status})" "$(gap_state_from_status "$put_status")"
  delete_status="$(http_status -X DELETE -b "$viewer_jar" -H "Origin: ${BASE_URL}" "${BASE_URL}/api/datasources/proxy/uid/${DS_UID}/${probe_index}")"
  # Um 404 do OpenSearch indicaria que o DELETE chegou lá: só vale como bloqueio se o proxy respondeu 403.
  delete_state=unknown
  if [[ "$delete_status" == 403 ]]; then delete_state=closed; elif [[ "$delete_status" =~ ^2 ]]; then delete_state=open; fi
  denied "Viewer NÃO apaga índices por /api/datasources/proxy (DELETE, HTTP ${delete_status})" "$delete_state"
  gapi "${work_dir}/grafana-admin.jar" DELETE "/api/datasources/proxy/uid/${DS_UID}/${probe_index}" >/dev/null 2>&1 || true
  # Leitura permitida continua funcionando pela mesma rota (versão do cluster).
  check "Viewer ainda lê a rota permitida por /api/datasources/proxy (GET /, HTTP 200)" "$(eq_if "$(http_status -b "$viewer_jar" "${BASE_URL}/api/datasources/proxy/uid/${DS_UID}/")" 200)"
else
  check "Viewer local descartável criado para o teste de índices" false
fi
fi  # fim da parte 3 (datasource)

if [[ "$RUN_ALERTS" == true || "$RUN_METRICS" == true ]]; then
# Parte 4: helpers comuns (sessão do break-glass, API autenticada, jq local ou imagem pinada).
JQ_IMAGE="ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432"
# jq sobre a entrada padrão. O título/uid a filtrar vai pela variável de ambiente FILTER_VALUE (lida com env.FILTER_VALUE no jq).
jqs() {
  if command -v jq >/dev/null 2>&1; then jq "$@"; else docker run -i --rm -e FILTER_VALUE "$JQ_IMAGE" "$@"; fi
}
alerts_jar="${work_dir}/alerts-admin.jar"
alerts_pw="${work_dir}/alerts-admin.pw"; (umask 077; printf '%s' "$GRAFANA_ADMIN_PASSWORD" > "$alerts_pw")
printf '{"user":"%s","password":"%s"}' "$GRAFANA_ADMIN_USER" "$(cat "$alerts_pw")" \
  | curl -s -o /dev/null --max-time 10 -c "$alerts_jar" -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login"
# Chamada autenticada (cookie + Origin). Uso: aapi MÉTODO CAMINHO [curl...]
aapi() {
  local method="$1" path="$2"
  shift 2
  curl -s --max-time 20 -X "$method" -b "$alerts_jar" -H "Origin: ${BASE_URL}" -H 'Content-Type: application/json' "$@" "${BASE_URL}${path}"
}
# "<estado> <saúde>" da regra com esse título (state: inactive/pending/firing; health: ok/error/nodata); vazio se não existe.
rule_state() {
  aapi GET /api/prometheus/grafana/api/v1/rules | FILTER_VALUE="$1" jqs -r '[.data.groups[].rules[] | select(.name == env.FILTER_VALUE)][0] | select(. != null) | "\(.state) \(.health)"'
}
# Espera (até $3 s) a regra "$1" chegar ao estado "$2" (inactive|pending|firing). Sai com 0 se chegou.
wait_rule_state() {
  local title="$1" want="$2" max="$3" waited=0 got=""
  while [[ $waited -lt $max ]]; do
    got="$(rule_state "$title")"
    [[ "${got%% *}" == "$want" ]] && return 0
    sleep 10; waited=$((waited + 10))
  done
  return 1
}
fi

if [[ "$RUN_ALERTS" == true ]]; then
# 11. Parte 4a (T14): alertas como código. Regras, contact point sem envio externo e Firing -> Normal com fixture GELF.
rules_json="$(aapi GET /api/v1/provisioning/alert-rules)"
check "regras de alerta carregadas por arquivo (provisioning/alerting)" \
  "$(n="$(jqs -r 'length' <<< "$rules_json")"; [[ "$n" -ge 6 ]] && echo true || echo false)"
for title in "Cadastro - Taxa de erros alta" "Legado - Taxa de erros alta" "Keycloak - Falhas de login em rajada" "Plataforma - Serviço sem logs"; do
  check "regra \"${title}\" carregada, com labels project e severity" \
    "$(FILTER_VALUE="$title" jqs -r '[.[] | select(.title == env.FILTER_VALUE)] | length == 1 and (.[0].labels | has("project") and has("severity"))' <<< "$rules_json")"
done
check "regras provisionadas por arquivo ficam somente leitura na API (provenance file)" \
  "$(jqs -r '[.[] | select(.uid | test("^(cadastro-error-rate|legado-error-rate|keycloak-login-burst|platform-service-without-logs|api-down|api-no-data|api-target-unresolved)$"))] | all(.provenance == "file")' <<< "$rules_json")"
check "regras de log do smoke_test:true e ruído do health check do Cadastro excluídos (serviço sem logs e taxa de erros)" \
  "$(jqs -r '([.[] | select(.uid == "platform-service-without-logs") | .data[] | select(.model.query != null) | .model.query] | all(contains("NOT smoke_test:true"))) and ([.[] | select(.uid == "cadastro-error-rate") | .data[] | select(.model.query != null) | .model.query] | all(contains("KeycloakHealthCheck")))' <<< "$rules_json")"

contact_json="$(aapi GET /api/v1/provisioning/contact-points)"
check "contact point ui-only existe e é só e-mail (sem webhook/Slack/etc.)" \
  "$(jqs -r '[.[] | select(.name == "ui-only")] | length >= 1 and all(.type == "email")' <<< "$contact_json")"
check "SMTP do Grafana desligado (GF_SMTP_ENABLED=false): e-mail não tem como sair" "$(ok_if grep -qx 'GF_SMTP_ENABLED=false' <<< "$env_dump")"
policy_json="$(aapi GET /api/v1/provisioning/policies)"
check "política de notificação: receiver ui-only e rota filha silenciada pelo mute timing always" \
  "$(jqs -r '.receiver == "ui-only" and ([.routes[]? | select(.receiver == "ui-only" and ((.mute_time_intervals // []) | index("always") != null))] | length >= 1)' <<< "$policy_json")"
check "mute timing always cobre o dia todo, todos os dias" \
  "$(jqs -r '[.[] | select(.name == "always")] | length == 1 and (.[0].time_intervals[0].times[0].start_time == "00:00") and (.[0].time_intervals[0].times[0].end_time == "24:00")' <<< "$(aapi GET /api/v1/provisioning/mute-timings)")"

# As regras avaliam sem erro contra o OpenSearch real (aguarda a primeira avaliação, até 3 min).
eval_ok=false
for _ in $(seq 1 18); do
  bad_rules="$(aapi GET /api/prometheus/grafana/api/v1/rules | jqs -r '[.data.groups[].rules[] | select(.name | test("Taxa de erros|rajada|Serviço sem logs")) | select(.health != "ok")] | length')"
  [[ "$bad_rules" == 0 ]] && { eval_ok=true; break; }
  sleep 10
done
check "as 4 regras de log avaliam com saúde ok contra o datasource graylog-opensearch" "$eval_ok"

# Firing -> Normal da regra real "Legado - Taxa de erros alta" (limiar 20%, volume mínimo 10 logs, janela de 5 min). O legado-api
# gera logs reais continuamente (sondas de health), então o volume de erros sintéticos é proporcional ao total medido na janela:
# N = max(12, ceil(total/2) + 6) leva a taxa a >= 33% mesmo que o total cresça ~30% até a avaliação. Os erros sintéticos têm
# smoke_test="alert-fixture" (não é o "true" ignorado pelas regras), então contam na regra.
legado_rule="Legado - Taxa de erros alta"
check "regra \"${legado_rule}\" parte de Normal (sem erros reais do legado na janela)" \
  "$(wait_rule_state "$legado_rule" inactive 120 && echo true || echo false)"
# Total de logs do legado na janela de 5 min, com a mesma consulta da regra (agregação por service_name pelo /api/ds/query).
legado_now="$(date +%s)000"
legado_total="$(printf '{"from":"%s","to":"%s","queries":[{"refId":"A","datasource":{"type":"grafana-opensearch-datasource","uid":"%s"},"queryType":"lucene","query":"service_name:legado-* AND NOT smoke_test:true","metrics":[{"id":"1","type":"count"}],"bucketAggs":[{"id":"2","type":"terms","field":"service_name","settings":{"size":"10","order":"desc","orderBy":"_count","min_doc_count":"1"}}],"timeField":"timestamp"}]}' \
  "$((legado_now - 300000))" "$legado_now" "$DS_UID" | aapi POST /api/ds/query --data-binary @- | jqs -r '[.results.A.frames[0].data.values[1][]?] | add // 0')"
[[ "$legado_total" =~ ^[0-9]+$ ]] || legado_total=0
alert_count=$(((legado_total + 1) / 2 + 6))
[[ $alert_count -ge 12 ]] || alert_count=12
alert_run_id="grafana-alert-$(date +%s)-$RANDOM"
sent=true
for _ in $(seq 1 "$alert_count"); do
  code="$(sed "s/__RUN_ID__/${alert_run_id}/g" tests/fixtures/alerts/legado-api-error.json | http_status -H 'Content-Type: application/json' --data-binary @- "$GELF_HTTP_URL")"
  [[ "$code" == 202 ]] || sent=false
done
check "${alert_count} erros sintéticos do legado-api enviados ao Graylog (HTTP 202; total real na janela: ${legado_total})" "$sent"
check "regra \"${legado_rule}\" vai a Firing (até 4 min)" "$(wait_rule_state "$legado_rule" firing 240 && echo true || echo false)"
check "regra \"${legado_rule}\" volta a Normal quando os erros saem da janela de 5 min (até 9 min)" \
  "$(wait_rule_state "$legado_rule" inactive 540 && echo true || echo false)"
fi  # fim da parte 4a

if [[ "$RUN_METRICS" == true ]]; then
# 12. Parte 4b (T17): health das APIs. Datasource prometheus, dashboard, isolamento de rede e alerta "API fora do ar" x DNS.
PROM_DS="prometheus"
ds_prom_json="$(aapi GET "/api/datasources/uid/${PROM_DS}")"
check "datasource ${PROM_DS} provisionado (tipo prometheus, readOnly, sem credenciais)" \
  "$([[ "$ds_prom_json" == *'"type":"prometheus"'* && "$ds_prom_json" == *'"readOnly":true'* && "$ds_prom_json" == *'"basicAuth":false'* \
    && "$ds_prom_json" == *'"secureJsonFields":{}'* && "$ds_prom_json" == *'"url":"http://prometheus:9090"'* ]] && echo true || echo false)"
check "GET /api/datasources/uid/${PROM_DS}/health = OK" "$(ok_if grep -q '"status":"OK"' <<< "$(aapi GET "/api/datasources/uid/${PROM_DS}/health")")"
# prom_query DS_UID "<promql>": consulta instantânea pelo /api/ds/query, como um painel faria.
prom_query() {
  local now
  now="$(date +%s)000"
  printf '{"from":"%s","to":"%s","queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"%s"},"expr":"%s","instant":true,"range":false}]}' \
    "$((now - 300000))" "$now" "$1" "${2//\"/\\\"}" | aapi POST /api/ds/query --data-binary @-
}
live_resp="$(prom_query "$PROM_DS" 'probe_success{job="api-health",project="cadastro",endpoint="live"}')"
check "consulta de probe_success (cadastro/live) devolve dados (valor 1 = UP)" \
  "$([[ "$live_resp" =~ \"values\":\[\[[0-9]+\],\[1\]\] ]] && echo true || echo false)"
avail_resp="$(prom_query "$PROM_DS" 'project_endpoint:probe_success:avg_over_time24h{project!="smoke"}')"
check "regra gravada de disponibilidade 24h devolve dados (painel de disponibilidade)" "$([[ "$avail_resp" == *'"values":[['* ]] && echo true || echo false)"
check "dashboard api-health provisionado (Plataforma - Saúde das APIs)" \
  "$(ok_if grep -q '"title":"Plataforma - Saúde das APIs"' <<< "$(aapi GET /api/dashboards/uid/api-health)")"
rules_api_json="$(aapi GET /api/v1/provisioning/alert-rules)"
check "regras \"API fora do ar\" (failure_kind=api_down) e \"Alvo não resolve\" (failure_kind=dns) carregadas com rótulos distintos" \
  "$(jqs -r '([.[] | select(.uid == "api-down" and .labels.failure_kind == "api_down")] | length == 1) and ([.[] | select(.uid == "api-target-unresolved" and .labels.failure_kind == "dns")] | length == 1)' <<< "$rules_api_json")"
check "regra de ausência de dado (api-no-data, failure_kind=no_data) carregada e usa absent(probe_success)"   "$(jqs -r '[.[] | select(.uid == "api-no-data" and .labels.failure_kind == "no_data" and .noDataState == "Alerting" and (.data[0].model.expr | contains("absent(probe_success")))] | length == 1' <<< "$rules_api_json")"
# Isolamento: o Grafana lê o Prometheus, mas não alcança o blackbox nem as APIs (só o blackbox está nas redes delas).
check "Grafana alcança o Prometheus (prometheus:9090) pela rede metrics" \
  "$(ok_if docker exec "$container" curl -sf --max-time 5 http://prometheus:9090/-/ready)"
check "Grafana NÃO alcança o blackbox (blackbox:9115)" "$([[ -z "$(docker exec "$container" curl -s --max-time 5 http://blackbox:9115/-/healthy 2>/dev/null || true)" ]] && echo true || echo false)"
# O Grafana já divide as redes observability/workspace-identity com as APIs (GELF e SSO, bem antes da T17): isso não vem da rede
# metrics. Por isso o alcance direto às APIs é registrado como risco conhecido (não reprova); a rede metrics, essa sim, não dá rota.
# Usa os aliases estáveis (cadastro-api/legado-api, os mesmos dos alvos do Prometheus), não os nomes de container: estes mudam com
# projeto/escala e, se não resolvessem, o teste passaria em falso. O alias cadastro-api só existe em cadastro_default (o Grafana não está
# nela); o legado-api também é alias na workspace-identity quando o overlay docker-compose.identity.yml do legado está de pé, e ali o
# Grafana o alcança: o teste registra o que for verdade.
for api_url in http://cadastro-api:8080/health/live http://legado-api:8080/health/live; do
  if docker exec "$container" curl -sf --max-time 5 "$api_url" >/dev/null 2>&1; then
    echo "RISCO CONHECIDO Grafana alcança ${api_url%%/health*} por redes compartilhadas anteriores à T17 (observability/workspace-identity), não pela rede metrics"
    open_gaps+=("Grafana alcança ${api_url%%/health*} por observability/workspace-identity (anterior à T17; a rede metrics não dá rota)")
  else
    echo "OK   Grafana NÃO alcança a API (${api_url%%/health*})"
  fi
done
metrics_members="$(docker network inspect metrics -f '{{range .Containers}}{{.Name}} {{end}}')"
check "rede metrics tem só Prometheus e Grafana (sem blackbox nem API)" \
  "$([[ "$metrics_members" == *prometheus* && "$metrics_members" == *grafana-grafana* && "$metrics_members" != *blackbox* && "$metrics_members" != *api* ]] && echo true || echo false)"

# Alerta com alvo falso e Prometheus DESCARTÁVEL (as APIs reais não são paradas): copia das expressões das regras reais
# (uid api-down e api-target-unresolved), trocando project!="smoke" por project="smoke" e apontando para o datasource temporário.
prom_image="$(docker inspect -f '{{.Config.Image}}' "$(docker compose -f prometheus/docker-compose.metrics.yml ps -q prometheus 2>/dev/null)" 2>/dev/null || true)"
if [[ -z "$prom_image" ]]; then
  check "stack grafana-metrics de pé (docker compose -f prometheus/docker-compose.metrics.yml up -d)" false
else
  smoke_targets_dir="$(mktemp -d)"
  smoke_targets_win="$(cygpath -m "$smoke_targets_dir" 2>/dev/null || echo "$smoke_targets_dir")"
  cat > "${smoke_targets_dir}/fixture.yml" <<YAML
# Gerado pelo smoke-test.sh (diretório temporário, removido ao final): alvo falso que responde 200 (depois 404) e um nome que
# não resolve. Mesmos rótulos das APIs reais, mas project=smoke.
- targets: ["http://${SMOKE_API}:8080/health/ready"]
  labels: {project: smoke, endpoint: ready}
- targets: ["http://smoke-grafana-no-such-host.invalid:8080/health/ready"]
  labels: {project: smoke, endpoint: ready}
YAML
  chmod 755 "$smoke_targets_dir"; chmod 644 "${smoke_targets_dir}/fixture.yml"
  docker rm -f "$SMOKE_API" "$SMOKE_PROM" >/dev/null 2>&1 || true
  MSYS_NO_PATHCONV=1 docker run -d --name "$SMOKE_API" --network metrics-probe --network-alias "$SMOKE_API" --user 65534:65534 --entrypoint sh "$prom_image" \
    -c 'mkdir -p /tmp/www/health && echo ok > /tmp/www/health/ready && exec httpd -f -p 8080 -h /tmp/www' >/dev/null
  MSYS_NO_PATHCONV=1 docker run -d --name "$SMOKE_PROM" --network metrics-probe --user 65534:65534 --read-only --tmpfs /prometheus:uid=65534 \
    --cap-drop ALL --security-opt no-new-privileges \
    -v "$(pwd -W 2>/dev/null || pwd)/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    -v "$(pwd -W 2>/dev/null || pwd)/prometheus/rules.yml:/etc/prometheus/rules.yml:ro" \
    -v "${smoke_targets_win}:/etc/prometheus/targets:ro" "$prom_image" \
    --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=1h >/dev/null
  docker network connect --alias "$SMOKE_PROM" metrics "$SMOKE_PROM"
  # Datasource, pasta e regras temporários no Grafana (removidos no trap).
  printf '{"name":"smoke-prometheus","uid":"%s","type":"prometheus","access":"proxy","url":"http://%s:9090"}' "$SMOKE_DS_UID" "$SMOKE_PROM" \
    | aapi POST /api/datasources --data-binary @- >/dev/null
  printf '{"uid":"%s","title":"smoke-alerts-tmp"}' "$SMOKE_FOLDER_UID" | aapi POST /api/folders --data-binary @- >/dev/null
  # rule_expr UID: expressão PromQL da regra real, com o filtro de séries trocado para o alvo falso.
  rule_expr() {
    sed -n "/uid: $1\$/,/expr:/{s/^ *expr: '\\(.*\\)'\$/\\1/p}" provisioning/alerting/rules.yaml | sed 's/project!="smoke"/project="smoke"/g'
  }
  # create_smoke_rule UID TÍTULO FAILURE_KIND: cópia da regra real (condição > 0 sobre a contagem), for 0s, no datasource temporário.
  create_smoke_rule() {
    local expr
    expr="$(rule_expr "$1")"
    printf '{"uid":"smoke-%s","title":"%s","folderUID":"%s","ruleGroup":"smoke","orgID":1,"condition":"C","for":"0s","noDataState":"OK","execErrState":"Error","labels":{"failure_kind":"%s"},"annotations":{},"data":[{"refId":"A","relativeTimeRange":{"from":600,"to":0},"datasourceUid":"%s","model":{"refId":"A","datasource":{"type":"prometheus","uid":"%s"},"expr":"%s","instant":true,"range":false}},{"refId":"R1","datasourceUid":"__expr__","model":{"refId":"R1","type":"reduce","expression":"A","reducer":"last","settings":{"mode":"dropNN"},"datasource":{"type":"__expr__","uid":"__expr__"}}},{"refId":"C","datasourceUid":"__expr__","model":{"refId":"C","type":"threshold","expression":"R1","conditions":[{"evaluator":{"type":"gt","params":[0]}}],"datasource":{"type":"__expr__","uid":"__expr__"}}}]}' \
      "$1" "$2" "$SMOKE_FOLDER_UID" "$3" "$SMOKE_DS_UID" "$SMOKE_DS_UID" "${expr//\"/\\\"}" | aapi POST /api/v1/provisioning/alert-rules --data-binary @-
  }
  check "expressões das regras reais extraídas do rules.yaml (API fora e DNS)" \
    "$([[ -n "$(rule_expr api-down)" && -n "$(rule_expr api-target-unresolved)" ]] && echo true || echo false)"
  create_smoke_rule api-down smoke-api-down api_down >/dev/null
  create_smoke_rule api-target-unresolved smoke-api-dns dns >/dev/null
  # Espera o Prometheus descartável coletar o alvo falso (até 90 s).
  smoke_up=false
  for _ in $(seq 1 18); do
    [[ "$(prom_query "$SMOKE_DS_UID" 'probe_success{project="smoke",instance=~".*smoke-grafana-api.*"}')" =~ \"values\":\[\[[0-9]+\],\[1\]\] ]] && { smoke_up=true; break; }
    sleep 5
  done
  check "alvo falso no ar: probe_success = 1 no Prometheus descartável" "$smoke_up"
  # Com o alvo falso saudável, só o nome que não resolve (DNS) alerta; a regra de API fora segue Normal (distinção).
  check "nome que não resolve: a regra \"alvo não resolve (DNS)\" vai a Firing (até 4 min)" "$(wait_rule_state smoke-api-dns firing 240 && echo true || echo false)"
  check "alvo falso saudável: a regra \"API fora do ar\" fica Normal (DNS não é confundido com API fora)" \
    "$([[ "$(rule_state smoke-api-down)" == inactive* ]] && echo true || echo false)"
  # Quebra o alvo falso (404 no /health/ready; o nome continua resolvendo): vira "API fora do ar".
  MSYS_NO_PATHCONV=1 docker exec "$SMOKE_API" rm /tmp/www/health/ready
  check "alvo falso derrubado (nome resolve): a regra \"API fora do ar\" vai a Firing (até 4 min)" "$(wait_rule_state smoke-api-down firing 240 && echo true || echo false)"
  MSYS_NO_PATHCONV=1 docker exec "$SMOKE_API" sh -c 'echo ok > /tmp/www/health/ready'
  check "alvo falso de volta: a regra \"API fora do ar\" volta a Normal (até 4 min)" "$(wait_rule_state smoke-api-down inactive 240 && echo true || echo false)"
  rm -rf "$smoke_targets_dir"
fi
fi  # fim da parte 4b

if [[ $failures -ne 0 ]]; then echo "smoke-test: ${failures} falha(s)"; exit 1; fi
parts="1"
[[ "$RUN_SSO" == true ]] && parts="${parts}, 2 (SSO)"
[[ "$RUN_DATASOURCE" == true ]] && parts="${parts}, 3 (datasource)"
[[ "$RUN_ALERTS" == true ]] && parts="${parts}, 4a (alertas)"
[[ "$RUN_METRICS" == true ]] && parts="${parts}, 4b (health das APIs)"
if [[ "$RUN_DATASOURCE" != true ]]; then
  echo "smoke-test (partes ${parts}): APROVADO. Bloqueios do opensearch-proxy (ADR-0004) NÃO avaliados (parte 3 não executada)."
elif [[ ${#open_gaps[@]} -eq 0 ]]; then
  echo "smoke-test (partes ${parts}): APROVADO, 0 riscos conhecidos abertos"
else
  echo "smoke-test (partes ${parts}): APROVADO COM ${#open_gaps[@]} RISCO(S) CONHECIDO(S) ABERTO(S) (não está fechado):"
  for gap in "${open_gaps[@]}"; do echo "  - ${gap}"; done
fi
