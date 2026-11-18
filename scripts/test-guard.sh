#!/usr/bin/env bash
# Testes unitários do opensearch-proxy/guard.js (ADR-0004) com node:test, sem instalar nada na máquina.
# Roda sempre na imagem do Playwright já pinada (tag + digest, a mesma do e2e.sh), que traz o Node: resultado
# igual em qualquer máquina. NODE_LOCAL=1 usa o Node local (mais rápido, só para desenvolvimento).
# Uso (na raiz do projeto): ./scripts/test-guard.sh
set -euo pipefail

PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v1.64.1-noble@sha256:2f05f8a734509a7b3f26a912639488ee08f58a7b292d14d62271bcff9038768f"
cd "$(dirname "$0")/.."

if [[ "${NODE_LOCAL:-}" == "1" ]]; then
  node --test tests/unit/
else
  host_dir="$(pwd -W 2>/dev/null || pwd)"
  MSYS_NO_PATHCONV=1 docker run --rm -v "${host_dir}:/repo:ro" -w /repo "$PLAYWRIGHT_IMAGE" node --test tests/unit/
fi
