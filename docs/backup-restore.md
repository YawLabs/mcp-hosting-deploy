# Backup + restore

The only durable data on a self-hosted instance is in Postgres. Redis / Valkey is a cache — losing it triggers fresh logins and a few minutes of degraded analytics, nothing more. So "backup" here means "Postgres dumps + a tested restore path."

## What you're backing up

All user data lives in Postgres:
- `accounts`, `servers`, `connect_servers`, `connect_teams` — user + config state.
- `api_tokens`, `api_keys` — credentials (hashes only — plaintext is never stored).
- `connect_analytics`, `analytics_events`, `request_logs` — opt-in usage data.
- `compliance_reports` — compliance test history.

`scripts/backup.sh` produces a compressed `pg_dump` of the whole database. That single file is a complete, restorable snapshot.

## Daily backups (recommended)

### Local only

```bash
# One-off
./scripts/backup.sh

# Nightly at 02:00 via cron
0 2 * * * /path/to/mcp-hosting-deploy/scripts/backup.sh
```

The script writes timestamped `mcp-hosting-backup-YYYYMMDD-HHMMSS.sql.gz` files under `./backups/` by default.

### Backups uploaded to S3 (recommended for production)

```bash
# One-off upload
./scripts/backup.sh s3://my-bucket/mcp-backups

# Nightly
0 2 * * * /path/to/mcp-hosting-deploy/scripts/backup.sh s3://my-bucket/mcp-backups
```

The script uses your AWS CLI default credentials. Use an IAM user scoped to a single bucket with `s3:PutObject` / `s3:GetObject`.

**RPO guidance:** with nightly backups, worst-case data loss is 24 hours. For a more aggressive RPO, run the script every 6 hours and use S3 lifecycle rules to expire daily snapshots after 30 days while keeping weekly snapshots for 90.

## Restore

### From a local backup

```bash
# Docker Compose
gunzip -c backups/mcp-hosting-backup-20260414-020001.sql.gz \
  | docker compose exec -T postgres psql -U mcphosting mcphosting

# Pull the Postgres container's state fresh first if restoring from scratch
docker compose down
docker volume rm docker-compose_postgres_data
docker compose up -d postgres
# wait ~5s for Postgres to accept connections
gunzip -c backups/mcp-hosting-backup-20260414-020001.sql.gz \
  | docker compose exec -T postgres psql -U mcphosting mcphosting
docker compose up -d
```

### From S3

```bash
aws s3 cp s3://my-bucket/mcp-backups/mcp-hosting-backup-20260414-020001.sql.gz .
gunzip -c mcp-hosting-backup-20260414-020001.sql.gz \
  | docker compose exec -T postgres psql -U mcphosting mcphosting
```

### Helm / Kubernetes

Dump locally via `kubectl exec` against the app pod (which has `pg_dump` installed via the image):

```bash
kubectl -n mcp-hosting exec deploy/mcp-hosting-app -- \
  pg_dump $DATABASE_URL | gzip > mcp-hosting-backup.sql.gz
```

Restore the same way, piping `psql` against `$DATABASE_URL` from inside the pod.

## Testing your backups

Untested backups aren't backups. At least quarterly, restore a recent snapshot into a throwaway instance and verify:

1. Dashboard loads.
2. An existing account can log in (magic-link triggers email; SES has to be working).
3. MCP servers appear with correct config.

If you skip this, you'll discover the backup was broken the day you actually need it.

## Schema migrations + restore

Backups include schema state — `__drizzle_migrations` table is restored with everything else. The app on boot sees "we're already at migration N" and doesn't re-run anything. If you restore a backup from an older app version, you can then `docker compose pull && docker compose up -d` and the newer app will run any pending forward migrations on top.

## What the backup script actually runs

```bash
docker compose exec -T postgres pg_dump \
  -U ${POSTGRES_USER:-mcphosting} \
  -d ${POSTGRES_DB:-mcphosting} \
  --format=plain --no-owner --no-acl \
  | gzip > "${OUTPUT_PATH}"
```

Plain-text dump (not custom-format) so you can eyeball it with `zless` if something goes wrong. No owner / ACL lines so restoring into a different user account is clean.
