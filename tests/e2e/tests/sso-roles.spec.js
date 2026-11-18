// Cenários 1, 2 e 3: cada role do realm entra (ou é negada) pelo login real no Keycloak, com o efeito visível na UI.
const { test, expect } = require("@playwright/test");
const { ssoLogin, whoAmI, watchProblems } = require("../support/auth");

const ORIGIN = { Origin: "http://localhost:3000" };
const afterLogin = (url) => url.origin === "http://localhost:3000" && url.pathname !== "/login";
const newDatasource = { name: "e2e-ds", type: "prometheus", url: "http://example.invalid", access: "proxy" };

/** A rota é barrada: o Grafana redireciona para o início (ou mostra acesso negado); a tela da rota não abre. */
async function expectBlocked(page, route) {
  await page.goto(route);
  await expect.poll(() => new URL(page.url()).pathname, { message: `rota ${route} deveria ser barrada` }).not.toBe(route);
}

test("viewer signs in as Viewer: no Explore, no data sources and no dashboard creation", async ({ page }) => {
  await ssoLogin(page, "VIEWER");
  await page.waitForURL(afterLogin);

  expect(await whoAmI(page)).toMatchObject({ orgRole: "Viewer", isGrafanaAdmin: false });

  // UI: o menu não oferece Explore nem Conexões, e as rotas respondem acesso negado.
  await page.goto("/dashboards");
  await expect(page.locator("#pageContent")).toBeVisible();
  await expect(page.locator('a[href^="/explore"]')).toHaveCount(0);
  await expect(page.locator('a[href^="/connections"]')).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^(Novo|New)$/ })).toHaveCount(0);
  for (const route of ["/explore", "/connections/datasources", "/dashboard/new"]) {
    await expectBlocked(page, route);
  }

  // API: gravar dashboard e criar data source são 403 (Origin é exigido pelo Grafana em métodos não seguros).
  const write = await page.request.post("/api/dashboards/db", {
    headers: ORIGIN,
    data: { dashboard: { title: "e2e-viewer-write" }, overwrite: false },
  });
  expect(write.status()).toBe(403);
  expect((await page.request.post("/api/datasources", { headers: ORIGIN, data: newDatasource })).status()).toBe(403);
});

test("editor signs in as Editor, uses Explore, is not Admin and cannot overwrite a provisioned dashboard", async ({ page }) => {
  await ssoLogin(page, "EDITOR");
  await page.waitForURL(afterLogin);

  expect(await whoAmI(page)).toMatchObject({ orgRole: "Editor", isGrafanaAdmin: false });

  // Pode: Explore abre.
  await page.goto("/explore");
  await expect(page.locator("#pageContent")).toBeVisible();
  expect(new URL(page.url()).pathname).toBe("/explore");

  // Não é Admin: administração do servidor, usuários e criação de data source são recusados.
  expect((await page.request.get("/api/admin/settings")).status()).toBe(403);
  expect((await page.request.get("/api/users")).status()).toBe(403);
  expect((await page.request.post("/api/datasources", { headers: ORIGIN, data: newDatasource })).status()).toBe(403);
  await expectBlocked(page, "/admin/users");

  // Dashboard provisionado (editable:false): a API o marca como provisionado e sobrescrevê-lo é recusado.
  const found = await (await page.request.get("/api/search?type=dash-db&limit=1")).json();
  expect(found.length).toBeGreaterThan(0);
  const loaded = await (await page.request.get(`/api/dashboards/uid/${found[0].uid}`)).json();
  expect(loaded.meta.provisioned).toBe(true);
  const overwrite = await page.request.post("/api/dashboards/db", {
    headers: ORIGIN,
    data: { dashboard: loaded.dashboard, overwrite: true, folderUid: loaded.meta.folderUid },
  });
  expect([400, 403, 412]).toContain(overwrite.status());
  expect(JSON.stringify(await overwrite.json())).toMatch(/provision/i);
});

for (const [role, label] of [
  ["NOROLE", "user without a grafana-* role"],
  ["ENDUSER", "Cadastro end user (role user)"],
]) {
  test(`${label} is denied, with an on-screen error and no Grafana session`, async ({ page }) => {
    await ssoLogin(page, role);
    // O Grafana devolve ao /login com um alerta de erro (não entra e não cria o usuário).
    await page.waitForURL((url) => url.origin === "http://localhost:3000");
    await expect(page.getByRole("alert")).toBeVisible();
    expect((await page.request.get("/api/user")).status()).toBe(401);
  });
}

// DEFEITO CONHECIDO (relatado ao desenvolvedor): a mensagem do Grafana para "sem role" vem em inglês e técnica
// ("IdP did not return a role attribute..."), e o spec pede mensagem adequada em PT-BR. test.fail() mantém a suíte
// verde enquanto o defeito existir e VIRA ERRO quando for corrigido (então remova o test.fail).
test("user without a role sees a PT-BR denial message, without technical jargon", async ({ page }) => {
  test.fail(true, "mensagem do Grafana em inglês/técnica (role_attribute_strict)");
  await ssoLogin(page, "NOROLE");
  await page.waitForURL((url) => url.origin === "http://localhost:3000");
  const message = (await page.getByRole("alert").innerText()).trim();
  console.log(`[NOROLE] mensagem de acesso negado: ${message.replace(/\s+/g, " ")}`);
  expect(message).toMatch(/permiss|acesso|autoriz/i);
  expect(message).not.toMatch(/IdP|attribute|administrator/i);
});

test("authenticated UI loads and the panel shows error/empty without breaking the page, with OpenSearch down", async ({ page }) => {
  const problems = watchProblems(page);
  await ssoLogin(page, "VIEWER");
  await page.waitForURL(afterLogin);
  const found = await (await page.request.get("/api/search?type=dash-db&limit=1")).json();
  await page.goto(`/d/${found[0].uid}`);
  await expect(page.getByText(found[0].title).first()).toBeVisible();
  await page.waitForTimeout(5_000);
  await expect(page.getByText(/Application error|Algo deu errado|Something went wrong/i)).toHaveCount(0);
  await page.screenshot({ path: ".artifacts/dashboard-opensearch-down.png", fullPage: true });
  console.log(`[dashboard] problemas observados: ${JSON.stringify([...new Set(problems)])}`);
  // Erros de datasource (OpenSearch fora) são esperados; exceção JS não tratada reprova.
  expect(problems.filter((p) => p.startsWith("pageerror"))).toEqual([]);
});
