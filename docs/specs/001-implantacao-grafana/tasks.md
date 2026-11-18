# Tarefas 001 — Implantação do Grafana OSS

Dono: **infra** = `backend-developer` (infra Docker/shell/provisioning); **qa** = `qa-engineer`.
Não há tarefa de frontend de código (a UI é do Grafana; verificação visual dos dashboards cabe ao `qa-engineer`).
`[P]` = paralelizável com as demais da mesma onda. Todas incluem seus testes (Art. V.1) e respeitam Art. I
(código/nomes em inglês, comentários e docs em PT-BR). Raiz: `C:\Workspace\grafana` salvo indicação (`../x`).

## Onda 0 — Scaffolding (walking skeleton começa aqui)

### T01 — Scaffolding do projeto (infra)
- **Dep.**: P7 respondida (licença). **Arquivos**: `CLAUDE.md` (de `_templates/project-CLAUDE.md`), `README.md`, `.gitignore`
  (`.env`, `.backups/`), `.gitattributes` (LF em `*.sh`), `scripts/generate-env.sh`, `tests/README.md`, `docs/` (já existe).
- **Testes**: `scripts/lint-repo.sh` (shellcheck nos .sh, ausência de segredos, `.env` ignorado) rodando local.
- **Pronto**: `generate-env.sh` cria `.env` (0600) com `GRAFANA_ADMIN_USER` não padrão, `GRAFANA_ADMIN_PASSWORD`, `GF_SECURITY_SECRET_KEY` aleatórios, sem sobrescrever; `git init` na branch `DEV-001` só se o usuário pedir.

## Onda 1

### T02 — Imagem e compose do Grafana, hardening base (infra) [P] — CONCLUÍDA (usa grafana/grafana:13.3.1; ver ADR-0001)
- **Dep.**: T01. **Arquivos**: `Dockerfile` (grafana-oss 13.3.1 por tag+digest; plugin `grafana-opensearch-datasource` versão pinada), `docker-compose.yml` (porta `127.0.0.1:3000`, volume, redes externas, healthcheck `/api/health`, `GF_*` de hardening/anonymous off/sign-up off/telemetria off/logs JSON/pt-BR/CSP), `scripts/smoke-test.sh` (parte 1).
- **Testes**: smoke 1: healthy; `/api/dashboards/home` anônimo = 401; login com `admin/admin` falha; `sign_up` off; cabeçalhos (CSP, X-Content-Type-Options); porta só em 127.0.0.1; versão == tag fixada; licença do plugin confirmada (anotar no ADR-0001).
- **Pronto**: `docker compose up -d --build` verde; digest registrado; chaves `GF_*` validadas na doc 13.3 (Context7).

### T03 — Graylog: rede `logs-read`, stream e regra do Grafana (`../graylog`) [P]
- **Dep.**: T01 (ADR-0001 aceito). **Arquivos**: `../graylog/docker-compose.yml` (rede `logs-read`, OpenSearch com alias), `../graylog/provisioning/provision.sh` (stream `Grafana - Infra`, retenção, alerta opcional), `../graylog/provisioning/rules/NN-grafana-json.rule`, `../graylog/scripts/smoke-test.sh`, README/CLAUDE do graylog (nova rede e regra).
- **Testes**: casos novos no smoke do graylog: evento sintético `service_name:grafana` JSON chega ao stream e com nível correto; log de login com e-mail é mascarado/descartado (LGPD); OpenSearch continua inacessível de `observability`.
- **Pronto**: smoke do graylog verde; **não** rodar junto do keycloak.

### T04 — Keycloak: client `grafana`, roles e mapper (`../keycloak`) [P]
- **Dep.**: T01 (ADR-0002 aceito). **Arquivos**: `../keycloak/realm/realm-workspace.json` (roles `grafana-viewer`/`grafana-editor`, client `grafana`), `../keycloak/provisioning/provision.sh` (`ensure_grafana_client`, redirect/post-logout, PKCE S256, sem Direct Grant, mapper `roles`, scope mappings), `../keycloak/scripts/generate-env.sh` (`KC_GRAFANA_CLIENT_SECRET`), `../keycloak/docker-compose.yml` (env), docs do keycloak.
- **Testes**: no smoke do keycloak e/ou IT: client existe com flags corretas; password grant recusado; token de usuário de teste contém `roles` só com `grafana-*`/`admin`; mudança idempotente.
- **Pronto**: smoke do keycloak verde; segredo nunca impresso.

### T05 — Esqueleto de dashboards e lint (infra) [P] — CONCLUÍDA
- **Dep.**: T01. **Arquivos**: `provisioning/dashboards/providers.yaml`, pastas por projeto com `.gitkeep`, `scripts/lint-dashboards.sh` (jq: `uid` único kebab-case, sem `id`, datasource por uid provisionado, `schemaVersion`, títulos PT-BR, **proíbe painel `logs` e campos LGPD** em pastas de Viewer, `editable:false`), montagem no compose (alinhar com T02).
- **Testes**: lint com dashboard bom e ruins (fixtures em `tests/fixtures/dashboards/`).
- **Pronto**: lint verde e falhando nos casos ruins.

## Onda 2

### T06 — SSO Keycloak no Grafana (infra) — CONCLUÍDA
- **Dep.**: T02, T04. **Arquivos**: `docker-compose.yml` (bloco `GF_AUTH_GENERIC_OAUTH_*`, `$__env` para secret), `generate-env.sh` (copia `KC_GRAFANA_CLIENT_SECRET` sem exibir), `scripts/smoke-test.sh` (parte 2).
- **Testes**: smoke 2: discovery do Keycloak alcançável do container; `/login/generic_oauth` redireciona ao Keycloak com `code_challenge_method=S256`; `use_pkce`, `role_attribute_strict`, `allow_assign_grafana_admin=false` conferidos via `/api/frontend/settings`/env; sem `client_secret` em arquivos do repo.
- **Pronto**: fluxo manual com usuário `grafana-viewer` entra como Viewer; sem role é negado; logout encerra sessão Keycloak.

### T07 — Datasource Graylog/OpenSearch (infra) — **spike primeiro** — CONCLUÍDA (compatível, sem fallback; risco do Viewer x OpenSearch aberto: ver README)
- **Dep.**: T02, T03. **Arquivos**: `provisioning/datasources/graylog-opensearch.yaml`, `tests/fixtures/gelf/*.json` (logs sintéticos), `scripts/smoke-test.sh` (parte 3).
- **Testes**: smoke 3: `GET /api/datasources/uid/graylog-opensearch/health` OK; query de agregação por `level`/`service_name` retorna dados da fixture enviada via GELF HTTP.
- **Pronto**: compatibilidade plugin x OpenSearch 3.7 x Grafana 13.3 confirmada (senão aplicar fallback do plan §11) e prefixo de índice do Graylog documentado.

### T08 — Envio dos logs do Grafana ao Graylog (infra) [P] — CONCLUÍDA
- **Dep.**: T02, T03. **Arquivos**: `docker-compose.graylog.yml` (driver GELF `udp://127.0.0.1:12201`, tag `grafana`), README (uso).
- **Testes**: `scripts/smoke-graylog.sh`: sobe com o override, gera evento (login falho do break-glass) e confere no Graylog `service_name:grafana`, nível, sem e-mail em claro.
- **Pronto**: smoke verde; smoke principal não recria o container sem o override (regressão citada no sonarqube).

### T09 — Backup e restauração (infra) [P] — **CONCLUÍDA**
- **Dep.**: T02. **Arquivos**: `scripts/backup.sh`, `scripts/restore.sh`, `.gitignore`.
- **Testes**: smoke: cria usuário/preferência, backup, `down -v`, restore, confere estado; backup com permissão 0600.
- **Pronto**: documentado no README (frequência e retenção conforme P5).

## Onda 3 (todas [P], dependem de T05 e T07)

### T10 — Dashboard Cadastro - Visão geral (infra)
- **Arquivos**: `provisioning/dashboards/cadastro/overview.json`. **Testes**: lint (T05) + smoke "dashboard existe e consulta retorna dados da fixture" + screenshots Playwright mobile/tablet/desktop (qa). **Pronto**: 4 estados verificados, PT-BR, só agregações, drill-down ao Graylog.

### T11 — Dashboard Legado - Visão geral (infra)
- **Arquivos**: `provisioning/dashboards/legado/overview.json`. **Testes/Pronto**: idem T10; incluir login falho e API interna de migração sem campos sensíveis.

### T12 — Dashboard Keycloak - Autenticação (infra)
- **Arquivos**: `provisioning/dashboards/keycloak/authentication.json`. **Testes/Pronto**: idem; conferir campo `type` (`LEGACY_*`) nos logs reais; sem `masked_login` exibido.

### T13 — Dashboards SonarQube - Infra e Graylog - Plataforma (infra)
- **Arquivos**: `provisioning/dashboards/sonarqube/infra.json`, `provisioning/dashboards/graylog/platform.json`. **Testes/Pronto**: idem; painel "serviços sem log" validado derrubando um serviço no smoke.

### T14 — Alertas como código (infra) — CONCLUÍDA (sem notificação externa, P4; ver README "Alertas como código")
- **Dep.**: T07 (e T10-T13 para links). **Arquivos**: `provisioning/alerting/{rules,contact-points,policies}.yaml` (3 regras: Cadastro/Legado taxa de erros, Keycloak falhas de login em rajada, Plataforma serviço sem logs), contact point conforme P4.
- **Testes**: smoke: regras carregadas via API de provisioning; fixture com erros força Firing e depois Normal. **Pronto**: sem duplicar alertas já existentes no Graylog (listados no README).

### T17 — Health check das APIs no Grafana (infra) — CONCLUÍDA — **pedido do usuário em 2026-11-17**
- **Decisão do usuário (2026-11-17)**: **Prometheus + blackbox exporter** (não Infinity). T20 e T22 foram promovidas da Fase 2 e viram pré-requisito desta tarefa.
- **Dep.**: T05, T20, T22 (e T14 para integrar o alerta). **Arquivos**: `provisioning/datasources/prometheus.yaml`, `provisioning/dashboards/graylog/api-health.json` (pasta Plataforma), regra "API fora do ar" em `provisioning/alerting/rules.yaml`, `scripts/smoke-test.sh` (parte 4).
- **Escopo**: `/health/live` e `/health/ready` (Art. VI.4) das APIs `cadastro` e `legado` (e `WebAPI` se expuser): status, latência e disponibilidade em 24h/7d/30d; alerta quando `ready` falhar.
- **Testes**: smoke: com a API no ar a série `probe_success` = 1 e o painel mostra UP; derrubando a API, vira DOWN, a regra dispara e depois volta ao normal. Lint do dashboard (T05) e screenshots nas 3 larguras.
- **Pronto**: health das APIs visível, sem expor dados sensíveis; o Grafana só lê o Prometheus (nunca alcança as redes das APIs).
- **Alerta e DNS (ADR-0003)**: os alvos usam os aliases de rede `cadastro-api`/`legado-api` (antes, nomes de container); falha de DNS (alias ausente) também dá `probe_success` 0. O alerta "API fora do ar" DEVE distinguir: `probe_success == 0` com `probe_ip_addr_hash > 0` = API fora; com `probe_ip_addr_hash == 0` = nome/DNS não resolve (alerta separado, "alvo não resolve"). O `smoke-metrics.sh` já prova a distinção.

## Onda 4

### T15 — E2E SSO e hardening com Playwright (qa) — CONCLUÍDA
- **Dep.**: T06, T10. **Arquivos**: `tests/e2e/` (Playwright em container, como `../cadastro/e2e`), `scripts/e2e.sh`.
- **Testes**: login viewer/editor/admin com usuários descartáveis `e2e.*` (criados e removidos pela Admin API do Keycloak); usuário sem role negado; anônimo bloqueado; logout; screenshots de dashboards nas 3 larguras + varredura de redimensionamento + axe nas páginas de login; console sem erros. **Pronto**: zero defeitos visuais; não rodar junto de provisioner/smoke do keycloak.

### T16 — Fechamento: documentação e revisão (infra + qa) — CONCLUÍDA (2026-11-17; resultado no README, "Resultado da verificação final"; ADRs 0001-0004 aceitos)
- **Dep.**: todas. **Arquivos**: `README.md` (ordem de subida: redes -> graylog -> keycloak -> grafana; pré-requisitos; backup), `CLAUDE.md`, ADRs 0001/0002 para "Aceito", referência cruzada nos README de graylog/keycloak/sonarqube, `../CLAUDE.md` se listar projetos.
- **Testes**: `smoke-test.sh` completo + `lint-repo.sh` + `lint-dashboards.sh` + revisão `code-reviewer`. **Pronto**: Definition of Done da Constituição.

## Prometheus + blackbox (**aprovado em 2026-11-17**, promovido da Fase 2; Onda 2, em paralelo a T06-T09)

- **T20 — CONCLUÍDA** Prometheus + blackbox exporter (imagens por tag+digest, `prometheus.yml`, `blackbox.yml`, retenção 30 dias, rede `metrics-probe` (Prometheus + blackbox) e `metrics` (Prometheus + Grafana, T17); só o blackbox entra nas redes das APIs (`cadastro_default`/`legado_default`), conforme o ADR-0003; sem porta no host) + smoke + **ADR 0003** (registra a mudança de escopo e atualiza o ADR-0001, que dizia "sem componente novo na v1"). Dep.: T02. Primeiro passo: confirmar que `cadastro` e `legado` expõem `/health/live` e `/health/ready`; se faltar, reportar (ajuste no backend vira tarefa à parte).
- **T22 — CONCLUÍDA** Probes do blackbox para as APIs `cadastro`, `legado` (e `WebAPI` se expuser): módulos HTTP 2xx, timeout, alvos por arquivo versionado, regra de gravação de disponibilidade. Dep.: T20.

## Fase 2 restante (**fora da aprovação atual**)

- **T21** Scrape de métricas do Keycloak (`keycloak:9000/metrics`) e SonarQube (passcode) + dashboards (JVM/HTTP/Sonar). Dep.: T20. Só com novo OK do usuário.

## Grafo e ondas

```
T01 -> {T02, T03, T04, T05}            (onda 1, 4 em paralelo; T03/T04 tocam repositórios de outros projetos)
T02+T04 -> T06      T02+T03 -> T07, T08      T02 -> T09     (onda 2; T06 e T07 em paralelo; T08, T09 [P])
T02 -> T20 -> T22                                            (onda 2, em paralelo a T06-T09; Docker pesado: máx. 2 stacks)
T05+T07 -> {T10, T11, T12, T13}; T07 -> T14                  (onda 3, até 5 em paralelo; teto padrão 4)
T05+T20+T22+T14 -> T17                                       (onda 3)
T06+T10 -> T15 ;  tudo -> T16                                (onda 4)
```
Observação de execução: T03 e T04 (e T15) não podem rodar ao mesmo tempo que provisioners/smokes do graylog ou keycloak
(falha intermitente documentada); usar worktree/sequência entre elas se houver conflito, e nunca dois smokes de infra juntos.

## Pendente de decisão do usuário

- **T23 — CONCLUÍDA** Proxy somente leitura do OpenSearch (nginx+njs por tag+digest, pasta `opensearch-proxy/`, redes `logs-ro`+`logs-read`, ADR-0004 Proposto; `smoke-proxy.sh`; smoke parte 3 assertando bloqueio) (fecha o risco residual do ADR-0001). Hoje o Viewer alcança, por `/api/ds/query` com `index` no corpo e por `/api/datasources/proxy`, índices fora do pattern e até escrita/apagamento no OpenSearch. Proposta: proxy na rede `logs-read` aceitando só `POST /<pattern>/_msearch`, `GET /`, `GET /<pattern>/_mapping` e `_field_caps`. É componente novo: exige ADR e aprovação. Riscos residuais medidos no ADR-0004.
