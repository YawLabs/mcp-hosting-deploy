#!/usr/bin/env bash
# =============================================================================
# mcp.hosting PostgreSQL backup script
# =============================================================================
# Usage:
#   ./scripts/backup.sh                     # Local backup only
#   ./scripts/backup.sh s3://bucket/path    # Upload to S3 after local backup
#
# Schedule with cron (daily at 2am):
#   0 2 * * * /path/to/mcp-hosting-deploy/scripts/backup.sh s3://my-bucket/mcp-backups
#
# Restore:
#   gunzip -c backup-file.sql.gz | docker compose exec -T postgres psql -U mcphosting mcphosting

set -euo pipefail

# Optional: set BACKUP_SLACK_WEBHOOK to receive failure notifications.
# Example: export BACKUP_SLACK_WEBHOOK=https://hooks.slack.com/services/T.../B.../xxx
notify_failure() {
  local msg="[mcp-hosting backup] FAILED on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "${msg}" >&2
  if [ -n "${BACKUP_SLACK_WEBHOOK:-}" ]; then
    curl -sf -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"${msg}\"}" \
      "${BACKUP_SLACK_WEBHOOK}" >/dev/null 2>&1 || true
  fi
}
trap notify_failure ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")/docker-compose"
BACKUP_DIR="${BACKUP_DIR:-${COMPOSE_DIR}/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="mcp-hosting-${TIMESTAMP}.sql.gz"
S3_DEST="${1:-}"

# Load .env for database credentials
if [ -f "${COMPOSE_DIR}/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "${COMPOSE_DIR}/.env"
  set +a
fi

DB_USER="${POSTGRES_USER:-mcphosting}"
DB_NAME="${POSTGRES_DB:-mcphosting}"

mkdir -p "${BACKUP_DIR}"

echo "[backup] Starting PostgreSQL backup..."
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T postgres \
  pg_dump -U "${DB_USER}" --format=plain "${DB_NAME}" \
  | gzip > "${BACKUP_DIR}/${BACKUP_FILE}"

FILE_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
echo "[backup] Created ${BACKUP_DIR}/${BACKUP_FILE} (${FILE_SIZE})"

# Upload to S3 if destination provided
if [ -n "${S3_DEST}" ]; then
  echo "[backup] Uploading to ${S3_DEST}/${BACKUP_FILE}..."
  aws s3 cp "${BACKUP_DIR}/${BACKUP_FILE}" "${S3_DEST}/${BACKUP_FILE}"
  echo "[backup] Upload complete."
fi

# Clean up old local backups
if [ "${RETENTION_DAYS}" -gt 0 ]; then
  DELETED=$(find "${BACKUP_DIR}" -name "mcp-hosting-*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete -print | wc -l)
  if [ "${DELETED}" -gt 0 ]; then
    echo "[backup] Removed ${DELETED} backup(s) older than ${RETENTION_DAYS} days."
  fi
fi

echo "[backup] Done."
