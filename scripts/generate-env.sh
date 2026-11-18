#!/usr/bin/env bash
# Gera o .env local com segredos aleatórios (nunca versionado). Não sobrescreve um .env existente.
# Uso: ./scripts/generate-env.sh   (informa onde está a senha do break-glass, sem imprimi-la)
set -euo pipefail

cd "$(dirname "$0")/.."

# Segredo do client "grafana" gerado pelo keycloak; copiado sem exibir (nem no argv). Vazio se ainda não existir.
read_keycloak_secret() {
  local file="../keycloak/.env"
  [[ -f "$file" ]] || return 0
  { grep -m1 '^KC_GRAFANA_CLIENT_SECRET=' "$file" || true; } | cut -d= -f2- | tr -d '\r'
}

if [[ -f .env ]]; then
  # Não sobrescreve o .env, mas completa o segredo do SSO se ele ainda faltar (ex.: .env anterior ao T06).
  if ! grep -q '^KC_GRAFANA_CLIENT_SECRET=.' .env; then
    secret="$(read_keycloak_secret)"
    if [[ -n "$secret" ]]; then
      printf '\n# Segredo do client "grafana" do Keycloak (copiado de ../keycloak/.env).\nKC_GRAFANA_CLIENT_SECRET=%s\n' "$secret" >> .env
      echo ".env já existia; KC_GRAFANA_CLIENT_SECRET copiado de ../keycloak/.env (valor não exibido)."
    else
      echo ".env já existe, mas KC_GRAFANA_CLIENT_SECRET falta e ../keycloak/.env não o tem: rode o generate-env.sh do keycloak antes."
    fi
  else
    echo ".env já existe; nada foi alterado. Apague-o para gerar novos segredos."
  fi
  exit 0
fi

# Aleatório alfanumérico de tamanho fixo (base64 pode render menos que o pedido: gera de sobra).
random() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# Usuário do break-glass com sufixo aleatório: nunca "admin" (Art. IV; ADR-0002 item 4).
admin_user="bg-$(openssl rand -hex 3)"

umask 077
cat > .env <<ENVFILE
# Gerado por scripts/generate-env.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ). NUNCA versione este arquivo.
# Conta local de recuperação (break-glass), usada só se o Keycloak estiver fora do ar.
GRAFANA_ADMIN_USER=${admin_user}
GRAFANA_ADMIN_PASSWORD=$(random 32)
# Chave de assinatura/cifra de segredos do Grafana (datasources, sessões). Trocá-la invalida segredos salvos.
GF_SECURITY_SECRET_KEY=$(random 48)
ENVFILE
# Segredo do SSO (client "grafana" do Keycloak), copiado sem exibir; ausente se o keycloak ainda não gerou o seu .env.
secret="$(read_keycloak_secret)"
if [[ -n "$secret" ]]; then
  printf '# Segredo do client "grafana" do Keycloak (copiado de ../keycloak/.env).\nKC_GRAFANA_CLIENT_SECRET=%s\n' "$secret" >> .env
else
  echo "AVISO: ../keycloak/.env não tem KC_GRAFANA_CLIENT_SECRET; rode o generate-env.sh do keycloak e depois este de novo."
fi
chmod 600 .env

echo ".env criado (0600). Usuário break-glass e senha: GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD no .env."
