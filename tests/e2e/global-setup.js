// Dentro do container do Playwright, "localhost" é o próprio container. Quando E2E_FORWARD_HOST está definido
// (scripts/e2e.sh no Docker Desktop), este setup encaminha localhost:<porta> para o host, preservando o hostname
// "localhost": é o hostname público do Grafana (root_url, redirect_uri) e do Keycloak (issuer e cookies do login).
const net = require("node:net");

// 3000: Grafana. 8180: Keycloak.
const FORWARDED_PORTS = [3000, 8180];

module.exports = async () => {
  const targetHost = process.env.E2E_FORWARD_HOST;
  if (!targetHost) {
    return undefined;
  }

  const servers = await Promise.all(
    FORWARDED_PORTS.map(
      (port) =>
        new Promise((resolve, reject) => {
          const server = net.createServer((client) => {
            const upstream = net.connect(port, targetHost);
            client.pipe(upstream).pipe(client);
            // Conexão encerrada de um lado fecha a outra; erros de rede só derrubam o par afetado.
            client.on("error", () => upstream.destroy());
            upstream.on("error", () => client.destroy());
          });
          server.once("error", reject);
          server.listen(port, "127.0.0.1", () => resolve(server));
        }),
    ),
  );

  return async () => Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve))));
};
