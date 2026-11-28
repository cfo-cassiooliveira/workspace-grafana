# Regras do lint de dashboards (usado por lint-dashboards.sh). Uma linha por violação: "<arquivo>\t[regra] mensagem".
# A linha "<arquivo>\tuid=<valor>" alimenta a checagem de unicidade no shell.
# Por que existe: impede que um painel com documento bruto ou campo pessoal entre pelo PR sem ninguém notar.
# Limite: é revisão automática dos arquivos por nome de campo, não controle de acesso aos dados.
def lgpd: "(^|[^a-z0-9])(cpf|cnpj|e-?mail|masked_login|phone|celular|telefone|user_?name|user_?id|preferred_username|mobile_?phone|(remote|client)_?ip|gl2_remote_ip|nome|full_message|remote_addr)([^a-z0-9]|$)";
# "ip" sozinho como campo (sem pegar probe_ip_addr_hash, métrica de DNS do blackbox): "_" conta como parte do nome.
def lgpd_ip: "(^|[^a-z0-9_])ip([^a-z0-9_]|$)";
def query_strings:
  [ (.. | objects | select(has("targets")) | .targets[]? | .. | strings),
    ((.templating // {}) | .. | strings), ((.annotations // {}) | .. | strings) ];
def targets_list: [ .. | objects | select(has("targets")) | .targets[]? | objects ];
def datasources: [ .. | objects | select(has("datasource")) | .datasource ];
input_filename as $f
| (
  ( if ((.uid | type) != "string") or (((.uid // "") | test("^[a-z0-9]+(-[a-z0-9]+)*$")) | not)
      then "[uid-format] uid ausente ou fora de kebab-case minúsculo" else empty end ),
  ( if has("id") and .id != null then "[id-present] o campo \"id\" deve ser removido (o Grafana o atribui)" else empty end ),
  ( if (.schemaVersion | type) != "number" or .schemaVersion < 39
      then "[schema-version] schemaVersion ausente ou < 39 (exporte da própria 13.x)" else empty end ),
  ( if .editable != false then "[editable] editable deve ser false" else empty end ),
  ( if ((.title | type) != "string") or (((.title // "") | test("^[^ ].* - [^ ].*$")) | not)
      then "[title] título fora do padrão \"<Sistema> - <Assunto>\""
    elif (.title | test("(^|[^A-Za-z])(Overview|Dashboard|Errors|Authentication|Platform|Failures)([^A-Za-z]|$)"))
      then "[title] título deve estar em PT-BR" else empty end ),
  ( datasources[]
    | select((type != "object") or ((.uid // "") as $u | ($allowed | index($u)) == null and $u != "-- Grafana --" and $u != "grafana"))
    | "[datasource] datasource deve ser objeto com uid provisionado: \(tostring)" ),
  ( if ([.. | objects | select(.type? == "logs")] | length) > 0
      then "[panel-logs] painel do tipo logs é proibido (Viewer só vê agregações)" else empty end ),
  ( targets_list[] | .metrics[]? | objects | select((.type // "") | IN("raw_data", "raw_document", "logs"))
    | "[raw-metric] métrica (.type) devolve documentos brutos (só agregações são permitidas)" ),
  ( targets_list[] | select(has("queryType") and .queryType != "lucene")
    | "[query-type] queryType \"(.queryType)\" não é permitido (só lucene com agregações; PPL/lucene-raw leem documentos)" ),
  ( query_strings | map(select(test(lgpd; "i") or test(lgpd_ip; "i"))) | unique[] | "[lgpd-field] consulta referencia campo pessoal: \(.)" ),
  "uid=\(.uid // "")"
) | "\($f)\t\(.)"
