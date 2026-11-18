// Testes unitários do guard.js (ADR-0004) com node:test. O guard exporta só `route`; as funções puras
// (validação do NDJSON, chaves proibidas, argumentos, tokens de índice) são exercitadas por ele com um `r` falso
// que imita o objeto de requisição do njs. Nenhuma dependência além do Node.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import guard from '../../opensearch-proxy/guard.js';

// Roda uma requisição pelo guard e devolve { status, body, forwarded } (forwarded = chamada ao upstream ou null).
async function call({ method = 'POST', uri, args = {}, body = '' }) {
  const out = { status: null, body: null, forwarded: null, headers: {} };
  const r = {
    method, uri, args, requestText: body, headersOut: out.headers, variables: { args: '' },
    return(status, payload) { out.status = status; out.body = payload; },
    async subrequest(path, opts) { out.forwarded = { path, ...opts }; return { status: 200, headersOut: {}, responseBuffer: 'upstream' }; }
  };
  await guard.route(r);
  return out;
}
const ndjson = (...objs) => objs.map((o) => JSON.stringify(o)).join('\n') + '\n';
const reasonOf = (res) => JSON.parse(res.body).reason;
const search = (header, body = { query: { match_all: {} } }, uri = '/_msearch') =>
  call({ uri, body: ndjson(header, body) });

test('msearch with an allowed index is forwarded as canonical NDJSON', async () => {
  const res = await search({ index: 'cadastro_*' });
  assert.equal(res.status, 200);
  assert.equal(res.forwarded.path, '/_up/_msearch');
  assert.equal(res.forwarded.body, ndjson({ index: 'cadastro_*' }, { query: { match_all: {} } }));
});

test('msearch takes the index from the URL when the header has none', async () => {
  const res = await search({}, undefined, '/legado_*/_msearch');
  assert.equal(res.status, 200);
});

test('msearch without any index (header or URL) is denied', async () => {
  const res = await search({});
  assert.equal(res.status, 403);
  assert.equal(reasonOf(res), 'index outside the allowed pattern');
});

test('index tokens outside the prefixes are denied', async () => {
  for (const idx of ['other_*', 'cadastro', '*', '_all', 'gl-events_1', 'cadastro_1,secret_1', '../cadastro_1']) {
    const res = await search({ index: idx });
    assert.equal(res.status, 403, idx);
  }
});

test('every configured prefix is accepted, list or array', async () => {
  for (const p of ['cadastro', 'legado', 'keycloak', 'sonarqube', 'grafana', 'graylog']) {
    assert.equal((await search({ index: `${p}_0` })).status, 200, p);
  }
  assert.equal((await search({ index: ['cadastro_1', 'legado_2'] })).status, 200);
  assert.equal((await search({ index: [] })).status, 403);
  assert.equal((await search({ index: [1] })).status, 403);
});

test('header with both index and indices is denied', async () => {
  const res = await search({ index: 'cadastro_1', indices: 'cadastro_2' });
  assert.equal(reasonOf(res), 'index and indices together');
});

test('header keys outside the allowlist are denied', async () => {
  const res = await search({ index: 'cadastro_1', script: 'x' });
  assert.equal(reasonOf(res), 'header key not allowed: script');
});

test('blank line in the middle of the NDJSON is denied, trailing newline is fine', async () => {
  const blank = await call({ uri: '/_msearch', body: '{"index":"cadastro_1"}\n\n{"query":{}}\n' });
  assert.equal(reasonOf(blank), 'blank line not allowed');
  const noTrailing = await call({ uri: '/_msearch', body: '{"index":"cadastro_1"}\n{"query":{}}' });
  assert.equal(noTrailing.status, 200);
});

test('malformed NDJSON (odd lines, bad JSON, empty, non-object header) is denied', async () => {
  const cases = [
    ['{"index":"cadastro_1"}\n', 'ndjson malformed'],
    ['{"index":"cadastro_1"}\n{oops}\n', 'ndjson malformed'],
    ['', 'ndjson malformed'],
    ['[1]\n{}\n', 'header not an object'],
    ['null\n{}\n', 'header not an object']
  ];
  for (const [body, reason] of cases) {
    assert.equal(reasonOf(await call({ uri: '/_msearch', body })), reason, body);
  }
});

test('query bodies that reference another index are denied at any depth', async () => {
  const bodies = [
    { query: { terms: { id: { index: 'secret', id: '1', path: 'x' } } } },
    { query: { bool: { must: [{ more_like_this: { like: [{ _index: 'secret', _id: '1' }] } }] } } },
    { query: { geo_shape: { f: { indexed_shape: { index: 'secret' } } } } },
    { query: { wrapper: { query: 'e30=' } } }
  ];
  for (const b of bodies) {
    assert.equal(reasonOf(await search({ index: 'cadastro_1' }, b)), 'query references another index', JSON.stringify(b));
  }
});

test('msearch only accepts POST and only allowed URL arguments', async () => {
  const body = ndjson({ index: 'cadastro_1' }, {});
  assert.equal(reasonOf(await call({ method: 'GET', uri: '/_msearch', body })), 'method not allowed');
  assert.equal((await call({ uri: '/_msearch', args: { search_type: 'query_then_fetch', typed_keys: 'true' }, body })).status, 200);
  for (const bad of ['source', 'source_content_type', 'filter_path', 'pretty']) {
    assert.equal(reasonOf(await call({ uri: '/_msearch', args: { [bad]: '1' }, body })), 'argument not allowed', bad);
  }
});

test('routes outside the allowlist are denied', async () => {
  for (const [method, uri] of [['GET', '/_cat/indices'], ['PUT', '/cadastro_1'], ['POST', '/cadastro_1/_search'],
    ['DELETE', '/cadastro_1'], ['POST', '/cadastro_1/_delete_by_query'], ['GET', '/_cluster/settings']]) {
    const res = await call({ method, uri });
    assert.equal(res.status, 403, `${method} ${uri}`);
    assert.equal(res.forwarded, null);
  }
});

test('paths with encoding, dot segments or double slash are denied', async () => {
  for (const uri of ['/cadastro_%2A/_mapping', '/cadastro_1/../_mapping', '//_msearch', '/cadastro_1//_mapping']) {
    assert.equal(reasonOf(await call({ method: 'GET', uri })), 'path not allowed', uri);
  }
});

test('root answers GET and HEAD only', async () => {
  assert.equal((await call({ method: 'GET', uri: '/' })).status, 200);
  assert.equal((await call({ method: 'HEAD', uri: '/' })).status, 200);
  assert.equal((await call({ method: 'POST', uri: '/' })).status, 403);
});

test('_mapping needs an allowed index in the URL and is read-only', async () => {
  assert.equal((await call({ method: 'GET', uri: '/cadastro_1/_mapping' })).status, 200);
  assert.equal(reasonOf(await call({ method: 'GET', uri: '/_mapping' })), 'index required');
  assert.equal(reasonOf(await call({ method: 'GET', uri: '/other_1/_mapping' })), 'index outside the allowed pattern');
  assert.equal(reasonOf(await call({ method: 'POST', uri: '/cadastro_1/_mapping' })), 'method not allowed');
  assert.equal(reasonOf(await call({ method: 'GET', uri: '/cadastro_1/_mapping', args: { pretty: 'true' } })), 'argument not allowed');
});

test('_field_caps accepts GET and POST, and checks the POST body for cross-index keys', async () => {
  assert.equal((await call({ method: 'GET', uri: '/cadastro_1/_field_caps', args: { fields: '*' } })).status, 200);
  assert.equal((await call({ method: 'POST', uri: '/cadastro_1/_field_caps' })).status, 200);
  assert.equal((await call({ method: 'POST', uri: '/cadastro_1/_field_caps', body: '{"index_filter":{"term":{"a":1}}}' })).status, 200);
  assert.equal(reasonOf(await call({ method: 'POST', uri: '/cadastro_1/_field_caps', body: '{oops' })), 'body malformed');
  assert.equal(reasonOf(await call({ method: 'POST', uri: '/cadastro_1/_field_caps',
    body: '{"index_filter":{"terms":{"a":{"index":"x"}}}}' })), 'query references another index');
  assert.equal(reasonOf(await call({ method: 'PUT', uri: '/cadastro_1/_field_caps' })), 'method not allowed');
});
