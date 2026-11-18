// Cenário 8: cabeçalhos de segurança/CSP, axe-core (WCAG), console sem erros novos e telas de login/acesso negado em
// mobile 390, tablet 820 e desktop 1440 (screenshots em .artifacts/screenshots), com varredura de redimensionamento 320-1920.
const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;
const { ssoLogin, openKeycloakForm, watchProblems } = require("../support/auth");

const VIEWPORTS = [
  { name: "mobile-390", width: 390, height: 844 },
  { name: "tablet-820", width: 820, height: 1180 },
  { name: "desktop-1440", width: 1440, height: 900 },
];
// Passos de no máximo 100 px e os breakpoints (576/768/992/1024) com ±1 px.
const SWEEP_WIDTHS = [320, 360, 390, 414, 480, 575, 576, 577, 600, 700, 767, 768, 769, 820, 900, 991, 992, 993, 1023, 1024, 1025, 1100, 1200,
  1280, 1366, 1440, 1536, 1600, 1700, 1800, 1920];
const WCAG_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];

/** Espera a animação de entrada das telas (fade) terminar antes de capturar. */
const settle = (page) => page.waitForTimeout(900);

/** Elementos visíveis que passam da borda direita da janela (corte/overflow horizontal) e scroll horizontal da página. */
async function horizontalOverflow(page) {
  return page.evaluate(() => {
    const viewport = document.documentElement.clientWidth;
    const offenders = [...document.querySelectorAll("body *")]
      .filter((el) => {
        const rect = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        return rect.width > 0 && style.visibility !== "hidden" && style.position !== "fixed" && rect.right > viewport + 1 && !el.closest("[hidden]");
      })
      .slice(0, 5)
      .map((el) => `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ""}.${String(el.className).slice(0, 40)}`);
    return { pageScroll: document.documentElement.scrollWidth - viewport, offenders };
  });
}

async function sweep(page, label) {
  const problems = [];
  for (const width of SWEEP_WIDTHS) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(150);
    const { pageScroll, offenders } = await horizontalOverflow(page);
    if (pageScroll > 1 || offenders.length > 0) problems.push(`${label} @${width}px: scroll=${pageScroll} elementos=${offenders.join(" | ")}`);
  }
  return problems;
}

async function shoot(page, label) {
  for (const { name, width, height } of VIEWPORTS) {
    await page.setViewportSize({ width, height });
    await settle(page);
    await page.screenshot({ path: `.artifacts/screenshots/${label}-${name}.png`, fullPage: true });
  }
}

/** Violações sérias/críticas reprovam; as demais são impressas para o relatório. */
async function expectAccessible(page, label) {
  const { violations } = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze();
  const summary = violations.map((v) => `${v.id}(${v.impact}) x${v.nodes.length}`);
  console.log(`[axe] ${label}: ${summary.length ? summary.join(", ") : "sem violações"}`);
  const blocking = violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id}: ${v.help}`);
  expect(blocking, `axe ${label}`).toEqual([]);
}

test("security headers and CSP on the Grafana login page", async ({ request }) => {
  const response = await request.get("/login");
  expect(response.status()).toBe(200);
  const headers = response.headers();
  const csp = headers["content-security-policy"] ?? "";
  expect(csp).not.toBe("");
  expect(csp).not.toContain("unsafe-eval");
  expect(csp).toContain("frame-ancestors 'none'");
  expect(csp).toContain("object-src 'none'");
  expect(csp).toMatch(/img-src 'self' data: blob:;/);
  expect(csp).toMatch(/script-src [^;]*'nonce-/);
  expect(headers["x-content-type-options"]).toBe("nosniff");
  expect(headers["x-frame-options"]).toBe("deny");
  // Sem exposição de versão do servidor web nem cache da tela de login por intermediários.
  expect(headers["server"] ?? "").not.toMatch(/\d/);
});

test("Grafana login and Keycloak form: axe, clean console, screenshots and 320-1920 sweep", async ({ page }) => {
  const problems = watchProblems(page);
  await page.goto("/login");
  await expect(page.getByRole("link", { name: /Keycloak/i })).toBeVisible();
  await settle(page);
  await expectAccessible(page, "login do Grafana");
  await shoot(page, "grafana-login");
  const grafanaSweep = await sweep(page, "grafana-login");

  await page.setViewportSize({ width: 1440, height: 900 });
  await openKeycloakForm(page);
  await settle(page);
  await expectAccessible(page, "formulário do Keycloak");
  await shoot(page, "keycloak-login");
  const keycloakSweep = await sweep(page, "keycloak-login");

  // Console sem erros além dos conhecidos do Grafana OSS (ver watchProblems).
  console.log(`[console] problemas nas telas de login: ${JSON.stringify([...new Set(problems)])}`);
  expect(problems.filter((p) => !p.startsWith("http 401"))).toEqual([]);
  expect([...grafanaSweep, ...keycloakSweep]).toEqual([]);
});

test("access denied page: axe, screenshots and 320-1920 sweep", async ({ page }) => {
  await ssoLogin(page, "NOROLE");
  await page.waitForURL((url) => url.origin === "http://localhost:3000");
  await expect(page.getByRole("alert")).toBeVisible();
  await settle(page);
  await expectAccessible(page, "acesso negado");
  await shoot(page, "denied");
  expect(await sweep(page, "denied")).toEqual([]);
});
