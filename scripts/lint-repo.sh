#!/usr/bin/env bash
# Teste estático do repositório: sintaxe/shellcheck dos .sh, ausência de segredos, .env ignorado
# e comportamento do generate-env.sh (0600, não sobrescreve, valores aleatórios).
# Uso: ./scripts/lint-repo.sh   (sai com código != 0 se algo falhar)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FALHA $*"; fail=1; }
# check "descrição" comando...: OK se o comando retornar 0, FALHA caso contrário.
check() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
get_var() { sed -n "s/^$1=//p" "$2"; }

mapfile -t scripts < <(find scripts tests -name '*.sh' -type f | sort)

# 1. Sintaxe e shellcheck (local, depois Docker; sem nenhum dos dois, só `bash -n` e avisa).
for f in "${scripts[@]}"; do check "bash -n $f" bash -n "$f"; done
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck" shellcheck -x -P SCRIPTDIR "${scripts[@]}"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  check "shellcheck (docker)" env MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/mnt" \
    -w /mnt koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d -x -P SCRIPTDIR "${scripts[@]}"
else
  echo "AVISO shellcheck indisponível (nem local nem Docker); só a checagem de sintaxe foi feita."
fi

# Procura o caractere CR (retorno de carro) via grep -P.
no_crlf() { ! grep -qP '\r' "$1"; }
for f in "${scripts[@]}"; do check "LF $f" no_crlf "$f"; done

# 3. Segredos: nenhum valor atribuído a variáveis sensíveis nem chaves privadas em arquivos versionáveis.
secret_re='(PASSWORD|SECRET|TOKEN|API_KEY|SECRET_KEY)[A-Z_]*[[:space:]]*[=:][[:space:]]*["'\'']?[A-Za-z0-9+/_-]{12,}'
hits="$(grep -rEn --exclude-dir=.git --exclude-dir=.backups --exclude-dir=docs --exclude='.env' --exclude='lint-repo.sh' \
  -e "$secret_re" -e 'BEGIN [A-Z ]*PRIVATE KEY' . || true)"
if [[ -n "$hits" ]]; then bad "possível segredo no repositório:"; printf '     %s\n' "$hits"; else ok "sem segredos versionáveis"; fi

# 4. .env ignorado pelo git (git check-ignore quando for repositório; senão confere o .gitignore).
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  check ".env ignorado (git check-ignore)" git check-ignore -q .env
else
  check ".env listado no .gitignore" grep -qxF '.env' .gitignore
fi
check ".backups/ ignorado" grep -qxF '.backups/' .gitignore
check ".gitattributes força LF em *.sh" grep -qE '^\*\.sh[[:space:]]+text eol=lf' .gitattributes

# 5. generate-env.sh em diretório temporário (não toca no .env real).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/scripts"
cp scripts/generate-env.sh "$tmp/scripts/"
(cd "$tmp" && ./scripts/generate-env.sh >/dev/null)
env_file="$tmp/.env"
check "generate-env.sh criou o .env" test -f "$env_file"
perm="$(stat -c '%a' "$env_file")"
# NTFS (Git Bash) reporta 644/666; em Linux/WSL a permissão deve ser exatamente 600.
case "$(uname -s)" in
  MINGW* | MSYS*) [[ "$perm" == "600" ]] && ok ".env 0600" || echo "AVISO permissão $perm não verificável no NTFS (Git Bash)" ;;
  *) check ".env com permissão 0600" test "$perm" = "600" ;;
esac
user="$(get_var GRAFANA_ADMIN_USER "$env_file")"
pw="$(get_var GRAFANA_ADMIN_PASSWORD "$env_file")"
key="$(get_var GF_SECURITY_SECRET_KEY "$env_file")"
check "GRAFANA_ADMIN_USER não padrão" test -n "$user" -a "$user" != "admin"
check "senha >= 32 e secret_key >= 48 caracteres" test "${#pw}" -ge 32 -a "${#key}" -ge 48
before="$(cksum < "$env_file")"
(cd "$tmp" && ./scripts/generate-env.sh >/dev/null)
check "segunda execução não sobrescreve" test "$before" = "$(cksum < "$env_file")"
rm "$env_file"
(cd "$tmp" && ./scripts/generate-env.sh >/dev/null)
check "segredos diferentes a cada geração" test "$pw" != "$(get_var GRAFANA_ADMIN_PASSWORD "$env_file")"
cd "$ROOT"

# 5b. Segredo do SSO (T06): copiado de ../keycloak/.env sem aparecer na saída e sem sobrescrever o que já existe.
mkdir -p "$tmp/sso/grafana/scripts" "$tmp/sso/keycloak"
cp scripts/generate-env.sh "$tmp/sso/grafana/scripts/"
printf 'KC_GRAFANA_CLIENT_SECRET=lint-fake-secret-123\r\n' > "$tmp/sso/keycloak/.env"
sso_out="$(cd "$tmp/sso/grafana" && ./scripts/generate-env.sh)"
check "KC_GRAFANA_CLIENT_SECRET copiado do keycloak (sem CR)" test "$(get_var KC_GRAFANA_CLIENT_SECRET "$tmp/sso/grafana/.env")" = "lint-fake-secret-123"
check "generate-env.sh não imprime o segredo do SSO" test "${sso_out#*lint-fake-secret-123}" = "$sso_out"
printf 'KC_GRAFANA_CLIENT_SECRET=outro-valor\n' > "$tmp/sso/keycloak/.env"
(cd "$tmp/sso/grafana" && ./scripts/generate-env.sh >/dev/null)
check "segredo do SSO existente não é sobrescrito" test "$(get_var KC_GRAFANA_CLIENT_SECRET "$tmp/sso/grafana/.env")" = "lint-fake-secret-123"

# Cenário "env ausente" da spec (H1): sem as variáveis o compose deve falhar dizendo qual definir no .env.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  : > "$tmp/empty.env"
  empty_env="$(cygpath -m "$tmp/empty.env" 2>/dev/null || echo "$tmp/empty.env")"
  for var in GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GF_SECURITY_SECRET_KEY KC_GRAFANA_CLIENT_SECRET; do
    out="$(env -u GRAFANA_ADMIN_USER -u GRAFANA_ADMIN_PASSWORD -u GF_SECURITY_SECRET_KEY \
      docker compose --env-file "$empty_env" config 2>&1 || true)"
    check "compose sem .env falha pedindo $var" grep -qF "defina $var no .env" <<<"$out"
  done
fi

# 5c. .env.example lista exatamente as variáveis que o generate-env.sh gera (sem valores).
example_vars="$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' .env.example | sort | tr '\n' ' ')"
expected_vars="$(printf '%s\n' GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GF_SECURITY_SECRET_KEY KC_GRAFANA_CLIENT_SECRET | sort | tr '\n' ' ')"
check ".env.example com os nomes das variáveis do generate-env.sh" test "$example_vars" = "$expected_vars"
check ".env.example sem valores" bash -c "! grep -qE '^[A-Z_]+=.+' .env.example"

# 6. opensearch-proxy (ADR-0004): allowlist de prefixos do guard.js == index pattern do datasource; datasource aponta para o proxy.
guard_prefixes="$(sed -n "s/^const PREFIXES = \[\(.*\)\];$/\1/p" opensearch-proxy/guard.js | tr -d " '")"
ds_prefixes="$(sed -n 's/^ *database: "\(.*\)"$/\1/p' provisioning/datasources/graylog-opensearch.yaml | sed 's/_\*//g')"
check "prefixos do guard.js do proxy iguais ao index pattern do datasource" test -n "$guard_prefixes" -a "$guard_prefixes" = "$ds_prefixes"
check "datasource graylog-opensearch aponta para o opensearch-proxy (nunca o OpenSearch direto)" \
  grep -qE '^ *url: http://opensearch-ro:8080$' provisioning/datasources/graylog-opensearch.yaml
grafana_block="$(sed -n '/^  grafana:/,/^  opensearch-proxy:/p' docker-compose.yml)"
# Bloco vazio (extração falhou) NÃO pode passar em falso; e a rede logs-read não aparece em nenhuma linha do serviço.
no_logs_read() { [[ -n "$1" ]] && grep -q "^  grafana:" <<<"$1" && ! { grep -v "^ *#" <<<"$1" | grep -q "logs-read"; }; }
check "Grafana fora da rede logs-read no compose" no_logs_read "$grafana_block"

# 7. Testes unitários do guard.js (node:test; Node local ou, sem ele, a imagem do Playwright via Docker).
if command -v node >/dev/null 2>&1; then
  check "testes unitários do guard.js (node local)" bash -c "NODE_LOCAL=1 ./scripts/test-guard.sh >/dev/null"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  check "testes unitários do guard.js (docker)" bash -c "./scripts/test-guard.sh >/dev/null"
else
  echo "AVISO testes do guard.js não rodaram (sem Node nem Docker)."
fi

if [[ $fail -ne 0 ]]; then echo "lint-repo: REPROVADO"; exit 1; fi
echo "lint-repo: APROVADO"
