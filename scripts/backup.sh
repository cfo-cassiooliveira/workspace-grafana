#!/usr/bin/env bash
# Backup do volume de dados do Grafana (T09): tudo o que o Grafana guarda em /var/lib/grafana (SQLite com usuários SSO,
# preferências, silences e anotações; o plugin NÃO está no volume, vem da imagem). Gera .backups/grafana-data-<UTC>.tar.gz
# com permissão 0600 e apaga backups com mais de 30 dias (mesma retenção do Graylog).
#
# Consistência: o Grafana é PARADO por alguns segundos durante a cópia (e reiniciado se estava rodando). Escolhido em vez
# de `sqlite3 .backup` porque a imagem não traz o binário sqlite3 e a parada garante um instantâneo coerente do banco
# (WAL incluído) e dos demais arquivos do volume, sem instalar nada. O arquivo não contém segredos do .env, mas contém
# contas e preferências: por isso 0600 e fora do git (.backups/ no .gitignore).
# Frequência recomendada: diária (agendador do SO) e antes de atualizar a versão do Grafana. Restauração: restore.sh.
# Uso (na raiz do projeto): ./scripts/backup.sh
set -euo pipefail
exec < /dev/null

# Evita a conversão de caminhos do Git Bash em volumes/-C do docker.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

VOLUME="grafana_grafana-data"          # projeto compose "grafana" + volume "grafana-data"; nunca outro volume
HELPER_IMAGE="alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"
BACKUP_DIR=".backups"
RETENTION_DAYS=30

docker volume inspect "$VOLUME" > /dev/null 2>&1 || { echo "Volume ${VOLUME} não existe; nada a copiar." >&2; exit 2; }

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR" 2> /dev/null || true

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="${BACKUP_DIR}/grafana-data-${stamp}.tar.gz"
partial="${target}.partial"

was_running=false
if [[ -n "$(docker compose ps --status running -q grafana 2> /dev/null)" ]]; then was_running=true; fi

cleanup() {
  rm -f "$partial"
  # Reinicia o Grafana mesmo se a cópia falhar.
  if [[ "$was_running" == "true" ]]; then docker compose start grafana > /dev/null 2>&1 || true; fi
}
trap cleanup EXIT

if [[ "$was_running" == "true" ]]; then docker compose stop grafana > /dev/null; fi

# Volume montado somente leitura; o conteúdo vai para o stdout e é gravado aqui (umask 077 => 0600).
docker run --rm --network none -v "${VOLUME}:/data:ro" "$HELPER_IMAGE" tar czf - -C /data . > "$partial"
# Confere o arquivo gerado antes de publicá-lo: gzip íntegro, tar legível e com grafana.db (backup corrompido é pior que nenhum).
gzip -t "$partial" 2> /dev/null || { echo "Backup inválido: gzip corrompido; descartado." >&2; exit 1; }
tar tzf "$partial" 2> /dev/null | grep -qE '^(\./)?grafana\.db$' || { echo "Backup inválido: sem grafana.db; descartado." >&2; exit 1; }
mv "$partial" "$target"
chmod 600 "$target" 2> /dev/null || true

# Rotação: remove backups com mais de RETENTION_DAYS dias.
# (BACKUP_SKIP_ROTATION=1 é usado pelo restore.sh para o backup de segurança não apagar o arquivo que será restaurado.)
if [[ "${BACKUP_SKIP_ROTATION:-}" != "1" ]]; then
  find "$BACKUP_DIR" -maxdepth 1 -name 'grafana-data-*.tar.gz' -type f -mtime "+${RETENTION_DAYS}" -delete
fi
# `.partial` órfão (processo morto por SIGKILL antes do trap): apaga os de mais de 1 hora.
find "$BACKUP_DIR" -maxdepth 1 -name 'grafana-data-*.partial' -type f -mmin +60 -delete

echo "Backup criado: ${target} ($(wc -c < "$target") bytes). Retenção: ${RETENTION_DAYS} dias."
