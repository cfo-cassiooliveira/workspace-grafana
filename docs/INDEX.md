# Índice — Grafana (leia isto antes dos docs longos)

**Specs**
- 001 Implantação do Grafana OSS — Proposta — `docs/specs/001-implantacao-grafana/summary.md`

**ADRs** (0001-0004 Aceitos, 2026-11-17)
- 0001 Grafana OSS local sobre o Graylog — `docs/adr/0001-stack-grafana-oss.md`
- 0002 SSO Keycloak (OIDC + PKCE) — `docs/adr/0002-sso-keycloak-grafana.md`
- 0003 Prometheus + blackbox (health das APIs) — `docs/adr/0003-prometheus-blackbox-health.md`
- 0004 Proxy somente leitura do OpenSearch — `docs/adr/0004-proxy-somente-leitura-opensearch.md`
- 0005 Observabilidade do RabbitMQ (Proposto) — `docs/adr/0005-observabilidade-rabbitmq.md`

**Comandos**: `./scripts/generate-env.sh` · `./scripts/lint-repo.sh` · `./scripts/lint-dashboards.sh --self-test` · `docker compose up -d --build` · `./scripts/smoke-test.sh` · `./scripts/e2e.sh`

**Onde procurar**
- Regras e comandos: `CLAUDE.md`; produto, stack, estrutura, datasource: `docs/reference.md`
- Subida, redes, alertas, riscos, pendências: `README.md`
- Dashboards/alertas/datasources: `provisioning/`; proxy: `opensearch-proxy/`; testes: `tests/`, `scripts/`
