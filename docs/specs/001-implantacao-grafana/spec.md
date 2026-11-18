# Spec 001 — Implantação do Grafana OSS no Workspace

- **Status**: Proposta (aguarda aprovação e respostas da seção 8)
- **Data**: 2026-11-17
- **Projeto**: `C:\Workspace\grafana` (infraestrutura Docker, mesmo molde de `graylog` e `sonarqube`)

## 1. Problema e objetivo

Hoje cada ferramenta tem a sua UI (Graylog :9000, SonarQube :9001, Keycloak :8180) e **não existe visão
consolidada** da saúde e do comportamento dos projetos (`cadastro`, `legado`, `keycloak`, `sonarqube`, `graylog`).
Os dados já existem: todos os serviços enviam logs GELF ao Graylog (OpenSearch por baixo), o Keycloak expõe
métricas Prometheus em `:9000/metrics` e o SonarQube guarda o Quality Gate.

**Objetivo**: ter o Grafana OSS local em Docker, com login único (Keycloak), **100% configurado como código**
(datasources, pastas, dashboards e alertas versionados), mostrando dashboards iniciais por projeto sobre as fontes
que já existem, sem subir componentes novos além do Grafana no escopo mínimo.

### Métricas de sucesso

| Métrica | Meta |
|---|---|
| `docker compose up -d` + `scripts/smoke-test.sh` do zero | verde, sem passo manual na UI |
| Dashboards iniciais provisionados | 5 (Cadastro, Legado, Keycloak, SonarQube, Graylog/Plataforma), todos carregando dados reais |
| Login | 100% via Keycloak; nenhum acesso anônimo; acesso sem role Grafana negado |
| Logs do próprio Grafana | aparecem no Graylog (stream `Grafana - Infra`) com `service_name:grafana` |
| Segredos no repositório | 0 (verificado por teste) |

## 2. Perfis

| Perfil | Role Keycloak (realm `workspace`) | Role Grafana | Pode |
|---|---|---|---|
| Observador | `grafana-viewer` | Viewer | ver dashboards e alertas |
| Operador/Dev | `grafana-editor` | Editor | Viewer + Explore + editar dashboards **no navegador** (não persistem: RN-03) |
| Administrador | `admin` (já exige OTP) | Admin da org (não Server Admin) | tudo na org; datasources são somente leitura (provisionados) |
| Sem role | qualquer outro usuário do realm (ex.: usuário final do Cadastro) | nenhuma | **login negado** |
| Break-glass | conta local (`.env`) | Server Admin | só para recuperação se o Keycloak estiver fora |

## 3. Histórias e critérios de aceite

### H1 — Subir o Grafana pronto (infra como código)
```gherkin
Cenário: subida do zero
  Dado um host com Graylog, Keycloak e redes Docker prontos
  Quando executo ./scripts/generate-env.sh e docker compose up -d --build
  Então o Grafana fica healthy em http://localhost:3000
  E os datasources, pastas, dashboards e alertas existem sem intervenção na UI

Cenário: reaplicação idempotente
  Quando reinicio o container grafana
  Então nada é duplicado e o estado provisionado é o mesmo

Cenário: .env ausente
  Quando executo docker compose up sem .env
  Então o compose falha com a mensagem "defina <VAR> no .env"
```

### H2 — Login único via Keycloak
```gherkin
Cenário: usuário com role grafana-viewer
  Dado um usuário do realm workspace com a role grafana-viewer
  Quando ele acessa http://localhost:3000 e autentica no Keycloak (Authorization Code + PKCE)
  Então entra no Grafana com a role Viewer

Cenário: mapeamento de roles
  Dado usuários com grafana-editor e com admin
  Então entram como Editor e como Admin, respectivamente

Cenário: usuário sem role Grafana (ex.: usuário final do Cadastro)
  Quando ele conclui o login no Keycloak
  Então o Grafana nega o acesso (role_attribute_strict) e não cria o usuário

Cenário: acesso anônimo
  Quando acesso http://localhost:3000/api/dashboards/home sem sessão
  Então recebo 401 e a UI redireciona para o login

Cenário: Keycloak fora do ar
  Então o botão de SSO mostra erro tratável e o break-glass continua funcionando

Cenário: logout
  Quando saio do Grafana
  Então a sessão do Keycloak também é encerrada (RP-initiated logout)
```

### H3 — Dashboards iniciais por projeto
```gherkin
Cenário: dashboard do Cadastro
  Dado logs GELF com service_name "cadastro-api" e "cadastro-web" no Graylog
  Quando abro Cadastro > Visão geral
  Então vejo, no intervalo escolhido: volume por nível, taxa de erros (Error), 4xx/5xx do nginx,
       eventos de auditoria por tipo e latência quando o campo existir
  E nenhum painel exibe valor de campo pessoal (só agregações por nível/rota/evento)

Cenário: sem dados no período
  Então o painel mostra "Sem dados no período selecionado" (nunca gráfico quebrado)

Cenário: fonte indisponível
  Quando o OpenSearch do Graylog está fora
  Então o painel mostra o erro do datasource e o dashboard continua utilizável
```
Mesmo critério para Legado, Keycloak (eventos de login, falhas, migração `LEGACY_*` por `type`), SonarQube
(logs de infra e erros) e Graylog/Plataforma (ingestão por serviço, serviços sem log nos últimos N min).

### H4 — Alertas como código
```gherkin
Cenário: taxa de erro alta
  Dado uma regra "Cadastro - Taxa de erros" provisionada
  Quando há Error acima do limiar na janela definida
  Então a regra vai a Firing e aparece em Alertas, com link para o dashboard

Cenário: serviço mudo
  Quando um serviço deixa de enviar logs por N minutos
  Então a regra "Plataforma - Serviço sem logs" dispara
```
(Canal de notificação: ver P4.)

### H5 — Operação do próprio Grafana
```gherkin
Cenário: logs no Graylog
  Quando o Grafana loga em stdout (JSON)
  Então o evento chega ao Graylog com service_name "grafana" e nível correto

Cenário: backup e restauração
  Quando executo ./scripts/backup.sh e depois ./scripts/restore.sh em volume vazio
  Então o estado (usuários SSO, preferências, silences) é restaurado

Cenário: segredo vazado
  Quando varro o repositório
  Então não há senha, secret de client ou token
```

## 3b. Experiência do usuário

Não há telas próprias (a UI é a do Grafana). A UX é especificada nos **dashboards**:

- **Jornada**: Home → pasta do projeto → dashboard "Visão geral" → drill-down (Explore ou link ao Graylog filtrado).
- **4 estados** por painel: carregando (skeleton nativo), vazio ("Sem dados no período selecionado"), erro (mensagem
  do datasource) e sucesso. Painéis configuram *no value*; nunca "N/A" cru.
- **Variáveis** padrão: `environment`, `service_name`; intervalo padrão 6 h; atualização 1 min.
- **Idioma**: UI em pt-BR (`default_language`); títulos/descrições de dashboards, painéis e alertas em **PT-BR**
  (padrão `<Sistema> - <Assunto>`, como no Graylog); nomes de campos, queries e uids em inglês.
- **Cores/acessibilidade**: respeita tema claro/escuro; semáforo com paleta segura para daltonismo; unidades
  explícitas; thresholds com texto (não só cor). Legível em 1366x768 e utilizável em tablet; mobile só para consulta.
  Verificação visual com Playwright (desktop/tablet/mobile) conforme `frontend.md` §0.
- **Teclado/a11y**: o que é do Grafana segue o padrão dele; sem HTML customizado.

## 4. Regras de negócio

- **RN-01** Dados pessoais nunca aparecem: dashboards só com agregações; painel de logs brutos só em pasta de
  Editor+ (Explore também). O Graylog já mascara na gravação (ADR-0002/0003 do graylog).
- **RN-02** Toda configuração é versionada: datasources, dashboards e alertas só por arquivo.
- **RN-03** `allowUiUpdates: false`: edição na UI é rascunho; para persistir, exporta-se o JSON e abre-se PR.
- **RN-04** Acesso exige role Grafana explícita (negar por padrão).
- **RN-05** Nenhum projeto passa a depender do Grafana (ele observa; `cadastro`/`legado`/`keycloak` não o exigem).

## 5. Requisitos não funcionais

- **Segurança** (ASVS nível 2): SSO só Authorization Code + PKCE (sem Direct Grant/implícito); anônimo off; sign-up
  off; cookies `HttpOnly`/`SameSite=Lax` (`Secure` quando houver HTTPS); CSP ativada; sem telemetria; porta só em `127.0.0.1`.
- **LGPD**: contas de operadores (e-mail/login) ficam no Grafana; sem dado de usuário final; retenção dos logs = a
  do Graylog (o Grafana não copia logs).
- **Disponibilidade**: apoio local; `restart: unless-stopped`; health `/api/health`.
- **Performance**: dashboards abrem em < 3 s para 6 h de dados local; queries com agregações (`size: 0`).
- **Recursos**: ~300 MB de RAM no escopo mínimo.
- **Auditoria**: logs do Grafana (login, mudanças) vão ao Graylog; eventos de auth do Keycloak já existem.

## 6. Fora de escopo (v1)

Produção/HTTPS/proxy reverso; Loki, Tempo, OTel Collector; instrumentar os apps .NET com OpenTelemetry; Prometheus
(incremental, ver plan §2); datasources SQL (SQL Server do Legado, Postgres do Keycloak/SonarQube); plugins
Enterprise; notificações reais por e-mail/Slack (P4).

## 7. Premissas (decididas sem perguntar; padrão óbvio)

1. **Grafana OSS 13.3.1** (estável mais recente em 2026-11-17; linha anterior 12.4.x). Imagem `grafana/grafana-oss`
   por **tag + digest** (digest obtido na implementação, T02).
2. Porta `127.0.0.1:3000` (livre; em uso: 1433, 4200, 4300, 8025, 8180, 9000, 9001, 9100, 12201, 12202).
3. Banco do Grafana: **SQLite no volume** (instância única local); Postgres só se houver produção/HA (ADR-0001).
4. Redes: `observability` (GELF), `workspace-identity` (Keycloak) e nova `logs-read` (só Grafana + OpenSearch).
5. Break-glass: conta local com usuário não padrão e senha aleatória no `.env`; `admin/admin` não existe.
6. Realm `workspace` existente; client novo `grafana` (confidencial, PKCE S256), criado pelo provisionamento do `../keycloak`.
7. Projeto não analisado no SonarQube (só shell/JSON/YAML, como o `graylog`); revisar se virar necessidade.
8. Git: branch `DEV-001` a partir da `master` ao criar o repositório; commit só quando o desenvolvedor pedir.

## 8. Perguntas pendentes

Ver `plan.md` §10 (P1 fontes, P2 Prometheus, P3 ambiente alvo, P4 canal de alertas, P5 retenção, P6 logs brutos
para Viewer, P7 licença AGPL).
