# ADR-0004: Proxy somente leitura (nginx + njs) entre o Grafana e o OpenSearch

- **Status**: Aceito (aceito pelo responsável técnico em 2026-11-17)
- **Data**: 2026-11-17
- **Decisores**: responsável técnico (T23 aprovada pelo usuário; ADR aceito em 2026-11-17, mantendo os riscos residuais e as limitações conhecidas abaixo)
- **Artigos da Constituição relacionados**: Art. III.4, Art. IV.1/IV.3/IV.5 (negar por padrão, entrada não confiável), Art. IV.7 (licença), Art. VII.1 (timeout)
- **Relacionado**: [ADR-0001](0001-stack-grafana-oss.md) (risco residual aberto)

## Contexto

O OpenSearch do Graylog roda sem security plugin e o Grafana OSS não tem permissão por datasource (Enterprise). Medido no
ADR-0001 com um Viewer: (1) `index` no corpo de `/api/ds/query` substitui o index pattern; (2) `/api/datasources/proxy/...`
repassa qualquer caminho, inclusive `PUT`/`DELETE`; (3) a listagem de índices e a leitura de `gl-events_0` ficam abertas.
Um Viewer podia apagar índices do Graylog.

## Decisão

1. Novo serviço `opensearch-proxy` no `docker-compose.yml` do Grafana: **nginx 1.29-alpine por tag + digest** (licença
   BSD-2-Clause, confirmada; módulo **njs** já incluso na imagem oficial), sem build próprio. O Grafana passa a usar
   `http://opensearch-ro:8080`; o proxy encaminha a `opensearch:9200`.
2. **Hardening**: usuário `101:101` (não-root), `read_only: true` (só `/tmp` em tmpfs), `cap_drop: [ALL]`,
   `no-new-privileges`, healthcheck, **sem porta no host**, configuração montada só leitura, sem o entrypoint do nginx.
3. **Allowlist estrita** (`opensearch-proxy/guard.js`; tudo que não casa é `403` JSON):
   `GET|HEAD /` · `POST [/<padrão>]/_msearch` · `GET /<padrão>/_mapping` · `GET|POST /<padrão>/_field_caps`.
   `PUT/DELETE/PATCH`, `_bulk`, `_search`, `_cat`, `_cluster` etc. = 403. `_cat` **não** é necessário: o health do plugin
   usa `_field_caps`. Corpo ≤ 1 MB (413), timeouts de 10 s (cliente) e 30 s (upstream), sem compressão do upstream.
4. **Índice do `_msearch` validado no proxy** (resolve o furo do `index` no corpo): o corpo NDJSON é lido, cada cabeçalho
   só pode ter chaves conhecidas e o índice efetivo (`index`/`indices` do cabeçalho, senão o da URL) precisa casar
   `^(cadastro|legado|keycloak|sonarqube|grafana|graylog)_[a-z0-9_*.-]*$` por token (sem `gl-*`, `top_queries-*`, `.plugins*`,
   `cluster:índice`, `*` solto ou `-exclusão`). Sem índice em lugar nenhum = 403 (varreria tudo). As linhas de consulta são
   recusadas se contiverem as chaves `index`, `_index`, `indices`, `indexed_shape` ou `wrapper` (terms lookup, more_like_this, percolate,
   geo_shape indexado e query em base64 leem outro índice a partir do corpo; medido abaixo). A lista de prefixos é a mesma do
   datasource (`lint-repo.sh` confere a igualdade).
5. **Redes**: o proxy fica em `logs-read` (externa, criada pelo Graylog, alias `opensearch`) **e** na nova rede `logs-ro`
   (`internal`, só Grafana e proxy, alias `opensearch-ro`). O **Grafana saiu da `logs-read`**: não há mais rota direta
   dele ao OpenSearch. Nada mudou em `../graylog`.

5b. **Pareamento NDJSON e argumentos de URL (rodada de correção 1)**: linha em branco no meio do NDJSON é recusada (só a última
   pode ser vazia) e o que segue ao OpenSearch é o NDJSON **canônico remontado** do que foi validado, nunca o texto
   original. Argumentos de URL só de uma lista fechada por operação (`source`, `source_content_type`, `filter_path`, `pretty`
   etc. = 403); `_field_caps` POST é reserializado após a checagem.

## Medição (2026-11-17; Grafana 13.3.1 + plugin 2.34.7 + OpenSearch 3.7.0; só nomes de campos e contagens)

| Índice | Docs | Campos (nomes) |
|---|---|---|
| `gl-events_0` | 2124 | alert, associated_assets, event_definition_id/type, fields, group_by_fields, key, key_tuple, message, origin_context, priority, scores, source, source_streams, streams, tags, timerange_*, timestamp... (eventos de alerta do Graylog; podem repetir trechos de mensagens) |
| `gl-system-events_0` | 21 | eventos internos do Graylog |
| `top_queries-*` (6 índices) | ~10 mil | indices, source (**texto das consultas executadas**), username, user_roles, measurements... |
| `.plugins-ml-config` | 1 | interno do OpenSearch |
| `cadastro/legado/keycloak/sonarqube/grafana/graylog_*` | no pattern | passam pelo pipeline de mascaramento LGPD |

Os índices fora do pattern não têm a garantia de mascaramento dos index sets, e `top_queries` guarda o texto das consultas
de quem consultou: por isso ficam fora. Evidência: sem o guard, um `terms lookup` de `cadastro_*` em `gl-events_0`
funcionou (501 docs casados); pelo proxy, o mesmo `_msearch` dá 403.

## Bypass encontrado e corrigido (revisão, medido)

A primeira versão do guard descartava linhas em branco ao validar os pares cabeçalho/corpo, mas repassava o texto original; o
OpenSearch pareia as linhas de outro jeito. Reproduzido no OpenSearch real (a partir do container do Grafana, só contagens):
`POST /cadastro_*/_msearch` com `{"index":"cadastro_*"}
{}
<linha em branco>
{}
{"indices":"*"}
{}
{}
` foi aceito
(200) e devolveu 3 respostas, a terceira com total `>= 10000` contra 3845 documentos do pattern, ou seja, leu fora do
pattern. Corrigido (linha em branco = 403 e NDJSON canônico); os mesmos payloads agora dão 403 `blank line not allowed`,
cobertos em `smoke-proxy.sh`.

## Resultado dos 4 riscos do ADR-0001

| Risco | Estado |
|---|---|
| `PUT` (criar índice) pelo proxy do datasource | **Fechado** (403): o método não está na allowlist (validação exata, sem heurística) |
| `DELETE` pelo proxy do datasource | **Fechado** (403): o método não está na allowlist (validação exata, sem heurística) |
| Listar/ler o OpenSearch inteiro (`_cat/indices`, `_search`, `_mapping` fora do pattern, também por `resources/`) | **Mitigado** (403 por rota e índice na allowlist); residual: o índice do `_msearch` depende da validação heurística do corpo |
| `index` no corpo do `/api/ds/query` lendo `gl-events_0` | **Mitigado, residual heurístico**: o plugin envia o índice no cabeçalho do `_msearch` e o proxy o recusa (Grafana devolve 400, "unexpected status code: 403"); chaves de corpo que leem outro índice só são barradas se conhecidas (ver riscos residuais) |

## Riscos residuais (medidos, sem maquiagem)

- **A validação do corpo é heurística, não prova**: cobre `index`/`indices` do cabeçalho e as chaves conhecidas que leem
  outro índice (`index`, `_index`, `indices`, `indexed_shape`, `wrapper`). Um recurso futuro do OpenSearch que leia outro índice por
  outra chave passaria. Testados e negados (403): terms lookup, lista mista, `indices`, `*`, `-exclusão` com índice proibido,
  cluster remoto e chave de cabeçalho desconhecida; chave duplicada é recusada pelo próprio OpenSearch.
- A defesa depende de o validador e o OpenSearch lerem o mesmo corpo: por isso o proxy encaminha só o NDJSON canônico e
  recusa linha em branco e argumentos de URL fora da lista (`source`/`source_content_type` passam um corpo pela URL). Divergência
  futura de parser (outra versão do OpenSearch) reabre o risco; o `smoke-proxy.sh` é o teste de regressão.
- Dentro do pattern o Viewer ainda lê **qualquer documento** dos index sets (consulta bruta; só os dashboards limitam a agregações).
- Consultas chegam ao OpenSearch sem autenticação: um Viewer pode fazer consultas pesadas dentro do pattern; há só limite de
  corpo e timeout (sem rate limit).
- **Rede**: o Grafana não compartilha mais a `logs-read`, mas o proxy sim; quem entrar na `logs-read` continua falando com o
  OpenSearch sem autenticação. `logs-ro` é `internal` e só tem Grafana e proxy.
- Um Admin do Grafana pode criar outro datasource, mas só `opensearch-ro` (mesmas regras) é alcançável; `opensearch` não tem rota.
- Index set novo no Graylog exige atualizar **dois** lugares: `database` do datasource e `PREFIXES` em `guard.js`.
- Imagem `nginx` + njs: atualizar por tag+digest e rodar `smoke-proxy.sh`.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Security plugin do OpenSearch + usuário somente leitura | Exige mudar `../graylog` e a integração do Graylog; fora do escopo local |
| Permissões por datasource do Grafana | Recurso Enterprise |
| Proxy sem inspeção de corpo (só método/caminho) | Deixaria o furo do `index` no cabeçalho do `_msearch` |
| OpenResty/Lua ou proxy próprio em Go | Mais uma imagem/código a manter; o njs já vem na imagem oficial do nginx |

## Consequências

- **Positivas**: Viewer sem escrita e sem leitura fora do pattern; Grafana sem rota ao OpenSearch; 1 container leve.
- **Negativas**: mais um serviço a manter; allowlist com duas listas de prefixos; novo ponto de falha para dashboards e
  alertas (`depends_on` com healthcheck; se o proxy cair, as regras de log entram em erro de avaliação).
- **Ações**: `smoke-test.sh` (parte 3) e `smoke-proxy.sh` assertam o bloqueio; README/CLAUDE.md atualizados.
