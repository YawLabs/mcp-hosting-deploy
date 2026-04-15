# Upgrading

Routine upgrades pull a fresh image, restart the app container, and auto-apply any pending database migrations. The app refuses to boot if migrations fail, so a bad migration fails loudly and rolls back cleanly.

## Docker Compose

```bash
cd mcp-hosting-deploy/docker-compose

# Ensure your GHCR session is still valid. Tokens are revoked automatically
# when a subscription lapses, so a "docker compose pull" that used to work
# can start returning "denied" — re-login first if it's been a while.
echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin

# Pull the latest tag
docker compose pull mcp-hosting-app

# Restart — migrations run automatically on boot
docker compose up -d mcp-hosting-app

# Verify
docker compose ps
curl -sf https://your-domain.example/health
```

If you want to pin a specific version instead of `latest`:

```yaml
# docker-compose.override.yml
services:
  mcp-hosting-app:
    image: ghcr.io/yawlabs/mcp-hosting:v0.8.1
```

## Helm

```bash
helm repo update
helm upgrade mcp-hosting ./helm/mcp-hosting \
  --set app.tag=v0.8.1 \
  --reuse-values

# Watch the rollout
kubectl -n mcp-hosting rollout status deployment/mcp-hosting-app
```

## What runs during upgrade

1. New image starts → `runMigrations()` fires before any route handlers are registered.
2. Drizzle applies any new migrations in `drizzle/*.sql` that aren't already in `__drizzle_migrations`.
3. If migrations succeed, the app binds to port 3000 and the healthcheck goes green.
4. If migrations fail, the app exits(1) with a logged error. The container restart loop surfaces the failure — the old image keeps serving traffic if you're on Compose with `depends_on.service_healthy`, or Kubernetes holds the rollout if you're on Helm.

## Rollback

### Docker Compose

```bash
# Pin the previous tag
export MCP_HOSTING_IMAGE_TAG=v0.8.0   # whatever the prior version was
docker compose up -d mcp-hosting-app
```

### Helm

```bash
helm rollback mcp-hosting
kubectl -n mcp-hosting rollout status deployment/mcp-hosting-app
```

### Caveat on rolling back across a breaking migration

Migrations are forward-only. If release `N` added a NOT NULL column and release `N-1` never knew about it, rolling back the image without reverting the migration leaves you serving the old image against a new schema. Usually this works (extra column is ignored) but occasionally breaks (app writes `INSERT` statements that don't mention the new column and Postgres rejects them).

Rule of thumb:

- Schema additions (new tables, new nullable columns, new indexes) → rollback is safe.
- Schema removals (dropped columns, renamed columns, removed tables) → rollback needs a matching forward migration, not a backward one. Don't hot-rollback across these; fix-forward.

Every migration we ship aims for the "safe rollback" shape. If a release includes a breaking migration, the release notes call it out explicitly.

## Scheduled upgrade windows

Upgrades are backward-compatible within minor versions. You can upgrade any time with effectively zero downtime on Kubernetes (rolling deployment) or a ~10-second window on Docker Compose (container restart).

For major version bumps or release notes that call out a breaking change, schedule a short maintenance window and take a backup first.

## Verifying the upgrade worked

```bash
# Version comes back in the health / startup log
docker compose logs mcp-hosting-app | grep -i "mcph started\|version"

# Migration table in Postgres
docker compose exec postgres psql -U mcphosting -c "SELECT * FROM __drizzle_migrations ORDER BY created_at DESC LIMIT 5;"
```

## Related

- [docs/backup-restore.md](./backup-restore.md) — take a backup before a major upgrade.
- [docs/troubleshooting.md](./troubleshooting.md) — what to do when upgrade logs look bad.
