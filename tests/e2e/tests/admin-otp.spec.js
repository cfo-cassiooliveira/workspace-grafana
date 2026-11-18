// Cenário 7: o realm exige OTP para a role admin. O usuário descartável e2e.* (role admin, criado pela Admin API do
// Keycloak) não tem OTP: o login pede o cadastro do autenticador (required action nativa, fluxo suportado), o teste lê
// a chave manual exibida na tela e calcula o TOTP (RFC 6238). Nada é gravado por API de credenciais nem impresso.
const { test, expect } = require("@playwright/test");
const { credentials, totp, waitNextTotpWindow, openKeycloakForm, submitKeycloakCredentials, whoAmI } = require("../support/auth");

const afterLogin = (url) => url.origin === "http://localhost:3000" && url.pathname !== "/login";

test("realm admin only signs in with OTP and becomes org Admin (not Server Admin)", async ({ page }) => {
  test.setTimeout(180_000);
  const admin = credentials("ADMIN");

  // 1) Usuário e senha NÃO bastam: o Keycloak exige configurar/usar o OTP antes de voltar ao Grafana.
  await openKeycloakForm(page);
  await submitKeycloakCredentials(page, admin);
  await expect(page.locator("#totp")).toBeVisible();
  expect(page.url()).not.toContain("localhost:3000");
  expect((await page.request.get("http://localhost:3000/api/user")).status()).toBe(401);

  // 2) Cadastro do autenticador: lê a chave manual e confirma com o código calculado.
  await page.locator("#mode-manual").click();
  const secret = (await page.locator("#kc-totp-secret-key").innerText()).replace(/\s/g, "");
  expect(secret).toMatch(/^[A-Z2-7]{16,}$/);
  const firstCode = totp(secret);
  await page.locator("#totp").fill(firstCode);
  await page.locator("#userLabel").fill("e2e");
  await page.locator("#saveTOTPBtn").click();
  await page.waitForURL(afterLogin);
  expect(await whoAmI(page)).toMatchObject({ orgRole: "Admin", isGrafanaAdmin: false });

  // 3) Novo login (após logout completo): a senha passa, mas o OTP é exigido; código errado é recusado.
  await page.goto("/logout");
  await page.waitForURL(/localhost:(3000\/login|8180)/);
  const confirm = page.getByRole("button", { name: /Sair|Logout|Sign out/i });
  if (await confirm.isVisible().catch(() => false)) await confirm.click();
  await page.waitForURL(/localhost:3000\/login/);
  await openKeycloakForm(page);
  await submitKeycloakCredentials(page, admin);
  await expect(page.locator("#otp")).toBeVisible();
  await page.locator("#otp").fill("000000");
  await page.locator("#kc-login").click();
  await expect(page.locator("#otp")).toBeVisible();
  expect(page.url()).not.toContain("localhost:3000");

  // 4) Código correto de OUTRA janela (o Keycloak não aceita reutilizar o do cadastro) conclui o login.
  await waitNextTotpWindow(page);
  await page.locator("#otp").fill(totp(secret));
  await page.locator("#kc-login").click();
  await page.waitForURL(afterLogin);
  expect(await whoAmI(page)).toMatchObject({ orgRole: "Admin", isGrafanaAdmin: false });
  // Achado: o Admin da org lê /api/admin/settings (200, RBAC do Grafana 13). Garante ao menos que os segredos vêm mascarados
  // e que ele NÃO tem as ações exclusivas do Server Admin (listar todas as orgs/usuários do servidor).
  const settings = await page.request.get("/api/admin/settings");
  if (settings.status() === 200) {
    const body = await settings.json();
    const leaked = Object.entries(body).flatMap(([section, values]) =>
      Object.entries(values)
        .filter(([key, value]) => /secret|password|token|api_?key/i.test(key) && value !== "" && !/^\*+$/.test(String(value)))
        .map(([key]) => `${section}.${key}`),
    );
    expect(leaked, "segredos não mascarados em /api/admin/settings").toEqual([]);
  }
  expect((await page.request.get("/api/orgs")).status()).toBe(403);
});
