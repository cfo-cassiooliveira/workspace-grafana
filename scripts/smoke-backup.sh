#!/usr/bin/env bash
# Smoke test de backup e restauração (T09), só com o stack do Grafana (127.0.0.1:3000); sem Keycloak nem Graylog.
#   1) faz um backup de segurança do volume atual (mantido em .backups/) e sobe o Grafana;
#   2) cria um usuário e uma preferência de teste pela API (break-glass; senhas fora do argv, por -K e stdin);
#   3) backup.sh: arquivo 0600 (no NTFS só aviso), íntegro e com grafana.db;
#   4) restore.sh recusa sem --yes e recusa arquivo inválido, sem tocar no volume;
#   5) restore.sh recusa tar com symlink/hardlink e, numa falha de extração no meio, não toca o volume, mantém o usuário,
#      reinicia o Grafana e deixa o backup de segurança;
#   6) `docker compose down -v` (só o projeto "grafana", volume grafana_grafana-data), restore.sh --yes, sobe e confere
#      que usuário e preferência voltaram; ao final remove o usuário de teste e restaura a preferência.
# Dados 100% sintéticos. Se a rede externa logs-read não existir, é criada aqui e removida ao final.
# O container é recriado várias vezes: se já estava de pé com o override GELF (docker-compose.graylog.yml, driver gelf), é
# recriado com ele (e volta a ficar de pé ao final); se estava parado, termina parado (`docker compose down`).
# Os backups criados na rodada são apagados ao final, exceto o de segurança do estado inicial (1º passo), que fica em .backups/.
# Uso (na raiz do projeto): ./scripts/smoke-backup.sh
set -euo pipefail
exec < /dev/null

export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

BASE_URL="${GRAFANA_URL:-http://localhost:3000}"
VOLUME="grafana_grafana-data"
failures=0
work_dir="$(mktemp -d)"
created_network=false
COMPOSE=(docker compose)
was_up=false

check() {
  local description="$1" ok="$2"
  if [[ "$ok" == "true" ]]; then echo "OK   ${description}"; else echo "FALHA ${description}"; failures=$((failures + 1)); fi
}
contains() { if grep -qF -- "$2" <<< "$1"; then echo true; else echo false; fi; }

[[ -f .env ]] || { echo "Falta o .env (rode ./scripts/generate-env.sh)." >&2; exit 2; }
set -a
# shellcheck disable=SC1091
source .env
set +a

cleanup() {
  # Remove os backups da rodada (o de segurança do estado inicial, listado em keep_list, permanece).
  if [[ -n "${keep_list:-}" ]]; then
    for f in .backups/grafana-data-*.tar.gz; do
      [[ -e "$f" ]] || continue
      grep -qxF -- "$f" "$keep_list" || rm -f -- "$f"
    done
  fi
  rm -rf "$work_dir"
  if [[ "$created_network" == "true" ]]; then docker network rm logs-read > /dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# curl nativo no Windows precisa da conversão de caminhos do Git Bash (desligada acima só para o docker): ver api().
# Credencial do break-glass em arquivo -K (0600), nunca no argv.
(umask 077; printf 'user = "%s:%s"\n' "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD" > "${work_dir}/admin.curlrc")
api() { # api METODO CAMINHO [corpo-json]; o corpo vai por arquivo 0600, nunca pelo argv
  local method="$1" path="$2" data=()
  if [[ -n "${3:-}" ]]; then
    (umask 077; printf "%s" "$3" > "${work_dir}/body.json")
    data=(--data-binary "@${work_dir}/body.json")
  fi
  env -u MSYS_NO_PATHCONV curl -s --max-time 15 -K "${work_dir}/admin.curlrc" -X "$method" -H "Content-Type: application/json" "${data[@]}" "${BASE_URL}${path}"
}
wait_healthy() {
  local health="starting"
  for _ in $(seq 1 40); do
    health="$(docker inspect -f '{{.State.Health.Status}}' grafana-grafana-1 2> /dev/null || echo none)"
    [[ "$health" == "healthy" ]] && return 0
    sleep 3
  done
  return 1
}

# A rede logs-read normalmente vem do graylog; sem ele, cria à mão e remove no fim.
if ! docker network inspect logs-read > /dev/null 2>&1; then docker network create logs-read > /dev/null; created_network=true; fi

# Estado inicial: Grafana de pé? Com o driver GELF (override do Graylog)? Recria do mesmo jeito.
if [[ "$(docker inspect -f '{{.State.Running}}' grafana-grafana-1 2> /dev/null)" == "true" ]]; then
  was_up=true
  if [[ "$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' grafana-grafana-1)" == "gelf" ]]; then
    COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.graylog.yml)
    echo "INFO Grafana estava com o override GELF: será recriado com ele."
  fi
fi

# 1. Backup de segurança do estado atual (se houver) e subida do Grafana.
if docker volume inspect "$VOLUME" > /dev/null 2>&1; then
  ./scripts/backup.sh > /dev/null
  echo "INFO backup de segurança do volume atual mantido em .backups/"
  sleep 1
fi
# Lista (nome por linha) dos backups que existem antes da rodada: o cleanup apaga só os criados depois.
keep_list="${work_dir}/keep-backups.txt"
ls .backups/grafana-data-*.tar.gz > "$keep_list" 2> /dev/null || : > "$keep_list"

"${COMPOSE[@]}" up -d > /dev/null
check "Grafana saudável antes do teste" "$(wait_healthy && echo true || echo false)"

# 2. Estado de teste: usuário e preferência da organização.
test_login="smoke-backup-$(date +%s)"
test_password="$(openssl rand -hex 16)Aa1"
payload="$(printf '{"name":"Smoke Backup","email":"%s@invalid.test","login":"%s","password":"%s"}' "$test_login" "$test_login" "$test_password")"
body="$(api POST /api/admin/users "$payload")"
check "usuário de teste criado" "$(contains "$body" '"message":"User created"')"
api PUT /api/org/preferences '{"weekStart":"saturday","timezone":"utc"}' > /dev/null
check "preferência de teste gravada (weekStart=saturday)" "$(contains "$(api GET /api/org/preferences)" '"weekStart":"saturday"')"

# 3. Backup: arquivo 0600, íntegro e com grafana.db.
sleep 1
old=".backups/grafana-data-19700101T000000Z.tar.gz"; : > "$old"; touch -d "40 days ago" "$old"
./scripts/backup.sh > "${work_dir}/backup.out"
wait_healthy || true
backups=(.backups/grafana-data-*.tar.gz)   # nomes com data UTC: o último na ordem léxica é o mais recente
archive="${backups[-1]}"
check "backup.sh gerou o arquivo" "$([[ -f "$archive" ]] && echo true || echo false)"
check "arquivo íntegro e com grafana.db" "$(gzip -t "$archive" 2> /dev/null && tar tzf "$archive" | grep -qE '^(\./)?grafana\.db$' && echo true || echo false)"
mode="$(stat -c '%a' "$archive")"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) echo "AVISO permissão 0600 não é aplicável no NTFS (modo visto: ${mode}); verifique em Linux/WSL." ;;
  *) check "backup com permissão 0600" "$([[ "$mode" == "600" ]] && echo true || echo false)" ;;
esac
check "saída do backup sem segredos" "$([[ "$(contains "$(cat "${work_dir}/backup.out")" "$GRAFANA_ADMIN_PASSWORD")" == "false" ]] && echo true || echo false)"
check "rotação: backup com 40 dias apagado e o recente mantido" "$([[ ! -e "$old" && -f "$archive" ]] && echo true || echo false)"

# 4. Restore recusa sem --yes e com arquivo inválido; o volume continua intacto.
if ./scripts/restore.sh "$archive" > /dev/null 2>&1; then refused=false; else refused=true; fi
check "restore sem --yes é recusado" "$refused"
printf 'not-a-backup' > "${work_dir}/invalid.tar.gz"
if ./scripts/restore.sh --yes "${work_dir}/invalid.tar.gz" > /dev/null 2>&1; then refused=false; else refused=true; fi
check "restore --yes com arquivo inválido é recusado" "$refused"
check "usuário ainda existe após as recusas" "$(contains "$(api GET "/api/users/lookup?loginOrEmail=${test_login}")" "\"login\":\"${test_login}\"")"

# 4.1 Arquivos perigosos: symlink e hardlink são recusados na validação (volume intocado). O tar é montado dentro de um
# contêiner descartável (ln -s não é confiável no Git Bash/NTFS).
make_tar() { # make_tar ARQUIVO 'comandos sh que criam a árvore em /t'
  docker run --rm --network none "$HELPER_IMAGE" sh -c "mkdir /t && cd /t && echo x > grafana.db && $2 && tar czf - ." > "$1"
}
HELPER_IMAGE="alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"   # mesmo helper do restore.sh
make_tar "${work_dir}/symlink.tar.gz" 'ln -s /etc/passwd link'
if ./scripts/restore.sh --yes "${work_dir}/symlink.tar.gz" > /dev/null 2>&1; then refused=false; else refused=true; fi
check "restore --yes com tar contendo symlink é recusado" "$refused"
make_tar "${work_dir}/hardlink.tar.gz" 'ln grafana.db hard'
if ./scripts/restore.sh --yes "${work_dir}/hardlink.tar.gz" > /dev/null 2>&1; then refused=false; else refused=true; fi
check "restore --yes com tar contendo hardlink é recusado" "$refused"

# 4.2 Falha no meio da extração (passa na validação, mas "x" é arquivo e "x/y" exige diretório): o volume não pode ficar
# vazio/parcial, o usuário continua lá, o Grafana volta a rodar e o backup de segurança existe.
mkdir -p "${work_dir}/broken" && : > "${work_dir}/broken/grafana.db" && : > "${work_dir}/broken/x" && : > "${work_dir}/broken/xy"
tar czf "${work_dir}/broken.tar.gz" -C "${work_dir}/broken" --transform='s,^xy$,x/y,' grafana.db x xy
backups_before="$(find .backups -maxdepth 1 -name "grafana-data-*.tar.gz" | wc -l)"
if ./scripts/restore.sh --yes "${work_dir}/broken.tar.gz" > "${work_dir}/broken.out" 2>&1; then refused=false; else refused=true; fi
check "restore com falha na extração sai com erro" "$refused"
check "falha no meio: backup de segurança do estado atual foi criado antes" "$([[ "$(find .backups -maxdepth 1 -name "grafana-data-*.tar.gz" | wc -l)" -gt "$backups_before" ]] && echo true || echo false)"
check "falha no meio: Grafana reiniciado e saudável" "$(wait_healthy && echo true || echo false)"
check "falha no meio: volume não ficou vazio (usuário de teste e preferência intactos)" \
  "$([[ "$(contains "$(api GET "/api/users/lookup?loginOrEmail=${test_login}")" "\"login\":\"${test_login}\"")" == true && "$(contains "$(api GET /api/org/preferences)" '"weekStart":"saturday"')" == true ]] && echo true || echo false)"

# 5. down -v só do projeto grafana; confirma o volume antes de apagar.
volume_project="$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$VOLUME")"
check "volume a apagar é do projeto compose grafana (${VOLUME})" "$([[ "$volume_project" == "grafana" ]] && echo true || echo false)"
[[ "$volume_project" == "grafana" ]] || { echo "Abortando antes do down -v." >&2; exit 1; }
docker compose down -v > /dev/null
check "volume removido pelo down -v" "$(docker volume inspect "$VOLUME" > /dev/null 2>&1 && echo false || echo true)"

./scripts/restore.sh --yes "$archive" > /dev/null
check "restore --yes concluído" "$(docker volume inspect "$VOLUME" > /dev/null 2>&1 && echo true || echo false)"
"${COMPOSE[@]}" up -d > /dev/null
check "Grafana saudável após o restore" "$(wait_healthy && echo true || echo false)"
check "usuário de teste restaurado" "$(contains "$(api GET "/api/users/lookup?loginOrEmail=${test_login}")" "\"login\":\"${test_login}\"")"
check "preferência restaurada (weekStart=saturday)" "$(contains "$(api GET /api/org/preferences)" '"weekStart":"saturday"')"

# Limpeza do estado de teste (dados sintéticos).
test_id="$(api GET "/api/users/lookup?loginOrEmail=${test_login}" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
[[ -z "$test_id" ]] || api DELETE "/api/admin/users/${test_id}" > /dev/null
api PUT /api/org/preferences '{"weekStart":"","timezone":""}' > /dev/null
if [[ "$was_up" == "true" ]]; then "${COMPOSE[@]}" up -d > /dev/null; else docker compose down > /dev/null; fi

echo
if [[ "$failures" -eq 0 ]]; then echo "Todos os testes passaram."; else echo "${failures} teste(s) falharam."; exit 1; fi
