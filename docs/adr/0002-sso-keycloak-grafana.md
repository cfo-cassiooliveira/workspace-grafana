# ADR-0002: SSO do Grafana via Keycloak (OIDC, Authorization Code + PKCE) com roles do realm

- **Status**: Aceito (aceito pelo responsável técnico em 2026-11-17)
- **Data**: 2026-11-17
- **Decisores**: responsável técnico (aceito em 2026-11-17, com a aprovação das recomendações padrão P1-P8 do plano; P8: `admin` do realm = Admin do Grafana)
- **Artigos da Constituição relacionados**: Art. IV.2, IV.3, IV.4

## Contexto

A Constituição exige autenticação exclusiva via Keycloak (OIDC), sem fluxo implícito nem Direct Grant. O realm `workspace`
também contém usuários finais do Cadastro, que não podem acessar o Grafana. O Keycloak usa `KC_HOSTNAME=http://localhost:8180`
com back-channel dinâmico.

## Decisão

1. Client confidencial `grafana` no realm `workspace`, criado em `../keycloak` (realm JSON + `provision.sh`, padrão do
   client `cadastro`): Authorization Code com **PKCE S256**, `directAccessGrantsEnabled=false`, implícito off, redirect
   `http://localhost:3000/login/generic_oauth`, `fullScopeAllowed=false`.
2. Provider `auth.generic_oauth` do Grafana: `auth_url` no host público; `token_url`/`api_url` em `http://keycloak:8080`
   (rede `workspace-identity`). Segredo do client só no `.env`.
3. Roles de realm: **novas** `grafana-viewer` e `grafana-editor`; **existente** `admin` (OTP já obrigatório) -> Admin.
   Mapper de realm roles para o claim `roles`; `role_attribute_path` mapeia para Viewer/Editor/Admin;
   `role_attribute_strict=true` (sem role = login negado); `allow_assign_grafana_admin=false`.
4. Conta break-glass local (usuário não padrão, senha aleatória no `.env`) para falha do Keycloak; `admin/admin` inexistente.
5. Logout encerra a sessão no Keycloak (`signout_redirect_url`).

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Grupos do Keycloak em vez de roles | Escala melhor | Realm hoje não usa grupos | Consistência com `admin`/`log-investigator` |
| Reusar a role `admin` para tudo | Zero mudança | Sem granularidade | Viewer/Editor necessários |
| Proxy auth / SAML | — | Fora do padrão OIDC | Constituição |
| Login local do Grafana | Simples | Viola Art. IV.2 | Só break-glass |

## Consequências

- **Positivas**: um login, papéis auditáveis, revogação central.
- **Negativas / riscos**: mudança no `../keycloak` (aditiva, sem quebra de contrato); HTTP local sem `Secure` no cookie (HTTPS em produção).
- **Sintaxe confirmada (T06)**: `role_attribute_path` é JMESPath na 13.x (a dúvida JMESPath vs CEL está resolvida).
- **Limites de sessão (2026-11-17)**: a revogação central só vale quando o Grafana reautentica no Keycloak; os padrões do
  Grafana (7 dias de inatividade, 30 dias absolutos) deixariam uma role revogada ou alterada valendo por semanas. Decisão:
  `GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION=8h` e `GF_AUTH_LOGIN_MAXIMUM_LIFETIME_DURATION=12h` (chaves `[auth]`
  `login_maximum_inactive_lifetime_duration` e `login_maximum_lifetime_duration`, validadas no `defaults.ini` da 13.3.1), de
  modo que revogação/mudança de role tenha efeito em até 12 h. Alternativa não adotada: `use_refresh_token` + `offline_access`
  (o Grafana renovaria o token no Keycloak e derrubaria a sessão ao revogar, mais rápido, porém com mais partes móveis e
  tokens offline de longa duração). Custo: o operador reautentica a cada 12 h (silencioso enquanto a sessão do Keycloak vive).
  O smoke (parte 2) confere as duas variáveis no container.
- **Ações decorrentes**: T04 e T06; teste E2E negativo (T15).
