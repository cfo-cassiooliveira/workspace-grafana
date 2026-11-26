#!/usr/bin/env bash
# Teste de comportamento das regras "DLQ com mensagens", "Fila com mensagens e sem consumidor" e "Retry parada"
# (ADR-0005): extrai a expressão e o "for" reais do rules.yaml e os avalia com "promtool test rules" sobre séries
# sintéticas com os nomes e rótulos (job, vhost, queue) que o scrape do broker expõe. O limiar "> 0" do Grafana não muda
# o resultado: as expressões só devolvem séries positivas.
# Uso: ./tests/dashboards/rabbitmq-alerts.test.sh   (promtool local ou a imagem do Prometheus do compose, via Docker)
set -euo pipefail

cd "$(dirname "$0")/../.."
RULES="provisioning/alerting/rules.yaml"
# Mesma imagem (tag + digest) que o compose de métricas usa.
PROM_IMAGE="$(sed -n 's/^ *image: *\(prom\/prometheus:[^ ]*\).*/\1/p' prometheus/docker-compose.metrics.yml)"
[[ -n "$PROM_IMAGE" ]] || { echo "FALHA imagem do Prometheus não encontrada no compose de métricas"; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# rule_value UID CHAVE: primeiro valor de "CHAVE:" depois da regra (para expr, sem as aspas simples do YAML).
rule_value() {
  awk -v uid="$1" -v key="$2" '
    $1 == "-" && $2 == "uid:" { inside = ($3 == uid) }
    inside && $1 == key ":" { sub(/^[^:]*: */, ""); sub(/\r$/, ""); print; exit }' "$RULES"
}
dlq_expr="$(rule_value rabbitmq-dlq-not-empty expr)"
dlq_for="$(rule_value rabbitmq-dlq-not-empty for)"
idle_expr="$(rule_value rabbitmq-queue-without-consumer expr)"
idle_for="$(rule_value rabbitmq-queue-without-consumer for)"
stuck_expr="$(rule_value rabbitmq-retry-stuck expr)"
stuck_for="$(rule_value rabbitmq-retry-stuck for)"
[[ -n "$dlq_expr" && -n "$dlq_for" && -n "$idle_expr" && -n "$idle_for" && -n "$stuck_expr" && -n "$stuck_for" ]] \
  || { echo "FALHA regras não extraídas de $RULES"; exit 1; }

cat > "$work/rules.yml" <<RULES_EOF
groups:
  - name: rabbitmq
    rules:
      - alert: DlqNotEmpty
        expr: ${dlq_expr}
        for: ${dlq_for}
      - alert: QueueWithoutConsumer
        expr: ${idle_expr}
        for: ${idle_for}
      - alert: RetryStuck
        expr: ${stuck_expr}
        for: ${stuck_for}
RULES_EOF

# Filas reais da importação (definitions.template.json do projeto rabbitmq, vhost dev).
cat > "$work/test.yml" <<'TEST_EOF'
rule_files: [rules.yml]
evaluation_interval: 1m
tests:
  # DLQ da importação com mensagens: dispara só depois dos 5 min, por (vhost, queue). Fila principal e retry não contam.
  - interval: 1m
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.dlq"}'
        values: '3x20'
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines"}'
        values: '50x20'
      - series: 'rabbitmq_queue_consumers{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines"}'
        values: '1x20'
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.retry"}'
        values: '40x20'
      - series: 'rabbitmq_queue_consumers{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.retry"}'
        values: '0x20'
      - series: 'rabbitmq_queue_consumers{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.dlq"}'
        values: '0x20'
    alert_rule_test:
      - eval_time: 4m
        alertname: DlqNotEmpty
        exp_alerts: []
      - eval_time: 6m
        alertname: DlqNotEmpty
        exp_alerts:
          - exp_labels: {vhost: dev, queue: cadastro.user-import-lines.dlq}
      # Retry e DLQ não têm consumidor por desenho: mesmo com mensagens por muito tempo, não são "sem consumidor".
      - eval_time: 20m
        alertname: QueueWithoutConsumer
        exp_alerts: []
  # DLQ vazia: silêncio.
  - interval: 1m
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.dlq"}'
        values: '0x20'
    alert_rule_test:
      - eval_time: 20m
        alertname: DlqNotEmpty
        exp_alerts: []
  # Fila principal sem consumidor: dispara; o consumidor da mesma fila em outro vhost não a esconde.
  - interval: 1m
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines"}'
        values: '7x20'
      - series: 'rabbitmq_queue_consumers{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines"}'
        values: '0x20'
      - series: 'rabbitmq_queue_consumers{job="rabbitmq",vhost="other",queue="cadastro.user-import-lines"}'
        values: '1x20'
    alert_rule_test:
      - eval_time: 9m
        alertname: QueueWithoutConsumer
        exp_alerts: []
      - eval_time: 11m
        alertname: QueueWithoutConsumer
        exp_alerts:
          - exp_labels: {job: rabbitmq, vhost: dev, queue: cadastro.user-import-lines}
  # Retry parada (TTL real da policy cadastro-retry: 30 s). Ciclo normal em falha prolongada: a fila nunca esvazia, mas
  # tudo o que está nela foi publicado há pouco. Fila principal cheia não conta.
  - interval: 15s
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.retry"}'
        values: '20x80'
      - series: 'rabbitmq_queue_exchange_messages_published_total{job="rabbitmq",vhost="dev",exchange="cadastro.retry",queue="cadastro.user-import-lines.retry"}'
        values: '20+10x80'
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines"}'
        values: '5000x80'
    alert_rule_test:
      - eval_time: 12m
        alertname: RetryStuck
        exp_alerts: []
      - eval_time: 20m
        alertname: RetryStuck
        exp_alerts: []
  # Rajada que escoa pelo TTL: sem publicações novas e fila vazia depois.
  - interval: 15s
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.retry"}'
        values: '0 50 50 0x80'
      - series: 'rabbitmq_queue_exchange_messages_published_total{job="rabbitmq",vhost="dev",exchange="cadastro.retry",queue="cadastro.user-import-lines.retry"}'
        values: '0 50x80'
    alert_rule_test:
      - eval_time: 12m
        alertname: RetryStuck
        exp_alerts: []
  # Parada sem entradas novas (policy ausente): dispara cerca de 10 min depois (janela de 5 min + for de 5 min).
  - interval: 15s
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.retry"}'
        values: '0 7x80'
      - series: 'rabbitmq_queue_exchange_messages_published_total{job="rabbitmq",vhost="dev",exchange="cadastro.retry",queue="cadastro.user-import-lines.retry"}'
        values: '0 7x80'
    alert_rule_test:
      - eval_time: 9m
        alertname: RetryStuck
        exp_alerts: []
      - eval_time: 12m
        alertname: RetryStuck
        exp_alerts:
          - exp_labels: {vhost: dev, queue: cadastro.user-import-lines.retry}
  # Parada com entradas contínuas (a fila só cresce).
  - interval: 15s
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.retry"}'
        values: '0+10x80'
      - series: 'rabbitmq_queue_exchange_messages_published_total{job="rabbitmq",vhost="dev",exchange="cadastro.retry",queue="cadastro.user-import-lines.retry"}'
        values: '0+10x80'
    alert_rule_test:
      - eval_time: 14m
        alertname: RetryStuck
        exp_alerts:
          - exp_labels: {vhost: dev, queue: cadastro.user-import-lines.retry}
  # Depois de reiniciar o broker o contador de publicações some, mas as mensagens (quorum) ficam: ainda alerta.
  - interval: 15s
    input_series:
      - series: 'rabbitmq_queue_messages_ready{job="rabbitmq",vhost="dev",queue="cadastro.user-import-lines.retry"}'
        values: '7x80'
    alert_rule_test:
      - eval_time: 6m
        alertname: RetryStuck
        exp_alerts:
          - exp_labels: {vhost: dev, queue: cadastro.user-import-lines.retry}
TEST_EOF

if command -v promtool >/dev/null 2>&1; then
  (cd "$work" && promtool test rules test.yml) && result=0 || result=1
else
  # O mktemp cria a pasta com 0700 e o container do Prometheus roda como nobody.
  chmod 755 "$work"
  chmod 644 "$work"/*.yml
  MSYS_NO_PATHCONV=1 docker run --rm --network none -v "$(cd "$work" && (pwd -W 2>/dev/null || pwd)):/t:ro" -w /t \
    --entrypoint promtool "$PROM_IMAGE" test rules test.yml && result=0 || result=1
fi

if [[ $result -eq 0 ]]; then echo "rabbitmq-alerts: APROVADO"; else echo "rabbitmq-alerts: REPROVADO"; exit 1; fi
