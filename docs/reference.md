# Referência do projeto Grafana (movida do CLAUDE.md)

> Seções movidas verbatim do `CLAUDE.md` para reduzir o contexto lido por agentes. Regras e comandos continuam no `CLAUDE.md`.

## Produto

- **Propósito**: Grafana OSS local em Docker que dá visão consolidada (dashboards e alertas) dos projetos do
  workspace a partir dos logs do Graylog/OpenSearch, com login único via Keycloak e tudo configurado como código.
- **Usuários**: Observador (`grafana-viewer`), Operador/Dev (`grafana-editor`), Administrador (`admin` do realm),
  break-glass local (só se o Keycloak cair).
- **Bounded context**: observabilidade — dono do volume `grafana-data` (SQLite); não possui dados de negócio.
- **Fora de escopo (v1)**: scrape de Keycloak/SonarQube (T21; só o health das APIs entrou, ADR-0003), Loki/Tempo/OTel, datasources SQL, produção/HTTPS, notificação
  externa de alertas (e-mail/Slack), instrumentar os apps.
- **Requisitos não funcionais**: só `127.0.0.1:3000`; sem anônimo, sem sign-up, sem telemetria; LGPD: dashboards só
  com agregações (convenção dos dashboards, NÃO uma barreira: o `opensearch-proxy` (T23, ADR-0004) bloqueia escrita e leitura fora do pattern, mas o Viewer ainda lê documentos brutos dos index sets do pattern); AGPLv3 aceita (uso interno, sem modificar o Grafana).

## Stack deste projeto (diferenças do padrão)

- Grafana OSS **13.3.1** (`grafana/grafana` — o `grafana-oss` do Docker Hub parou na 13.0.2; tag + digest) + plugin
  `grafana-opensearch-datasource` 2.34.7 (Apache-2.0) instalado no build em `/opt/grafana-plugins` (fora do volume).
- Banco: SQLite em volume · Autenticação: Keycloak OIDC (code + PKCE S256), realm `workspace`, client `grafana`.
- Redes externas: `observability` (GELF), `workspace-identity` (Keycloak), `logs-read` (só OpenSearch + `opensearch-proxy`; o Grafana NÃO entra mais), `logs-ro` (interna, criada por este compose: Grafana + proxy), `metrics` (Grafana lê o Prometheus; T17); da stack de métricas: `metrics` e `metrics-probe` (internas, criadas por `prometheus/docker-compose.metrics.yml`, que deve subir ANTES do Grafana) e `cadastro_default`/`legado_default` (criadas por cadastro e legado; só o blackbox entra nelas; pela rede `metrics` o Grafana não alcança blackbox nem APIs, mas as APIs já são alcançáveis por `observability`/`workspace-identity`, compartilhadas antes da T17: risco conhecido).
- Sessão: `GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION=8h` e `..._LIFETIME_DURATION=12h` (ADR-0002): revogação/mudança de role no Keycloak vale no próximo login, no máximo em 12 h.
- Graylog stream: `Grafana - Infra` · Sem projeto no SonarQube (só shell/JSON/YAML).
- Mapeamento: `grafana-viewer`→Viewer, `grafana-editor`→Editor, `admin`→Admin da org (não Server Admin); sem role = negado.
- SSO (T06): `GF_AUTH_GENERIC_OAUTH_*` no compose; `role_attribute_path` é **JMESPath** (confirmado na 13.x), sem `|| 'Viewer'` (sem papel = negado via `role_attribute_strict`). `auth_url` público (`localhost:8180`), `token_url`/`api_url` em `keycloak:8080`. Username de usuário descartável no Keycloak: máx. 30 caracteres. O smoke (parte 2) exige o Keycloak de pé e lê `../keycloak/.env`.

## Estrutura

```
docker-compose.yml          grafana (build do Dockerfile) [T02] + opensearch-proxy (nginx+njs) [T23]
opensearch-proxy/           nginx.conf + guard.js (allowlist somente leitura do OpenSearch; ADR-0004) [T23]
docker-compose.graylog.yml  logging driver GELF (tag grafana)      [T08]
Dockerfile                  grafana por tag+digest + plugin        [T02]
provisioning/datasources/    graylog-opensearch.yaml (uid graylog-opensearch; index pattern restrito) [T07], prometheus.yaml (uid prometheus, rede metrics) [T17]
provisioning/alerting/      rules.yaml, contact-points.yaml, policies.yaml (alertas como código; sem notificação externa, P4) [T14/T17]
provisioning/               datasources, dashboards (JSON por projeto) e alerting (arquivos nativos do Grafana)
provisioning/dashboards/    providers.yaml + uma pasta por projeto (cadastro, legado, keycloak, sonarqube, graylog) [T05]
scripts/generate-env.sh     gera o .env com segredos aleatórios
scripts/lint-repo.sh        teste estático (shellcheck, segredos, .env ignorado, generate-env)
scripts/lint-dashboards.sh  lint dos JSON de dashboards (+ dashboard-lint.jq; --self-test usa as fixtures) [T05]
scripts/smoke-test.sh       teste ponta a ponta (1: saúde/hardening; 2: SSO [T06]; 3: datasource [T07]; 4a: alertas [T14]; 4b: health das APIs [T17]; flags --skip-sso/--skip-datasource/--skip-alerts/--skip-metrics)
scripts/test-guard.sh        unitário (node:test) do opensearch-proxy/guard.js, em tests/unit/ (imagem Node do Playwright; também no lint-repo.sh)
scripts/sweep-e2e-users.sh  lista/remove (--delete) usuários e2e.grafana.* órfãos no Keycloak/Grafana
scripts/smoke-proxy.sh      hardening do proxy + allowlist (métodos, rotas, índices do _msearch) [T23]
scripts/smoke-graylog.sh    sobe com o override GELF e confere o log do Grafana no Graylog sem login/e-mail em claro [T08]
scripts/backup.sh           backup do volume em .backups/ (0600, gzip/tar conferidos, retenção 30 dias, Grafana parado alguns segundos) [T09]
scripts/restore.sh          DESTRUTIVO (exige --yes): substitui o volume; backup de segurança antes, extração em volume temporário, recusa symlink/hardlink [T09]
.backups/                   backups do volume (usuários e preferências; fora do git, 0600)
scripts/smoke-backup.sh     backup.sh + restore.sh: backup 0600/íntegro, recusas, symlink/hardlink, falha no meio, down -v só do projeto grafana, restore [T09]
scripts/smoke-restart.sh    idempotência (H1): restart não duplica/perde dashboards, pastas, datasources, alertas, usuários
tests/                      fixtures (GELF, alerts, dashboards bons/ruins em tests/fixtures/dashboards), tests/dashboards/*.test.sh, E2E Playwright
scripts/e2e.sh              E2E SSO/hardening (Playwright 1.64.1 em container, tests/e2e/; Keycloak + Grafana, sem Graylog) [T15]
scripts/lib/keycloak-admin.sh  funções da Admin API do Keycloak (usuários descartáveis, TOTP), compartilhadas por e2e.sh e smoke-test.sh [T15]
prometheus/                 Prometheus + blackbox (compose próprio, targets/ file_sd, rules.yml) [T20/T22, ADR-0003]
scripts/smoke-rabbitmq.sh   smoke do RabbitMQ (alvos, dashboards com dados, 13 alertas, mutation check no broker) [ADR-0005]
scripts/import-rabbitmq-dashboards.sh  baixa os dashboards oficiais 10991/11350 por revisão e SHA-256 fixados [ADR-0005]
prometheus/docker-compose.rabbitmq.yml  override opcional: rede externa rabbitmq-metrics no Prometheus [ADR-0005]
scripts/smoke-metrics.sh    smoke da stack de métricas (promtool, hardening, probe_success 1->0->1) [T20/T22]
docs/adr/  docs/specs/      decisões e especificação
```

## Datasource e logs ao Graylog (T07/T08)

- Datasource `graylog-opensearch`: sem credenciais; `database` = prefixos dos index sets do Graylog (todos mascarados na gravação),
  sem `gl-*`/`top_queries-*`; `pplEnabled: false`. Index set novo no Graylog exige atualizar o pattern no YAML.
- **OpenSearch somente leitura (T23, ADR-0004)**: o datasource usa `http://opensearch-ro:8080` (proxy), nunca o OpenSearch direto; o Grafana não está
  na `logs-read`. A allowlist (e a lista `PREFIXES` do `guard.js`, igual ao pattern do YAML) é a barreira; o pattern sozinho NÃO é. Residual medido no ADR-0004:
  validação do corpo heurística, Viewer lê documentos brutos do pattern, `logs-read` sem autenticação. Mudou a allowlist/prefixos: `./scripts/smoke-proxy.sh`.
- Com o Graylog de pé suba o Grafana com `-f docker-compose.yml -f docker-compose.graylog.yml` (senão os logs não chegam);
  Keycloak e Graylog não rodam juntos: `smoke-test.sh --skip-sso` (Graylog) e `--skip-datasource` (Keycloak). A parte 3 do `smoke-test.sh` ASSERTA o bloqueio do proxy; riscos conhecidos que sobrarem (parte 4b) são contados no resumo e "APROVADO" com riscos abertos não é "fechado".
- Prometheus/blackbox usam os aliases de rede `cadastro-api`/`legado-api` (adicionados aos composes de cadastro e legado; o nome de container `cadastro-api-1` muda com projeto/escala): alias ausente gera falha de DNS indistinguível de API fora, exceto por `probe_ip_addr_hash` = 0 (resolvido = hash > 0) (a regra "API fora do ar" da T17 distingue; ADR-0003). Eles ainda não enviam logs ao Graylog.
- Smoke com `bash -x` vaza a senha do break-glass: nunca use.

## Regras detalhadas

- Regras de alerta novas não duplicam os alertas já existentes no Graylog (lista no README). Sem notificação externa na v1: contact point `ui-only` + mute timing `always` + SMTP desligado; um contact point sem integração derruba o provisioning (13.3).
- Dashboards sobre o Prometheus filtram `project!="smoke"` (alvos falsos do smoke); a regra "API fora do ar" distingue DNS (`probe_ip_addr_hash == 0`, rótulo `failure_kind=dns`) de API fora (`api_down`).
- No Git Bash (Windows), comandos com caminhos `/x:` ou volumes usam `MSYS_NO_PATHCONV=1` e `pwd -W`.
- Ordem de subida: redes -> graylog -> keycloak -> grafana -> métricas (README). Keycloak e Graylog nunca juntos nos smokes: passagem 1 (Keycloak + Grafana: `smoke-test.sh --skip-datasource --skip-alerts --skip-metrics`, `e2e.sh`) e passagem 2 (Graylog + Grafana: `--skip-sso`, `smoke-proxy.sh`, `smoke-graylog.sh`).
- Riscos/limitações e pendências ficam no README ("Riscos conhecidos e limitações", "Pendências"); atualize junto ao mudar um ADR. Pendências: agendar backup, validar 0600 em Linux/WSL.
- **CI** (`.github/workflows/ci.yml`): gitleaks (histórico), Trivy `fs` (vuln+misconfig, HIGH/CRITICAL, `--ignore-unfixed`), ShellCheck, lint (`lint-repo`, `lint-dashboards` + `--self-test`, `tests/dashboards`, `test-guard`) e `docker compose config -q`. Sem Sonar (ADR-0001 item 9) e sem smokes/E2E (locais). Exceções: `.trivyignore.yaml` (justificativa + `expired_at`) e `.gitleaksignore` (comentado). Imagens por tag+digest; actions por SHA.
