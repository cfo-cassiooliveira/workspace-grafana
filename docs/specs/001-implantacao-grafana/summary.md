# Resumo — Spec 001: Implantação do Grafana OSS

**Objetivo**: Grafana OSS local em Docker, login único via Keycloak, 100% como código (datasources, dashboards, alertas), com visão consolidada dos projetos do workspace a partir dos logs do Graylog/OpenSearch (e, depois, health das APIs via Prometheus).

**Decisões-chave**
- Grafana OSS 13.3.1, SQLite em volume, porta só `127.0.0.1:3000`, AGPLv3 aceita (uso interno) — ADR-0001.
- SSO só Authorization Code + PKCE; roles `grafana-viewer`/`grafana-editor`/`admin`; sem role = negado; break-glass local — ADR-0002.
- Config só por arquivo (`allowUiUpdates: false`); dashboards só com agregações (LGPD).
- Prometheus + blackbox para health de `cadastro`/`legado` — ADR-0003.
- `opensearch-proxy` (nginx+njs) com allowlist somente leitura entre Grafana e OpenSearch — ADR-0004.

**Contratos/interfaces**: datasources `graylog-opensearch` (via `opensearch-ro:8080`) e `prometheus`; dashboards `cadastro-overview`, `legado-overview`, `keycloak-authentication`, `sonarqube-infra`, `graylog-platform`, `api-health`; alertas em `provisioning/alerting/`; redes externas `observability`, `workspace-identity`, `logs-read`, `metrics`; logs do Grafana ao Graylog (`service_name:grafana`).

**Estado das tarefas** (tasks.md + código; verificado por existência de arquivos/testes)
- Concluídas (marcadas): T02, T05, T06, T07, T08, T09, T14, T15, T16, T17, T20, T22, T23.
- Sem marca em tasks.md, mas entregues no código (dashboards + `tests/dashboards/*.test.sh`; T01 via `scripts/generate-env.sh`, `lint-repo.sh`): T01, T10, T11, T12, T13. O README as dá por entregues.
- T03 e T04 (graylog/keycloak, outros repositórios): sem marca; há regras `19-/21-grafana-*.rule` no graylog e referências ao client `grafana` no keycloak.
- Pendente: T21 (scrape de Keycloak/SonarQube; fora da v1, exige novo OK). Operacional: agendar backup e validar 0600 em Linux/WSL (README, "Pendências").

Detalhes: [spec.md](spec.md) · [plan.md](plan.md) · [tasks.md](tasks.md)
