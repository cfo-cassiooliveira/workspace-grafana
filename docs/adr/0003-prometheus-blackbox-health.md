# ADR-0003: Prometheus + blackbox exporter para health check das APIs

- **Status**: Aceito (aceito pelo responsável técnico em 2026-11-17)
- **Data**: 2026-11-17
- **Decisores**: responsável técnico (aprovou em 2026-11-17: Prometheus + blackbox; Infinity descartado; ADR aceito em 2026-11-17, incluindo o alias de rede `cadastro-api`/`legado-api` nos composes das APIs)
- **Artigos da Constituição relacionados**: Art. III.4, IV.4, IV.7, V.1, VI.4, VII.1

## Contexto

O ADR-0001 fixou a v1 do Grafana "sem componente novo" (só OpenSearch do Graylog). O usuário pediu depois visibilidade do
health das APIs (`/health/live` e `/health/ready`, Art. VI.4) com histórico de disponibilidade e alerta (tarefa T17). Os
logs do Graylog não respondem "a API está no ar agora?" e não guardam série de disponibilidade. Os endpoints existem em
`cadastro` e `legado` (anônimos, porta 8080, só na rede Docker interna); `WebAPI` não expõe `/health/*` e não tem compose.

## Decisão

1. **Prometheus + blackbox exporter** em projeto compose próprio (`prometheus/docker-compose.metrics.yml`, projeto
   `grafana-metrics`), imagens oficiais `prom/prometheus` v3.16.0 e `prom/blackbox-exporter` v0.29.1 (ambas Apache-2.0) por
   **tag + digest**. Retenção de 30 dias, volume próprio, sem porta publicada no host.
2. **Alvos por arquivo versionado** (`prometheus/targets/*.yml`, file_sd) com rótulos `project` e `endpoint`; módulo
   `http_2xx` com timeout de 5 s (readiness 503 = falha). Regras de gravação de disponibilidade (5m, 24h, 7d, 30d) em
   `prometheus/rules.yml`.
3. **Isolamento de rede** (mais estrito que "Prometheus nas redes das APIs"): só o **blackbox** entra em
   `cadastro_default` e `legado_default`; o Prometheus fala com ele pela rede interna `metrics-probe`. A rede `metrics`
   (interna, nome fixo) liga Prometheus e Grafana (T17); o Grafana não alcança o blackbox nem as APIs. Evita-se a
   `workspace-identity` (compartilhada com o Keycloak).
4. **Hardening**: usuário `nobody` (65534), rootfs somente leitura, `cap_drop: ALL`, `no-new-privileges`, limites de memória,
   `--web.enable-lifecycle` e `--web.enable-admin-api` desligados (mudança de `prometheus.yml`/`rules.yml` exige restart).
5. Fora de escopo: scrape de Keycloak/SonarQube (T21, só com novo OK), alertmanager, instrumentar os apps.

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Infinity (datasource JSON no Grafana) | Sem componente novo | Sem histórico/uptime (consulta ao vivo); Grafana teria de alcançar as redes das APIs | Rejeitada pelo usuário |
| Sem histórico (só status atual) | Mais simples | Não responde disponibilidade 24h/7d/30d nem alerta por janela | Não atende T17 |
| Prometheus nas redes das APIs (scrape direto) | Um componente a menos | APIs não expõem `/metrics`; o Prometheus ficaria exposto às APIs e ao Keycloak | Blackbox isola o acesso |
| Uptime Kuma / outro monitor | UI pronta | Segundo sistema de UI e alertas fora do Grafana | YAGNI; Grafana já é o destino |

## Consequências

- **Positivas**: histórico de disponibilidade e base para alertas; padrão de mercado; Grafana lê só o Prometheus.
- **Negativas / riscos**: dois containers novos (~100 MB de RAM); os alvos usam os aliases de rede únicos `cadastro-api`/`legado-api`
  (o alias `api` é ambíguo entre as duas redes; os aliases foram adicionados aos composes de `cadastro` e `legado` em 2026-11-17) e
  a stack exige cadastro e legado de pé (redes externas).
- **Ações decorrentes**: ADR-0001 anotado (não é mais "sem componente novo"); T17 liga o Grafana à rede `metrics` e cria o
  datasource/dashboard/alerta; ao adicionar API nova, acrescentar o alvo em `targets/` e rodar `scripts/smoke-metrics.sh`.

## Riscos conhecidos e decisões conscientes (2026-11-17, rodada de correção da Onda 2)

- **Alvos por nome de container (RESOLVIDO em 2026-11-17)**: os alvos usavam `cadastro-api-1`/`legado-api-1`, que mudam se o projeto Compose, a
  escala ou o `-p` mudarem (o nome deixava de resolver e `probe_success` virava 0, igual a "API fora do ar"). Os composes de `cadastro` e `legado`
  agora dão à API o alias de rede único `cadastro-api`/`legado-api` na rede default de cada projeto, e os alvos o usam. Mitigação residual de
  diagnóstico (continua válida): o blackbox só zera `probe_ip_addr_hash` quando o DNS não resolve (medido: `0`; resolvido = hash > 0); então **hash 0 = problema de nome/DNS; hash > 0 e `probe_success`
  0 = API fora**. O alerta da T17 deve distinguir os dois (tasks.md, T17), e o `smoke-metrics.sh` prova a distinção com alvos
  falsos numa instância descartável do Prometheus (as séries e regras reais não recebem `project="smoke"`).
- **Logs de Prometheus e blackbox não vão ao Graylog** (Art. VI.1): hoje ficam só no `docker logs`. Decisão consciente de não
  criar driver GELF/stream agora (componentes de infraestrutura, sem dado pessoal, sem consumidor); **a avaliar depois**,
  junto da T21.
