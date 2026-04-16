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
  # Declare + assign on separate lines so the trap'd ERR exit code from
  # within the failed command is preserved — `local` masks the assignment's
  # exit status (shellcheck SC2155).
  local msg
  msg="[mcp-hosting backup] FAILED on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
# RETENTION_DAYS prunes only the LOCAL copies in BACKUP_DIR — this is a
# disk-fullness guard, not a long-term retention policy. For production
# 30/90/365-day retention, configure an S3 lifecycle policy on the upload
# bucket (see docs/production-checklist.md). The 7-day local default
# leaves enough history to roll back without filling small VM disks.
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="mcp-hosting-${TIMESTAMP}.sql.gz"
S3_DEST="${1:-}"

# Load .env for database credentials. Hard fail if it's missing — the
# script must back up the SAME database the running stack uses, and
# silently falling through to "mcphosting/mcphosting" defaults would
# happily produce empty/wrong backups when an operator has customised
# POSTGRES_USER or POSTGRES_DB.
if [ ! -f "${COMPOSE_DIR}/.env" ]; then
  echo "[backup] FAIL: ${COMPOSE_DIR}/.env not found." >&2
  echo "[backup]       cp ${COMPOSE_DIR}/.env.example ${COMPOSE_DIR}/.env first," >&2
  echo "[backup]       or set POSTGRES_USER + POSTGRES_DB in this script's env." >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "${COMPOSE_DIR}/.env"
set +a

DB_USER="${POSTGRES_USER:-mcphosting}"
DB_NAME="${POSTGRES_DB:-mcphosting}"

mkdir -p "${BACKUP_DIR}"

# Verify the postgres service is actually running before pg_dump'ing
# into a void. `docker compose exec` against a stopped container exits
# non-zero which trap'd `set -e` would catch — but the surfaced error is
# easier to diagnose if we name the failure mode explicitly.
if ! docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps --status=running --services 2>/dev/null \
    | grep -qx postgres; then
  echo "[backup] FAIL: postgres service is not running. Bring the stack up first:" >&2
  echo "[backup]       docker compose -f ${COMPOSE_DIR}/docker-compose.yml up -d postgres" >&2
  exit 1
fi

echo "[backup] Starting PostgreSQL backup..."
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T postgres \
  pg_dump -U "${DB_USER}" --format=plain "${DB_NAME}" \
  | gzip > "${BACKUP_DIR}/${BACKUP_FILE}"

FILE_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
echo "[backup] Created ${BACKUP_DIR}/${BACKUP_FILE} (${FILE_SIZE})"

# Verify the gzip stream parses end-to-end before we declare success or
# upload — pg_dump silently dropping mid-stream produces a "valid"
# gzip up to the truncation point, so a separate integrity check is the
# only way to catch partial writes.
echo "[backup] Verifying archive integrity..."
if ! gunzip -t "${BACKUP_DIR}/${BACKUP_FILE}"; then
  echo "[backup] FAIL: gzip integrity check did not pass — archive is corrupt." >&2
  exit 1
fi
echo "[backup] Integrity OK."

# Upload to S3 if destination provided. For huge databases we recommend
# the streaming variant in docs/backup-restore.md (pg_dump | gzip | aws
# s3 cp - s3://...) to avoid pinning a multi-GB temp file. This script's
# write-then-upload path is the safest default for the common case.
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
