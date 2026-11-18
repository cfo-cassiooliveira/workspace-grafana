#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034,SC2329 # variáveis vêm do script que faz o source; funções usadas pelos chamadores
# Funções compartilhadas (smoke-test.sh parte 2 e e2e.sh): Admin API do Keycloak e usuários descartáveis.
# Chamador define: work_dir, BASE_URL, KEYCLOAK_PUBLIC_URL, KEYCLOAK_REALM, GRAFANA_ADMIN_USER/PASSWORD (para
# remove_sso_users_from_grafana) e os arrays probe_ids e sso_probe_logins. Segredos nunca vão no argv.

# Lê o segredo da conta de serviço do Keycloak (../keycloak/.env) sem imprimir; deixa em automation_secret.
kc_load_automation_secret() {
  automation_secret="$({ grep -m1 '^KC_AUTOMATION_CLIENT_SECRET=' ../keycloak/.env 2>/dev/null || true; } | cut -d= -f2- | tr -d '\r')"
}

# Usuários criados no Grafana pelo login SSO entrariam nos backups (SQLite): remove-os pela Admin API (break-glass).
remove_sso_users_from_grafana() {
  local login uid jar="${work_dir}/cleanup-admin.jar"
  [[ ${#sso_probe_logins[@]} -gt 0 ]] || return 0
  printf '{"user":"%s","password":"%s"}' "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD" \
    | curl -s -o /dev/null --max-time 10 -c "$jar" -H 'Content-Type: application/json' --data-binary @- "${BASE_URL}/login" || true
  for login in "${sso_probe_logins[@]}"; do
    uid="$({ curl -s --max-time 10 -b "$jar" "${BASE_URL}/api/users/lookup?loginOrEmail=${login}" | grep -o '"id":[0-9]*' || true; } | head -1 | cut -d: -f2)"
    [[ -z "$uid" ]] || curl -s -o /dev/null --max-time 10 -X DELETE -b "$jar" -H "Origin: ${BASE_URL}" "${BASE_URL}/api/admin/users/${uid}" || true
  done
}

kc_token() {
  printf '%s' "$automation_secret" | curl -fs --max-time 10 "${KEYCLOAK_PUBLIC_URL}/realms/master/protocol/openid-connect/token" \
    --data-urlencode "grant_type=client_credentials" --data-urlencode "client_id=workspace-automation" \
    --data-urlencode "client_secret@-" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true
}
# kc_admin MÉTODO CAMINHO [curl...]: Admin API do realm com token novo. O Bearer vai num arquivo -K (0600), nunca no argv;
# corpo e senha vão por --data-binary @-.
kc_admin() {
  local method="$1" path="$2" token curlrc="${work_dir}/kc-bearer.curlrc"
  shift 2
  token="$(kc_token)"
  (umask 077; printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curlrc")
  curl -fs --max-time 15 -K "$curlrc" -X "$method" -H 'Content-Type: application/json' \
    "${KEYCLOAK_PUBLIC_URL}/admin/realms/${KEYCLOAK_REALM}${path}" "$@"
}
json_id() { { grep -o '"id":"[^"]*"' || true; } | head -1 | cut -d'"' -f4; }

# Cria o usuário descartável (senha aleatória em $work_dir/<nome>.pw, 0600) e a role opcional; deixa o id em probe_uid
# (sem subshell, para o cleanup enxergar probe_ids).
make_probe_user() {
  local name="$1" role="${2:-}" uid role_id
  probe_uid=""
  (umask 077; printf '%s-Aa1!' "$(openssl rand -hex 12)" > "${work_dir}/${name}.pw")
  printf '{"username":"%s","email":"%s@smoke.invalid","firstName":"Smoke","lastName":"Grafana","enabled":true,"emailVerified":true,"credentials":[{"type":"password","temporary":false,"value":"%s"}]}' \
    "$name" "$name" "$(cat "${work_dir}/${name}.pw")" | kc_admin POST /users --data-binary @- >/dev/null || true
  uid="$(kc_admin GET "/users?username=${name}&exact=true" | json_id || true)"
  if [[ -n "$uid" ]]; then
    probe_ids+=("$uid")
    sso_probe_logins+=("$name")
    if [[ -n "$role" ]]; then
      role_id="$(kc_admin GET "/roles/${role}" | json_id || true)"
      printf '[{"id":"%s","name":"%s"}]' "$role_id" "$role" | kc_admin POST "/users/${uid}/role-mappings/realm" --data-binary @- >/dev/null || true
    fi
  fi
  probe_uid="$uid"
}
