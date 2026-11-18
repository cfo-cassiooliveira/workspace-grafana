// Guarda somente leitura do OpenSearch (ADR-0004). Decide por método + caminho + índices do corpo e só então
// encaminha ao upstream (location interna /_up). Qualquer coisa fora da allowlist vira 403 (negar por padrão).

// Prefixos dos index sets de aplicação do Graylog (mesma lista do datasource; o smoke-proxy confere a igualdade).
const PREFIXES = ['cadastro', 'legado', 'keycloak', 'sonarqube', 'grafana', 'graylog'];
const INDEX_TOKEN = new RegExp('^(' + PREFIXES.join('|') + ')_[a-z0-9_*.-]*$');
// Um padrão de índice na URL: tokens permitidos separados por vírgula.
const INDEX_LIST = /^[^/]+$/;

// Chaves permitidas na linha de cabeçalho (NDJSON) do _msearch.
const HEADER_KEYS = ['index', 'indices', 'search_type', 'ignore_unavailable', 'allow_no_indices',
  'expand_wildcards', 'preference', 'routing', 'request_cache'];
// Chaves de consulta que leem OUTRO índice a partir do corpo (terms lookup, more_like_this, geo_shape indexado).
// "wrapper" aceita uma query em base64 (esconderia qualquer uma das outras chaves da validação).
const CROSS_INDEX_KEYS = ['index', '_index', 'indices', 'indexed_shape', 'wrapper'];
// Argumentos de URL permitidos por operação (lista fechada: "source"/"source_content_type" mandariam um corpo
// arbitrário pela URL, fora da validação do NDJSON; "filter_path", "pretty" etc. também ficam de fora).
const ALLOWED_ARGS = {
  _msearch: ['search_type', 'max_concurrent_shard_requests', 'ignore_unavailable', 'allow_no_indices',
    'expand_wildcards', 'ignore_throttled', 'rest_total_hits_as_int', 'typed_keys'],
  _mapping: ['ignore_unavailable', 'allow_no_indices', 'expand_wildcards', 'local'],
  _field_caps: ['fields', 'ignore_unavailable', 'allow_no_indices', 'expand_wildcards', 'include_unmapped',
    'ignore_throttled']
};

function deny(r, reason) {
  r.headersOut['Content-Type'] = 'application/json';
  r.return(403, JSON.stringify({ error: 'forbidden by read-only proxy', reason: reason }));
}

function validIndexList(value) {
  if (typeof value === 'string') { value = value.split(','); }
  if (!Array.isArray(value) || value.length === 0) { return false; }
  return value.every(function (t) { return typeof t === 'string' && INDEX_TOKEN.test(t); });
}

function hasCrossIndexKey(node) {
  if (node === null || typeof node !== 'object') { return false; }
  if (Array.isArray(node)) { return node.some(hasCrossIndexKey); }
  return Object.keys(node).some(function (k) {
    return CROSS_INDEX_KEYS.indexOf(k) >= 0 || hasCrossIndexKey(node[k]);
  });
}

// Valida o NDJSON do _msearch: pares cabeçalho/corpo; todo cabeçalho resolve para índices permitidos.
// Linha em branco no meio é recusada (o OpenSearch a pareia de outro jeito que este validador). Devolve
// { reason } em caso de recusa ou { ndjson } canônico remontado do que foi validado: é ele que segue ao upstream.
function msearchCheck(text, urlIndex) {
  const lines = text.split('\n');
  if (lines.length > 0 && lines[lines.length - 1] === '') { lines.pop(); }
  if (lines.some(function (l) { return l.trim() === ''; })) { return { reason: 'blank line not allowed' }; }
  if (lines.length === 0 || lines.length % 2 !== 0) { return { reason: 'ndjson malformed' }; }
  const canonical = [];
  for (let i = 0; i < lines.length; i += 2) {
    let header, body;
    try { header = JSON.parse(lines[i]); body = JSON.parse(lines[i + 1]); } catch (e) { return { reason: 'ndjson malformed' }; }
    if (header === null || typeof header !== 'object' || Array.isArray(header)) { return { reason: 'header not an object' }; }
    const keys = Object.keys(header);
    for (let k = 0; k < keys.length; k++) {
      if (HEADER_KEYS.indexOf(keys[k]) < 0) { return { reason: 'header key not allowed: ' + keys[k] }; }
    }
    // O índice do cabeçalho substitui o da URL no OpenSearch; sem nenhum dos dois a busca seria em TODOS os índices.
    const target = header.index !== undefined ? header.index : (header.indices !== undefined ? header.indices : urlIndex);
    if (header.index !== undefined && header.indices !== undefined) { return { reason: 'index and indices together' }; }
    if (!validIndexList(target)) { return { reason: 'index outside the allowed pattern' }; }
    if (hasCrossIndexKey(body)) { return { reason: 'query references another index' }; }
    canonical.push(JSON.stringify(header), JSON.stringify(body));
  }
  return { ndjson: canonical.join('\n') + '\n' };
}

// Recusa argumento de URL fora da lista da operação (comparação exata sobre o nome já decodificado).
function argsAllowed(r, op) {
  return Object.keys(r.args).every(function (name) { return ALLOWED_ARGS[op].indexOf(name) >= 0; });
}

async function forward(r, method, body) {
  const reply = await r.subrequest('/_up' + r.uri, { method: method, args: r.variables.args || '', body: body });
  r.headersOut['Content-Type'] = reply.headersOut['Content-Type'] || 'application/json';
  r.return(reply.status, reply.responseBuffer);
}

async function route(r) {
  const method = r.method;
  const uri = r.uri;
  // Normalizado: sem "//", "." ou ".." (o nginx já resolve), e sem "%" restante após a decodificação.
  if (uri.indexOf('%') >= 0 || uri.indexOf('..') >= 0 || uri.indexOf('//') >= 0) { return deny(r, 'path not allowed'); }

  if (uri === '/' && (method === 'GET' || method === 'HEAD')) { return forward(r, method, undefined); }

  const m = uri.match(/^\/(?:([^/]+)\/)?(_msearch|_mapping|_field_caps)$/);
  if (m === null) { return deny(r, 'route not allowed'); }
  const index = m[1];
  const op = m[2];
  if (index !== undefined && (!INDEX_LIST.test(index) || !validIndexList(index))) { return deny(r, 'index outside the allowed pattern'); }

  if (!argsAllowed(r, op)) { return deny(r, 'argument not allowed'); }
  if (op === '_msearch') {
    if (method !== 'POST') { return deny(r, 'method not allowed'); }
    const check = msearchCheck(r.requestText || '', index);
    return check.reason === undefined ? forward(r, method, check.ndjson) : deny(r, check.reason);
  }
  // _mapping e _field_caps só leem; a URL precisa trazer o índice (sem ele seria "todos os índices").
  if (index === undefined) { return deny(r, 'index required'); }
  if (op === '_mapping' && method === 'GET') { return forward(r, method, undefined); }
  if (op === '_field_caps' && (method === 'GET' || method === 'POST')) {
    // POST de _field_caps aceita index_filter (uma query) no corpo: passa pela mesma checagem de índice cruzado.
    const text = r.requestText || '';
    if (text === '') { return forward(r, method, undefined); }
    let parsed;
    try { parsed = JSON.parse(text); } catch (e) { return deny(r, 'body malformed'); }
    if (hasCrossIndexKey(parsed)) { return deny(r, 'query references another index'); }
    return forward(r, method, JSON.stringify(parsed));
  }
  return deny(r, 'method not allowed');
}

export default { route };
