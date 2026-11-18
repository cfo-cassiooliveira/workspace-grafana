// Utilitários de autenticação do E2E: usuários descartáveis (entregues pelo scripts/e2e.sh por variável de ambiente),
// login real pelo formulário do Keycloak e cálculo de TOTP (RFC 6238) para o admin.
const crypto = require("node:crypto");

/** Credenciais do usuário descartável; falha cedo se o scripts/e2e.sh não as forneceu. */
function credentials(role) {
  const user = process.env[`E2E_${role}_USER`];
  const password = process.env[`E2E_${role}_PASSWORD`];
  if (!user || !password) {
    throw new Error(`Usuário E2E ${role} ausente: rode os testes pelo scripts/e2e.sh.`);
  }
  return { user, password };
}

/** Decodifica Base32 (RFC 4648) sem preenchimento. */
function base32Decode(text) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const char of text.replace(/[\s=]/g, "").toUpperCase()) {
    bits += alphabet.indexOf(char).toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) {
    bytes.push(parseInt(bits.slice(i, i + 8), 2));
  }
  return Buffer.from(bytes);
}

/** TOTP de 6 dígitos (HMAC-SHA1, 30 s), o padrão do Keycloak, para a janela de tempo informada. */
function totp(secret, atMs = Date.now()) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(atMs / 30_000)));
  const hmac = crypto.createHmac("sha1", base32Decode(secret)).update(counter).digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const code = (hmac.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
  return String(code).padStart(6, "0");
}

/** Espera a próxima janela de 30 s (o Keycloak recusa o mesmo código duas vezes). */
async function waitNextTotpWindow(page) {
  await page.waitForTimeout(30_000 - (Date.now() % 30_000) + 1_500);
}

/** Abre o login do Grafana e segue o botão do Keycloak até o formulário de usuário e senha. */
async function openKeycloakForm(page) {
  await page.goto("/login");
  await page.getByRole("link", { name: /Keycloak/i }).click();
  await page.locator("#username").waitFor();
}

/** Preenche usuário e senha no formulário do Keycloak e envia. */
async function submitKeycloakCredentials(page, { user, password }) {
  await page.locator("#username").fill(user);
  await page.locator("#password").fill(password);
  await page.locator("#kc-login").click();
}

/** Login (usuário e senha) de quem não precisa de OTP. */
async function ssoLogin(page, role) {
  await openKeycloakForm(page);
  await submitKeycloakCredentials(page, credentials(role));
}

/** Login e papel da sessão atual do navegador. */
async function whoAmI(page) {
  const user = await (await page.request.get("/api/user")).json();
  const orgs = await (await page.request.get("/api/user/orgs")).json();
  return { login: user.login, isGrafanaAdmin: user.isGrafanaAdmin, orgRole: orgs[0]?.role };
}

/** Erros conhecidos do Grafana OSS (user-storage 404, quotas 501, teams 403), sem relação com a nossa configuração. */
const KNOWN_NOISE = [/user-storage/i, /quotas/i, /\/api\/user\/teams/i, /\/api\/teams/i];

/** Registra erros de console, falhas de página e respostas 4xx/5xx que não são ruído conhecido. */
function watchProblems(page) {
  const problems = [];
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    const text = `${message.text()} ${message.location().url}`;
    if (!KNOWN_NOISE.some((re) => re.test(text)) && !/Failed to load resource/.test(message.text())) {
      problems.push(`console: ${message.text()}`);
    }
  });
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("response", (response) => {
    if (response.status() >= 400 && !KNOWN_NOISE.some((re) => re.test(response.url()))) {
      problems.push(`http ${response.status()}: ${new URL(response.url()).pathname}`);
    }
  });
  return problems;
}

module.exports = {
  credentials,
  totp,
  waitNextTotpWindow,
  openKeycloakForm,
  submitKeycloakCredentials,
  ssoLogin,
  whoAmI,
  watchProblems,
};
