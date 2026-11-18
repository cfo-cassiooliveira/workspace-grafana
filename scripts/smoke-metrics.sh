#!/usr/bin/env bash
# Smoke test do Prometheus + blackbox (T20/T22, ADR-0003).
# Pré-requisito: cadastro e legado de pé. Sobe a stack de métricas (se necessário), valida config (promtool),
# saúde, hardening, alvos e, numa instância DESCARTÁVEL do Prometheus (nada vaza para as séries/regras reais), o ciclo
# probe_success 1 -> 0 -> 1 e o diagnóstico de falha de DNS x API fora (as APIs reais não são paradas).
# Uso (na raiz do projeto): ./scripts/smoke-metrics.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f prometheus/docker-compose.metrics.yml)
PROM_DIR="$(pwd -W 2>/dev/null || pwd)/prometheus"
FIXTURE="smoke-metrics-fixture"
FIXTURE_REFUSED="smoke-metrics-refused"
SMOKE_PROM="smoke-metrics-prometheus"
smoke_targets_dir=""
query_container=""
failures=0

check() {
  local description="$1" ok="$2"
  if [[ "$ok" == "true" ]]; then echo "OK   ${description}"; else echo "FALHA ${description}"; failures=$((failures + 1)); fi
}
eq_if() { if [[ "$1" == "$2" ]]; then echo true; else echo false; fi; }
ok_if() { if "$@" >/dev/null 2>&1; then echo true; else echo false; fi; }

cleanup() {
  docker rm -f "$FIXTURE" "$FIXTURE_REFUSED" "$SMOKE_PROM" >/dev/null 2>&1 || true
  [[ -z "$smoke_targets_dir" ]] || rm -rf "$smoke_targets_dir"
}
trap cleanup EXIT

# Imagem declarada no compose (tag@digest) cujo nome contém o texto de $1.
compose_image() { "${COMPOSE[@]}" config --images | grep -F "$1"; }
prom_image="$(compose_image prom/prometheus)"
bb_image="$(compose_image prom/blackbox-exporter)"

# 1. Imagens por tag + digest e licença Apache-2.0.
check "prometheus fixado por tag+digest" "$(ok_if grep -qE '^prom/prometheus:v[0-9.]+@sha256:[0-9a-f]{64}$' <<<"$prom_image")"
check "blackbox fixado por tag+digest" "$(ok_if grep -qE '^prom/blackbox-exporter:v[0-9.]+@sha256:[0-9a-f]{64}$' <<<"$bb_image")"
license="$(docker image inspect "$prom_image" -f '{{index .Config.Labels "org.opencontainers.image.licenses"}}' 2>/dev/null || true)"
check "licença do Prometheus Apache-2.0" "$(eq_if "$license" 'Apache License 2.0')"

# 2. Validação estática da configuração (promtool e --config.check, via imagem).
run_promtool() {
  docker run --rm --entrypoint promtool \
    -v "$PROM_DIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$PROM_DIR/rules.yml:/etc/prometheus/rules.yml:ro" \
    -v "$PROM_DIR/targets:/etc/prometheus/targets:ro" "$prom_image" "$@"
}
check "promtool check config" "$(ok_if run_promtool check config /etc/prometheus/prometheus.yml)"
check "promtool check rules" "$(ok_if run_promtool check rules /etc/prometheus/rules.yml)"
check "blackbox --config.check" "$(ok_if docker run --rm -v "$PROM_DIR/blackbox.yml:/config/blackbox.yml:ro" "$bb_image" --config.file=/config/blackbox.yml --config.check)"

# 3. Stack de pé e saudável (até ~2 min).
"${COMPOSE[@]}" up -d >/dev/null
prom="$("${COMPOSE[@]}" ps -q prometheus)"
bb="$("${COMPOSE[@]}" ps -q blackbox)"
for c in "$prom" "$bb"; do
  health=starting
  for _ in $(seq 1 40); do
    health="$(docker inspect -f '{{.State.Health.Status}}' "$c")"
    [[ "$health" == healthy ]] && break
    sleep 3
  done
  check "container $(docker inspect -f '{{.Name}}' "$c") healthy" "$(eq_if "$health" healthy)"
done

# Consulta ao Prometheus por dentro do container (não há porta publicada).
prom_get() { docker exec "${query_container:-$prom}" wget -qO- "http://127.0.0.1:9090$1" 2>/dev/null || true; }
encode() { sed -e 's/%/%25/g' -e 's/{/%7B/g' -e 's/}/%7D/g' -e 's/"/%22/g' -e 's/ /%20/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g' <<<"$1"; }
# Valor da primeira série devolvida por uma consulta instantânea (vazio se não houver).
prom_value() { prom_get "/api/v1/query?query=$(encode "$1")" | sed -n 's/.*"value":\[[0-9.]*,"\([^"]*\)"\].*/\1/p' | head -1; }
# Espera (até ~100 s) a consulta devolver o valor esperado; imprime o último valor lido.
wait_value() {
  local query="$1" expected="$2" got=""
  for _ in $(seq 1 25); do
    got="$(prom_value "$query")"
    [[ "$got" == "$expected" ]] && { echo "$got"; return; }
    sleep 4
  done
  echo "$got"
}
# Espera a consulta devolver qualquer valor.
wait_any() {
  local query="$1" got=""
  for _ in $(seq 1 25); do
    got="$(prom_value "$query")"
    [[ -n "$got" ]] && { echo "$got"; return; }
    sleep 4
  done
  echo "$got"
}

# 4. Hardening: sem porta no host, usuário não-root, sem lifecycle/admin API, retenção 30d, FS somente leitura.
check "Prometheus sem porta publicada" "$(eq_if "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$prom")" '{}')"
check "blackbox sem porta publicada" "$(eq_if "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$bb")" '{}')"
host_open=false
for port in 9090 9115; do
  if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${port}/-/healthy"; then host_open=true; fi
done
check "9090/9115 inacessíveis no host" "$(eq_if "$host_open" false)"
check "Prometheus roda como nobody (65534)" "$(eq_if "$(docker exec "$prom" id -u)" 65534)"
check "blackbox roda como nobody (65534)" "$(eq_if "$(docker exec "$bb" id -u)" 65534)"
check "rootfs somente leitura nos dois" "$(eq_if "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$prom" "$bb" | tr '\n' ' ')" 'true true ')"
flags="$(prom_get /api/v1/status/flags)"
check "retenção de 30 dias" "$(ok_if grep -q '"storage.tsdb.retention.time":"30d"' <<<"$flags")"
check "lifecycle desligado" "$(ok_if grep -q '"web.enable-lifecycle":"false"' <<<"$flags")"
check "admin API desligada" "$(ok_if grep -q '"web.enable-admin-api":"false"' <<<"$flags")"
reload_code="$(docker exec "$prom" wget -S -qO- --post-data= http://127.0.0.1:9090/-/reload 2>&1 | sed -n 's/.*HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | head -1)" || true
check "POST /-/reload recusado (403)" "$(eq_if "$reload_code" 403)"
# O Prometheus não alcança as APIs (só o blackbox alcança): sem rota/DNS para os containers delas.
prom_reaches_api=false
if docker exec "$prom" wget -q -T 3 -O /dev/null http://cadastro-api:8080/health/live 2>/dev/null; then prom_reaches_api=true; fi
check "Prometheus sem rota para a API (isolamento)" "$(eq_if "$prom_reaches_api" false)"
check "blackbox alcança a API (cadastro live)" "$(ok_if docker exec "$bb" wget -q -T 3 -O /dev/null http://cadastro-api:8080/health/live)"

# 5. Alvos e probe_success das APIs reais.
check "alvo prometheus up" "$(eq_if "$(wait_value 'up{job="prometheus"}' 1)" 1)"
check "alvo blackbox up" "$(eq_if "$(wait_value 'up{job="blackbox"}' 1)" 1)"
for project in cadastro legado; do
  check "alvo api-health ${project}/live up" "$(eq_if "$(wait_value "up{job=\"api-health\",project=\"${project}\",endpoint=\"live\"}" 1)" 1)"
  check "probe_success ${project}/live = 1" "$(eq_if "$(wait_value "probe_success{project=\"${project}\",endpoint=\"live\"}" 1)" 1)"
  # readiness reflete dependências (503 => 0): o valor deve ser coerente com o status HTTP observado.
  status="$(wait_any "probe_http_status_code{project=\"${project}\",endpoint=\"ready\"}")"
  success="$(prom_value "probe_success{project=\"${project}\",endpoint=\"ready\"}")"
  expected=0
  if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then expected=1; fi
  check "probe_success ${project}/ready coerente com HTTP ${status:-?} (= ${expected})" "$(eq_if "$success" "$expected")"
done

# 6. Regra de gravação de disponibilidade (avaliada a cada 1 min).
rule_value="$(wait_any 'project_endpoint:probe_success:avg_over_time5m{project="cadastro",endpoint="live"}')"
check "regra project_endpoint:probe_success:avg_over_time5m gravada" "$(if [[ -n "$rule_value" ]]; then echo true; else echo false; fi)"

# Contagem de séries de project="smoke" no Prometheus REAL antes do teste (execuções antigas do smoke, que injetavam o alvo
# falso nele, deixaram resíduo nas regras 24h/7d/30d; o Prometheus real não permite apagar: admin API desligada). O teste
# prova que esta execução NÃO acrescenta nada.
smoke_before_probe="$(prom_value 'count(probe_success{project="smoke"})')"
smoke_before_rule="$(prom_value 'count({__name__=~"project_endpoint:probe_success:.*",project="smoke"})')"
# 7. Ciclo 1 -> 0 -> 1 e diagnóstico de DNS com alvos falsos numa instância DESCARTÁVEL do Prometheus (mesmo prometheus.yml e
# rules.yml da stack, só com um diretório de alvos temporário e retenção de 1 h). Assim as séries e as regras de
# disponibilidade (24h/7d/30d) do Prometheus real nunca recebem project="smoke". As APIs reais não são paradas.
smoke_targets_dir="$(mktemp -d)"
smoke_targets_win="$(cygpath -m "$smoke_targets_dir" 2>/dev/null || echo "$smoke_targets_dir")"
cat > "${smoke_targets_dir}/fixture.yml" <<'YAML'
# Gerado pelo smoke-metrics.sh (diretório temporário, removido ao final).
# up: servidor HTTP que o teste para e religa. refused: container no ar SEM servidor (DNS resolve, conexão recusada).
# dns: nome que não resolve.
- targets: ["http://smoke-fixture:8080/health/live"]
  labels: {project: smoke, endpoint: live}
- targets: ["http://smoke-refused:8080/health/live"]
  labels: {project: smoke, endpoint: refused}
- targets: ["http://smoke-no-such-host.invalid:8080/health/live"]
  labels: {project: smoke, endpoint: dns}
YAML
chmod 755 "$smoke_targets_dir"; chmod 644 "${smoke_targets_dir}/fixture.yml"
docker rm -f "$FIXTURE" "$FIXTURE_REFUSED" "$SMOKE_PROM" >/dev/null 2>&1 || true
docker run -d --name "$FIXTURE" --network metrics-probe --network-alias smoke-fixture --user 65534:65534 --entrypoint sh \
  "$prom_image" -c 'mkdir -p /tmp/www/health && echo ok > /tmp/www/health/live && exec httpd -f -p 8080 -h /tmp/www' >/dev/null
docker run -d --name "$FIXTURE_REFUSED" --network metrics-probe --network-alias smoke-refused --user 65534:65534 --entrypoint sh \
  "$prom_image" -c 'exec sleep 600' >/dev/null
docker run -d --name "$SMOKE_PROM" --network metrics-probe --user 65534:65534 --read-only --tmpfs /prometheus:uid=65534 \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$PROM_DIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$PROM_DIR/rules.yml:/etc/prometheus/rules.yml:ro" \
  -v "${smoke_targets_win}:/etc/prometheus/targets:ro" "$prom_image" \
  --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=1h >/dev/null
query_container="$SMOKE_PROM"   # a partir daqui as consultas vão à instância descartável

smoke_query='probe_success{project="smoke",endpoint="live"}'
check "alvo falso no ar: probe_success = 1" "$(eq_if "$(wait_value "$smoke_query" 1)" 1)"
docker stop "$FIXTURE" >/dev/null
check "alvo falso parado: probe_success = 0" "$(eq_if "$(wait_value "$smoke_query" 0)" 0)"
docker start "$FIXTURE" >/dev/null
check "alvo falso de volta: probe_success = 1" "$(eq_if "$(wait_value "$smoke_query" 1)" 1)"

# Diagnóstico de DNS (ADR-0003, T17): probe_success = 0 tanto com a API fora quanto com o nome não resolvendo (container
# renomeado, projeto Compose/escala diferente). O alerta deve distinguir pelo IP resolvido: o blackbox zera
# probe_ip_addr_hash quando o DNS não resolve (valor medido: 0; resolvido = hash > 0); probe_dns_lookup_time_seconds acompanha a resolução.
refused_ok="$(wait_value 'probe_success{project="smoke",endpoint="refused"}' 0)"
dns_ok="$(wait_value 'probe_success{project="smoke",endpoint="dns"}' 0)"
check "API fora com DNS ok (conexão recusada): probe_success = 0" "$(eq_if "$refused_ok" 0)"
check "nome que não resolve: probe_success = 0" "$(eq_if "$dns_ok" 0)"
check "API fora com DNS ok: IP resolvido (probe_ip_addr_hash > 0)" \
  "$([[ -n "$(wait_any 'probe_ip_addr_hash{project="smoke",endpoint="refused"} > 0')" ]] && echo true || echo false)"
check "falha de DNS: IP zerado (probe_ip_addr_hash = 0), distinguível da API fora" \
  "$(eq_if "$(wait_value 'probe_ip_addr_hash{project="smoke",endpoint="dns"}' 0)" 0)"
check "alerta expressável: probe_success 0 com hash 0 = só o alvo dns; com hash > 0 = só o alvo refused" \
  "$([[ "$(prom_value 'count(probe_success{project="smoke"} == 0 and on(instance) probe_ip_addr_hash{project="smoke"} == 0)')" == 1 \
    && "$(prom_value 'count(probe_success{project="smoke"} == 0 and on(instance) probe_ip_addr_hash{project="smoke"} > 0)')" == 1 ]] && echo true || echo false)"
check "probe_dns_lookup_time_seconds exposto" "$([[ -n "$(prom_value 'probe_dns_lookup_time_seconds{project="smoke",endpoint="live"}')" ]] && echo true || echo false)"

# Prometheus real: os alvos reais resolvem (hash > 0), então um probe_success = 0 deles seria API fora, não DNS; e esta
# execução não acrescentou nada do alvo falso a ele.
query_container=""
for project in cadastro legado; do
  check "alvo real ${project}/live resolve o alias de rede (probe_ip_addr_hash > 0)" \
    "$([[ -n "$(prom_value "probe_ip_addr_hash{project=\"${project}\",endpoint=\"live\"} > 0")" ]] && echo true || echo false)"
done
check "Prometheus real: nenhuma série nova de project=\"smoke\" (probe_success e regras de disponibilidade)" \
  "$([[ "$(prom_value 'count(probe_success{project="smoke"})')" == "$smoke_before_probe" \
    && "$(prom_value 'count({__name__=~"project_endpoint:probe_success:.*",project="smoke"})')" == "$smoke_before_rule" ]] && echo true || echo false)"

if [[ $failures -ne 0 ]]; then echo "smoke-metrics: REPROVADO ($failures falha(s))"; exit 1; fi
echo "smoke-metrics: APROVADO"
