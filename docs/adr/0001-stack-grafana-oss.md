# ADR-0001: Grafana OSS local como camada de dashboards e alertas sobre o Graylog

- **Status**: Aceito (aceito pelo responsável técnico em 2026-11-17)
- **Data**: 2026-11-17
- **Decisores**: responsável técnico (aceito em 2026-11-17, com a aprovação das recomendações padrão P1-P8 do plano)
- **Artigos da Constituição relacionados**: Art. III.4 (banco próprio), Art. IV.2/IV.4/IV.7, Art. V.1, Art. VI

## Contexto

Os projetos do Workspace enviam logs estruturados ao Graylog (OpenSearch); Keycloak e SonarQube têm UIs próprias e não
há visão consolidada nem alertas transversais. Os apps .NET não emitem OpenTelemetry. Precisamos de dashboards e alertas
como código com o menor número possível de componentes novos.

## Decisão

1. Projeto `C:\Workspace\grafana` no molde de `graylog`/`sonarqube`: compose, `generate-env.sh`, `provisioning/`
   (arquivos nativos do Grafana), `scripts/`, `tests/`, `docs/`.
2. **Grafana OSS 13.3.1** (imagem oficial `grafana/grafana`, edição OSS) por **tag + digest**; porta `127.0.0.1:3000`.
3. **Escopo v1**: Grafana + datasource `grafana-opensearch-datasource` (versão pinada, instalada no build) lendo o
   OpenSearch do Graylog. Sem Prometheus, Loki, Tempo ou OTel Collector (incrementos sob nova decisão; Prometheus é a
   primeira opção, Fase 2).
4. **Rede dedicada `logs-read`** (criada pelo projeto graylog), contendo só OpenSearch e Grafana: o OpenSearch roda sem
   security plugin (ADR-0001 do graylog) e não deve ficar visível para toda a rede `observability`.
5. Banco do Grafana: **SQLite em volume** (instância local única). Postgres e HA só em produção (nova spec).
6. Dashboards, datasources e alertas **somente por arquivo** (`allowUiUpdates: false`); sem dado pessoal (só agregações).
7. Logs do Grafana em JSON no stdout -> driver GELF -> Graylog (stream `Grafana - Infra`).
8. **Licença**: Grafana é AGPLv3. Uso interno sem modificar o código-fonte: sem obrigação de publicação; proibido distribuir
   imagem modificada ou usar componentes Enterprise sem revisão; plugin com licença compatível.
   - **Confirmado em 2026-11-17 (T02)**: `grafana-opensearch-datasource` 2.34.7 é **Apache-2.0** (LICENSE do repositório
     `grafana/opensearch-datasource`), assinado pela Grafana Labs (`signatureType: grafana`), compatível com AGPLv3 e com o
     Art. IV.7. A imagem `grafana/grafana` 13.3.1 traz a AGPLv3 em `/usr/share/grafana/LICENSE`.
   - **Nota de imagem**: o repositório `grafana/grafana-oss` no Docker Hub parou em 13.0.2; a versão 13.3.1 só existe como
     `grafana/grafana:13.3.1` (a mesma edição OSS, que é a imagem oficial). Usa-se `grafana/grafana` por tag + digest.
9. O projeto tem pouco código, mas não "nenhum código de aplicação": `opensearch-proxy/guard.js` (njs, ES module) e `tests/e2e/` e `tests/unit/` (JavaScript).
   - **Sonar**: o projeto fica **FORA do Quality Gate do SonarQube** por decisão consciente (sem projeto em `provisioning/projects.json`;
     a análise JS exigiria cobertura lcov e um token próprio). **Nenhuma análise do Sonar foi executada** neste projeto; é pendência
     aceita, a reavaliar se o `guard.js` crescer. A qualidade vem de smoke, lint de dashboards, E2E, `scripts/test-guard.sh` e `lint-repo.sh`.
   - **Cobertura (Art. V.3, ≥ 80%)**: não é medida por ferramenta. O `guard.js` tem testes unitários (`tests/unit/guard.test.mjs`, `node:test`)
     que exercitam o `route` e, por ele, todas as funções puras (NDJSON do `_msearch`, linha em branco, chaves proibidas, argumentos, tokens de
     índice, prefixos, `_mapping`/`_field_caps`). Só o `forward` roda contra um `subrequest` falso (o njs real é coberto por `smoke-proxy.sh`).
     Cobertura de linhas não medida (sem lcov); o gate numérico não é afirmado.

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Só UI do Graylog (dashboards próprios) | Nada novo | Sem visão unificada Keycloak/SonarQube/alertas multi-fonte | Pedido explícito de Grafana |
| Loki para logs | Nativo no Grafana | Duplica o Graylog; novo coletor | YAGNI, Art. VI |
| Prometheus + OTel já na v1 | Métricas reais | Apps sem OTel; mais containers | Sem consumidor hoje; Fase 2 |
| Datasource SQL (Legado/Postgres) | KPIs de negócio | Dado pessoal, acoplamento ao schema | LGPD / Art. III.4 |
| OpenSearch na rede `observability` | Sem rede nova | Qualquer container lê/escreve logs | Segurança |
| Postgres para o Grafana | Pronto para HA | Mais um banco p/ uso local | YAGNI |
| Graylog REST + Infinity | Respeita permissões do Graylog | Sem agregações temporais ricas, token a gerir | Fallback se o plugin OpenSearch falhar |

## Consequências

- **Positivas**: visão única com 1 container novo; tudo versionado; rollback simples; sem tocar nos apps.
- **Negativas / riscos**: Grafana passa a ler o índice do Graylog (acoplamento ao mapeamento de campos); OpenSearch segue
  sem autenticação (mitigação por rede); plugin precisa ser compatível com OpenSearch 3.7.
- **Risco residual (OpenSearch sem autenticação na `logs-read`)**: quem alcança a rede `logs-read` lê qualquer índice, e um
  usuário Viewer do Grafana pode consultar DSL arbitrária do datasource por `/api/ds/query` (permissão por datasource é
  recurso Enterprise), inclusive índices além dos dashboards. Mitigação planejada: datasource restrito a um index pattern
  já mascarado (LGPD), definido na T07, e avaliar um proxy somente-leitura entre o Grafana e o OpenSearch.
- **Ações decorrentes**: mudanças em `../graylog` (rede, stream, regra) e `../keycloak` (ADR-0002); atualizar READMEs.

## Nota (2026-11-17): escopo ampliado pelo ADR-0003

A v1 **não é mais "sem componente novo"**: o usuário aprovou Prometheus + blackbox exporter (health check das APIs,
T20/T22/T17) em projeto compose próprio. Ver [ADR-0003](0003-prometheus-blackbox-health.md). O restante deste ADR vale como
está; Loki, Tempo e OTel Collector continuam fora de escopo.

## Risco residual aberto (2026-11-17, rodada de correção da Onda 2)

Verificado na prática (Grafana 13.3.1 + plugin 2.34.7 + OpenSearch 3.7.0), com um Viewer local (mesmo papel do SSO). **O index
pattern do datasource NÃO contém o Viewer** e o papel Viewer **não é somente leitura** sobre o OpenSearch:

1. `POST /api/ds/query` com `index`/`database` no corpo substitui o pattern e lê índices fora dele (ex.: `gl-events_*`).
2. `/api/datasources/proxy/uid/graylog-opensearch/<caminho>` repassa qualquer caminho ao OpenSearch: o Viewer lê todos os
   índices e pode **criar e apagar** índices (`PUT`/`DELETE`).

Estado (histórico, ver atualização abaixo): **aberto e aceito temporariamente** pelo responsável técnico até a decisão sobre o proxy somente leitura na `logs-read`
(tarefa T23, sem implementação: componente novo, exige ADR e aprovação). Enquanto isso: (a) `grafana-viewer` só para
pessoas de confiança que já poderiam ler os logs; (b) nenhum painel, permissão ou texto pode tratar o index pattern ou o papel
Viewer como barreira de segurança; (c) o `smoke-test.sh` testa leitura **e escrita** como `RISCO CONHECIDO`, conta e lista os
riscos abertos no resumo final e reprova se o resultado for inconclusivo; (d) descrições que digam "somente leitura" ou
"Viewer só vê agregações" para o Viewer estão incorretas e foram corrigidas neste repositório. Este ADR foi aceito
pelo responsável técnico em 2026-11-17, mantendo o risco como residual medido (ver a atualização abaixo).

### Atualização (2026-11-17, T23): risco tratado pelo ADR-0004

O proxy somente leitura (`opensearch-proxy`, nginx + njs; [ADR-0004](0004-proxy-somente-leitura-opensearch.md), status Aceito)
passou a ficar entre o Grafana e o OpenSearch, e o Grafana saiu da rede `logs-read`. Os quatro pontos acima (leitura de
`gl-events_0` via `index` no corpo, listagem/leitura do OpenSearch inteiro, `PUT` e `DELETE` pelo proxy do datasource) agora
retornam 403 e são ASSERTIDOS pelo `smoke-test.sh` (parte 3) e pelo `smoke-proxy.sh`. Permanece residual e medido: a validação do
corpo do `_msearch` é heurística (chaves conhecidas), o Viewer ainda lê qualquer documento dos index sets do pattern e quem entrar
na `logs-read` fala com o OpenSearch sem autenticação. O texto acima é o histórico do achado; este ADR está "Aceito" (2026-11-17) com esse risco residual mantido.
