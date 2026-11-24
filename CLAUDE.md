# Grafana — dashboards e alertas do Workspace

> Herda a Constituição (`C:\Workspace\CLAUDE.md`) e o steering (`C:\Workspace\.claude\rules\`).
> Projeto de infraestrutura (só `guard.js` do proxy e testes em JS; fora do Quality Gate do Sonar, ADR-0001 item 9): aplicam-se Art. I, IV, V, VI, X e XI.
> Spec: `docs/specs/001-implantacao-grafana/` · ADRs **aceitos** em 2026-11-17: `docs/adr/0001`, `0002`, `0003`, `0004`.

> Índice rápido: `docs/INDEX.md` · Referência (produto, stack, estrutura de arquivos, datasource/Graylog, regras detalhadas): `docs/reference.md`.

## Regras deste projeto

- Imagens e plugins fixados por **tag/versão + digest**; ao atualizar, leia *What's new*/breaking changes e rode o smoke.
- Configuração **só por arquivo** (`allowUiUpdates: false`): datasources, dashboards e alertas nunca só pela UI.
  Para persistir uma edição, exporte o JSON e abra PR.
- Segredos só no `.env` (gerado, fora do git) e injetados por `$__env{VAR}`/`${VAR}`; nunca em YAML, JSON ou testes.
- Dashboards: `uid` kebab-case em inglês, sem `id`, títulos/descrições em PT-BR (`<Sistema> - <Assunto>`), só agregações,
  sem painel `logs` nem campos pessoais em pastas de Viewer.
- Não rodar junto do Keycloak e do SonarQube no mesmo `up` pesado (memória); suba por projeto.
- **Idioma (Art. I)**: nomes, uids, queries e logs em inglês; comentários, docs e saída dos scripts em PT-BR.
- Git: branch `DEV-001` (commit/push só a pedido; sem coautoria de IA). Os `.sh` são versionados com bit executável (`100755`).
- Detalhes (alertas, Prometheus, ordem de subida, riscos, CI, Git Bash): `docs/reference.md` > "Regras detalhadas".

## Comandos

```bash
./scripts/generate-env.sh                      # cria o .env (não sobrescreve)
./scripts/lint-repo.sh                         # teste estático (rodar antes de cada entrega)
docker compose up -d --build                   # [T02] sobe o Grafana (exige as redes externas: ver README)
./scripts/smoke-test.sh                        # [T02+] teste ponta a ponta
./scripts/backup.sh                            # [T09] backup do volume (.backups/)
./scripts/restore.sh --yes .backups/<arquivo>     # [T09] DESTRUTIVO: substitui o volume (faz backup de segurança antes)
./scripts/lint-dashboards.sh [--self-test]     # [T05] lint dos dashboards (jq local ou imagem jq pinada via Docker)
docker compose -f prometheus/docker-compose.metrics.yml up -d   # [T20] métricas (exige cadastro e legado de pé); suba ANTES do Grafana (rede metrics)
./scripts/smoke-proxy.sh                    # [T23] proxy somente leitura (Grafana + Graylog de pé)
./scripts/smoke-metrics.sh                     # [T20/T22] smoke das métricas
docker compose -f prometheus/docker-compose.metrics.yml -f prometheus/docker-compose.rabbitmq.yml up -d   # [ADR-0005] com o broker de pé (cria a rede rabbitmq-metrics)
./scripts/smoke-rabbitmq.sh                    # [ADR-0005] observabilidade do RabbitMQ (broker de pé; não reinicia o broker)
./scripts/smoke-graylog.sh                  # [T08] com o Graylog de pé e o override GELF (sem Keycloak)
./scripts/smoke-backup.sh                   # [T09] só o Grafana; backup/restore com `down -v` do projeto grafana
./scripts/smoke-restart.sh                  # [H1] reinício idempotente (qualquer stack do Grafana de pé)
./scripts/e2e.sh                           # [T15] E2E Playwright (Keycloak + Grafana de pé, sem Graylog)
```
