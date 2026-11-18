// Cenários 4, 5 e 6: acesso anônimo, logout (Grafana e Keycloak) e limites de sessão (só a configuração).
const fs = require("node:fs");
const { test, expect } = require("@playwright/test");
const { ssoLogin, openKeycloakForm } = require("../support/auth");

const afterLogin = (url) => url.origin === "http://localhost:3000" && url.pathname !== "/login";

test("anonymous user is redirected to login and /api/* answers 401", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveURL(/\/login/);
  await expect(page.getByRole("link", { name: /Keycloak/i })).toBeVisible();

  for (const path of ["/api/dashboards/home", "/api/org", "/api/user", "/api/search", "/api/datasources", "/api/folders"]) {
    expect((await page.request.get(path)).status(), path).toBe(401);
  }
  // Sem sign-up e sem dashboard público/snapshot que contorne o login.
  expect((await page.request.get("/api/snapshots")).status()).toBe(401);
});

test("logout ends the Grafana and Keycloak sessions: a new visit asks for credentials", async ({ page }) => {
  await ssoLogin(page, "VIEWER");
  await page.waitForURL(afterLogin);
  expect((await page.request.get("/api/user")).status()).toBe(200);

  // Logout pela própria UI do Grafana (menu do perfil).
  await page.goto("/");
  await page.getByRole("button", { name: /Perfil|Profile/i }).click();
  await page.getByRole("menuitem", { name: /Finalizar sessão|Sign out/i }).click();
  // O Keycloak pode pedir confirmação do logout; depois volta ao /login do Grafana (post_logout_redirect_uri).
  const confirm = page.getByRole("button", { name: /Sair|Logout|Sign out/i });
  await Promise.race([
    page.waitForURL(/localhost:3000\/login/),
    confirm.waitFor({ state: "visible" }).then(() => confirm.click()),
  ]).catch(() => undefined);
  await page.waitForURL(/localhost:3000\/login/);

  expect((await page.request.get("/api/user")).status()).toBe(401);

  // Sessão do Keycloak encerrada: o SSO não loga sozinho, volta a pedir usuário e senha.
  await openKeycloakForm(page);
  await expect(page.locator("#username")).toBeVisible();
  await expect(page.locator("#password")).toBeVisible();
});

test("configured session limits: 8 h inactivity and 12 h absolute (ADR-0002)", async () => {
  // Só a configuração (sem esperar): o compose é montado somente leitura em /repo pelo scripts/e2e.sh.
  const compose = fs.readFileSync("/repo/docker-compose.yml", "utf8");
  expect(compose).toMatch(/GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION:\s*8h\b/);
  expect(compose).toMatch(/GF_AUTH_LOGIN_MAXIMUM_LIFETIME_DURATION:\s*12h\b/);
});

test("Grafana session cookie: HttpOnly, SameSite=Lax and lifetime within the 12 h absolute limit", async ({ page }) => {
  await ssoLogin(page, "VIEWER");
  await page.waitForURL(afterLogin);
  const cookies = await page.context().cookies();
  const session = cookies.find((cookie) => cookie.name === "grafana_session");
  expect(session, "cookie grafana_session").toBeDefined();
  expect(session.httpOnly).toBe(true);
  expect(session.sameSite).toBe("Lax");
  // O cookie não pode viver além do limite absoluto (12 h) a partir de agora; o limite de inatividade (8 h) é conferido só na configuração.
  const remainingHours = (session.expires - Date.now() / 1000) / 3600;
  console.log(`[sessão] validade restante do cookie: ${remainingHours.toFixed(2)} h`);
  expect(remainingHours).toBeGreaterThan(0);
  expect(remainingHours).toBeLessThanOrEqual(12.01);
});
