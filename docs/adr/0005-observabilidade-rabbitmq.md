# ADR-0005: Observabilidade do RabbitMQ no Grafana (scrape, dashboards oficiais e alertas)

- **Status**: Proposto (item 1 aprovado pelo responsável técnico; aceite do ADR pendente)
- **Data**: 2026-11-24
- **Decisores**: responsável técnico
- **Artigos da Constituição relacionados**: Art. III.4, IV.7, VI.1, VI.4, VII.4

## Contexto

O projeto `rabbitmq` expõe métricas Prometheus do broker (`rabbitmq:15692/metrics`, com séries por fila) e do coletor de logs
Fluent Bit (`log-shipper:2020/api/v2/metrics/prometheus`) pela rede interna `rabbitmq-metrics`, e entregou os insumos em
`rabbitmq/docs/integration/grafana-inputs.md`. O Grafana precisa de dashboards e alertas desses dois alvos, como código.

## Decisão

1. **Scrape**: jobs `rabbitmq` e `rabbitmq-log-shipper` em `prometheus/prometheus.yml` (rótulo `project: rabbitmq`). `/metrics`
   já traz as séries por fila (`return_per_object_metrics = true` no broker), então `/metrics/per-object` não é usado.
2. **Rede**: a `rabbitmq-metrics` (externa, `internal: true`) entra só no Prometheus, por um **override opcional**
   (`prometheus/docker-compose.rabbitmq.yml`), igual ao `docker-compose.graylog.yml`: rede externa ausente derruba o `up`
   inteiro, e o stack de métricas precisa subir com o broker fora. Sem porta nova no host; o Grafana continua sem alcançar o broker.
3. **Dashboards oficiais** do grafana.com por **revisão fixada e SHA-256 conferido** (`scripts/import-rabbitmq-dashboards.sh`):
   10991 rev 15 (Visão geral) e 11350 rev 8 (Alocadores de memória). Ajustes: datasource fixo `prometheus`, sem variável de
   datasource, uid/título no padrão do projeto, `editable: false`. Mais um dashboard próprio do coletor de logs (`rabbitmq-log-shipper`).
4. **Erlang-Distribution (11352 rev 10) não é incluído**: ele mostra tráfego e filas de distribuição entre nós Erlang
   (`erlang_vm_dist_*`); no broker de nó único essas séries não existem e todos os painéis ficariam vazios. Reavaliar se o broker virar cluster.
5. **12 regras de alerta** na pasta `rabbitmq` (`provisioning/alerting/rules.yaml`), com `project=rabbitmq` e `severity`.
   `noDataState: Alerting` só para "broker fora" e "coletor fora" (ausência de série é o sintoma); `OK` nas demais.

### Limiares (dev, nó único, `mem_limit` 1 GiB, watermark de memória 600 MiB)

| Alerta | Limiar / for | Justificativa |
|---|---|---|
| Fila crescendo | > 100 prontas e `deriv[15m] > 0`, 15m | Ignora picos pequenos; exige tendência sustentada. DLQ excluída (tem regra própria) |
| Sem consumidor | prontas > 0 e consumidores == 0, 10m | Tolera reinício de consumidor |
| DLQ não vazia | `*.dlq` > 0, 5m | Qualquer mensagem em DLQ exige olhar humano |
| Memória alta | > 80% do limite exposto, 5m | Antecipa o alarme (que bloqueia publicadores) |
| Alarmes de memória/disco | `== 1`, 0s, critical | Publicadores já estão bloqueados |
| Disco perto do limite | livre < 2x o limite, 10m | Margem para agir antes do alarme |
| Broker fora | `up == 0` ou série ausente, 2m, critical | Sem métricas não há como alertar o resto |
| Coletor fora / backlog / falha de envio / descarte | 5m / chunks > 0 por 10m / erros ou retries esgotados 15m / dropped > 0 (critical) | Backlog > 0 é normal por instantes; descarte é a única perda de logs |

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Rede `rabbitmq-metrics` no compose principal de métricas | Rede externa ausente quebraria o stack inteiro com o broker fora |
| Grafana na `rabbitmq-metrics` (consulta direta) | Amplia a superfície; o Grafana só lê o Prometheus |
| JSON dos dashboards sem pinagem | Revisão pode mudar no grafana.com; o SHA-256 garante reprodutibilidade |

## Consequências

- Subir o stack de métricas **sem** o override recria o Prometheus fora da rede: os alvos ficam `up == 0` e "Broker fora do ar" dispara (esperado).
- Pré-requisito: broker de pé (cria a rede). Subir revisão de dashboard exige trocar revisão e SHA-256 no script.
- Alertas sem notificação externa (contact point `ui-only`, como no restante do projeto).
