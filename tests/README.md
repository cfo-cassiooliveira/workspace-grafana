# Testes do projeto Grafana

Infraestrutura sem código de aplicação: a qualidade vem de testes estáticos e de smoke (Art. V.1).

| Teste | Onde | O que cobre | Quando existe |
|---|---|---|---|
| `scripts/lint-repo.sh` | local/CI | sintaxe e `shellcheck` dos `.sh`, LF, ausência de segredos, `.env` ignorado, comportamento do `generate-env.sh` (0600, não sobrescreve, aleatório) | T01 |
| `scripts/smoke-test.sh` | local | saúde, versão, plugin, hardening (parte 1, T02); SSO (parte 2, T06); datasource, agregação da fixture GELF e Viewer x índices (parte 3, T07); dashboards, alertas nas tarefas seguintes. Flags `--skip-sso`/`--skip-datasource` (Keycloak e Graylog não rodam juntos) | T02 em diante |
| `scripts/smoke-graylog.sh` | local | override GELF: login falho chega ao Graylog (`service_name:grafana`, nível), sem login/e-mail em claro; smoke principal não recria o container | T08 |
| `scripts/smoke-backup.sh` | local | backup 0600/íntegro, recusas do restore (sem --yes, inválido, symlink, hardlink), falha no meio sem perder o volume, `down -v` e restore | T09 |
| `scripts/smoke-metrics.sh` | local | Prometheus + blackbox: config, hardening, alvos, probe_success 1->0->1 e diagnóstico DNS x API fora em instância descartável | T20/T22 |
| `scripts/test-guard.sh` | `tests/unit/` | unitário (`node:test`) do `opensearch-proxy/guard.js`: NDJSON do `_msearch`, linha em branco, chaves proibidas, argumentos, tokens de índice e prefixos, `_mapping`/`_field_caps`; roda na imagem Node do Playwright (tag+digest) e também no `lint-repo.sh` | M2 |
| `scripts/lint-dashboards.sh` | local/CI | regras dos JSON de dashboards (uid, datasource, painéis proibidos); `--self-test` prova que o bom passa e cada `bad-<regra>.json` falha | T05 |
| `tests/fixtures/dashboards/` | lint | `good/` (aprovado), `bad/bad-<regra>.json` (um por regra) e `duplicate/` (uid repetido) | T05 |
| `tests/fixtures/gelf/` | smoke | logs GELF sintéticos (`__RUN_ID__` trocado por execução, sem dado pessoal) | T07 |
| `scripts/e2e.sh` (Playwright) | `tests/e2e/` | login por role (viewer/editor/admin com OTP), negação sem role, anônimo, logout, sessão, CSP, axe, screenshots 390/820/1440 e varredura 320-1920; Keycloak + Grafana, sem Graylog | T15 |

Rode antes de cada entrega: `./scripts/lint-repo.sh`. O `shellcheck` é usado se instalado; senão, via Docker
(`koalaman/shellcheck`); sem nenhum dos dois, apenas `bash -n` (com aviso).
