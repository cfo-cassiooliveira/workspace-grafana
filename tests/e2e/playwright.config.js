// E2E do Grafana (SSO Keycloak e hardening). Roda contra o docker compose (Grafana em localhost:3000), pelo scripts/e2e.sh.
const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests",
  globalSetup: require.resolve("./global-setup.js"),
  fullyParallel: false,
  // Um worker: cada teste abre sessões reais no Keycloak e no Grafana; o TOTP do admin exige tempo entre os códigos.
  workers: 1,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  forbidOnly: true,
  retries: 0,
  reporter: [["list"]],
  outputDir: "./.artifacts/test-results",
  use: {
    baseURL: process.env.E2E_BASE_URL || "http://localhost:3000",
    locale: "pt-BR",
    trace: "retain-on-failure",
    ...devices["Desktop Chrome"],
  },
});
