#!/usr/bin/env bash
# Restaura um backup do volume de dados do Grafana (T09). DESTRUTIVO: substitui todo o conteúdo atual do volume
# grafana_grafana-data (usuários, preferências, silences) pelo do arquivo. Por isso exige --yes.
# Só toca nesse volume (nome fixo); nunca em volumes de outros projetos. Proteções:
#   1) valida o arquivo antes de qualquer alteração: gzip íntegro, tar legível, sem caminhos absolutos/"..", só arquivos
#      regulares e diretórios (symlink, hardlink e dispositivos são recusados), e com grafana.db;
#   2) faz um backup automático do estado atual (.backups/, backup.sh) antes de apagar qualquer coisa;
#   3) extrai primeiro para um volume temporário: se a extração falhar (disco cheio, tar defeituoso) o volume real não é tocado;
#   4) só então troca o conteúdo; se a troca falhar, devolve o backup de segurança e sai com erro;
#   5) o Grafana é parado durante a restauração e reiniciado mesmo em caso de falha (se estava rodando);
#   6) os contêineres auxiliares rodam sem rede (--network none), sem privilégios e só com as capabilities necessárias.
# Se o volume não existir (ex.: após `docker compose down -v`), é criado com os rótulos do compose.
# Uso (na raiz do projeto): ./scripts/restore.sh --yes .backups/grafana-data-<UTC>.tar.gz
set -euo pipefail
exec < /dev/null

export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

VOLUME="grafana_grafana-data"
HELPER_IMAGE="alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"
# Auxiliar sem rede e sem privilégios; CHOWN/FOWNER/DAC_OVERRIDE bastam para preservar dono (uid 472) e apagar/copiar arquivos.
HELPER=(docker run --rm --network none --cap-drop ALL --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE
  --security-opt no-new-privileges)

confirmed=false
archive=""
for arg in "$@"; do
  case "$arg" in
    --yes) confirmed=true ;;
    -*) echo "Opção desconhecida: ${arg}" >&2; exit 2 ;;
    *) [[ -z "$archive" ]] || { echo "Informe um único arquivo de backup." >&2; exit 2; }; archive="$arg" ;;
  esac
done

if [[ -z "$archive" ]]; then
  echo "Uso: $0 --yes <arquivo.tar.gz>" >&2
  exit 2
fi
if [[ "$confirmed" != "true" ]]; then
  echo "Recusado: a restauração substitui o conteúdo atual do volume ${VOLUME}. Repita com --yes para confirmar." >&2
  exit 2
fi

# 1. Validação do arquivo antes de qualquer alteração.
[[ -f "$archive" ]] || { echo "Arquivo não encontrado: ${archive}" >&2; exit 2; }
gzip -t "$archive" 2> /dev/null || { echo "Arquivo inválido: não é um gzip íntegro." >&2; exit 2; }
entries="$(tar tzf "$archive" 2> /dev/null)" || { echo "Arquivo inválido: tar ilegível." >&2; exit 2; }
if grep -qE '^/|(^|/)\.\.(/|$)' <<< "$entries"; then
  echo "Arquivo recusado: contém caminhos absolutos ou '..'." >&2; exit 2
fi
# Listagem detalhada: o 1º caractere é o tipo ('-' arquivo, 'd' diretório, 'l' symlink, 'h' hardlink, 'c'/'b'/'p' dispositivos).
if tar tvzf "$archive" 2> /dev/null | grep -qvE '^[-d]'; then
  echo "Arquivo recusado: contém link simbólico, hardlink ou dispositivo (só arquivos e diretórios são aceitos)." >&2; exit 2
fi
grep -qE '^(\./)?grafana\.db$' <<< "$entries" || { echo "Arquivo recusado: não contém grafana.db." >&2; exit 2; }

was_running=false
if [[ -n "$(docker compose ps --status running -q grafana 2> /dev/null)" ]]; then was_running=true; fi
staging=""
stopped=false

cleanup() {
  local rc=$?
  if [[ -n "$staging" ]]; then docker volume rm -f "$staging" > /dev/null 2>&1 || true; fi
  # Reinicia o Grafana mesmo se a restauração falhar.
  if [[ "$was_running" == "true" && "$stopped" == "true" ]]; then docker compose start grafana > /dev/null 2>&1 || true; fi
  if [[ $rc -ne 0 ]]; then echo "Restauração NÃO concluída (código ${rc})." >&2; fi
}
trap cleanup EXIT

# Substitui o conteúdo de $VOLUME pelo do diretório /src de outro volume (cópia preservando dono e permissões).
replace_from_volume() { # replace_from_volume VOLUME_ORIGEM
  "${HELPER[@]}" -v "${1}:/src:ro" -v "${VOLUME}:/data" "$HELPER_IMAGE" \
    sh -c 'find /data -mindepth 1 -delete && cp -a /src/. /data/'
}
# Extrai o arquivo (pela entrada padrão) no volume informado, que deve estar vazio.
extract_into() { # extract_into VOLUME ARQUIVO
  "${HELPER[@]}" -i -v "${1}:/data" "$HELPER_IMAGE" tar xzf - -C /data < "$2"
}

if ! docker volume inspect "$VOLUME" > /dev/null 2>&1; then
  docker volume create \
    --label com.docker.compose.project=grafana --label com.docker.compose.volume=grafana-data "$VOLUME" > /dev/null
fi

# 2. Backup de segurança do estado atual (se houver banco), sem rotação para não apagar o arquivo a restaurar.
safety=""
if "${HELPER[@]}" -v "${VOLUME}:/data:ro" "$HELPER_IMAGE" test -f /data/grafana.db > /dev/null 2>&1; then
  safety_out="$(BACKUP_SKIP_ROTATION=1 ./scripts/backup.sh)" || { echo "Backup de segurança falhou: restauração abortada (nada foi alterado)." >&2; exit 1; }
  safety="$(sed -n 's/^Backup criado: \(.*\) ([0-9]* bytes).*/\1/p' <<< "$safety_out")"
  [[ -f "$safety" ]] || { echo "Backup de segurança não localizado: restauração abortada (nada foi alterado)." >&2; exit 1; }
  echo "Backup de segurança do estado atual: ${safety}"
fi

if [[ "$was_running" == "true" ]]; then docker compose stop grafana > /dev/null; stopped=true; fi

# 3. Extrai para um volume temporário: falha aqui não toca o volume real.
staging="grafana_restore_staging_$$"
docker volume create "$staging" > /dev/null
extract_into "$staging" "$archive" || { echo "Falha ao extrair o arquivo (volume ${VOLUME} intacto)." >&2; exit 1; }

# 4. Troca o conteúdo; se falhar no meio, devolve o estado anterior pelo backup de segurança.
if ! replace_from_volume "$staging"; then
  echo "Falha ao substituir o conteúdo do volume ${VOLUME}." >&2
  if [[ -n "$safety" ]]; then
    "${HELPER[@]}" -v "${VOLUME}:/data" "$HELPER_IMAGE" find /data -mindepth 1 -delete > /dev/null 2>&1 || true
    if extract_into "$VOLUME" "$safety"; then echo "Estado anterior devolvido a partir de ${safety}." >&2
    else echo "ATENÇÃO: não foi possível devolver o estado anterior; restaure manualmente de ${safety}." >&2; fi
  fi
  exit 1
fi

echo "Restauração concluída em ${VOLUME} a partir de ${archive}."
