# Production deployment checklist

The Quickstart in the README gets you a working instance fast, but a
production deployment for a real team needs more. Walk this list end
to end **before** you cut over real users.

## 1. Database — managed multi-AZ Postgres

The bundled `postgres:18` container in `docker-compose/` and the
`postgres.enabled=true` toggle in the Helm chart are **development
defaults**. Don't run them in production:

- Single-replica Postgres in a single AZ has no failover. A node loss
  means the dashboard is down until you restore from a backup.
- The container has no replication, no PITR, no automated failover.
- A persistent volume is one accidental `docker compose down -v`
  away from total data loss.

For production:

- **AWS**: RDS for PostgreSQL 17+, Multi-AZ deployment, automated
  backups + 7-day PITR retention, `rds_pgvector` enabled.
- **GCP**: Cloud SQL for PostgreSQL 17+, HA configuration,
  point-in-time recovery on, pgvector extension enabled.
- **Azure**: Azure Database for PostgreSQL Flexible Server, zone-
  redundant HA, geo-redundant backups, pgvector extension installed.
- **Self-managed**: PostgreSQL 17+ with streaming replication to a
  hot standby in a separate AZ, WAL archiving, automated failover
  via Patroni or pg_auto_failover.

In every case: `CREATE EXTENSION IF NOT EXISTS vector;` must succeed
on first boot. The app's startup migration runs it; if pgvector isn't
available the pod crash-loops before binding `/health`.

For Helm: leave `postgres.enabled: false` (the default) and fill in
`externalDatabase` with your managed instance's connection details.

For Docker Compose: comment out the `postgres` service entirely and
override `DATABASE_URL` to point at your managed instance.

## 2. Backups — automated + tested

- Schedule `scripts/backup.sh s3://your-bucket/path` daily via cron
  or your scheduler. Retain at least 30 daily snapshots; 12 weekly;
  12 monthly. See [backup-restore.md](./backup-restore.md).
- Verify the script's gzip integrity check is running (it exits
  non-zero on corrupt dumps).
- **Test restores quarterly** against a throwaway instance. An
  untested backup is a hope, not a backup.

## 3. App replicas — at least two

The Helm chart defaults `app.replicas: 2`, which is the minimum for
zero-downtime rolling updates. If you bumped it to 1 for cost
reasons, undo that for production. Pair this with a
PodDisruptionBudget if your platform autoscales nodes.

## 4. TLS termination — managed

The bundled Caddy works fine in front of a single-VM Compose deploy.
For Kubernetes production, terminate TLS at your platform's managed
load balancer (ALB, NLB+ACM, GLB, etc.) so cert renewal isn't
single-pod-pinned. Caddy can stay as the in-cluster reverse proxy
behind the LB if you want; it just doesn't need to handle
Let's Encrypt itself.

## 5. License monitoring

A self-host instance returns 503 on API routes when its license
validation has failed for 24 hours straight. Get ahead of it:

- Add an alert on `mcp_license_grace_remaining_seconds` (exposed via
  `/metrics`) firing at < 12h remaining.
- Watch the dashboard's in-app **License grace** banner — it appears
  when validation hasn't succeeded in the last 12h, and turns red
  when the instance has already started returning 503.
- The `Revalidate now` button in the banner and on the Admin page
  forces an out-of-band validation; useful when you've fixed
  whatever blocked the background timer.

## 6. Secret rotation — graceful path

The single `COOKIE_SECRET` signs every session cookie. Rotating it
naively logs every user out. Use the dual-key flow instead:

```bash
# 1. Generate a new secret
NEW_SECRET=$(openssl rand -hex 32)

# 2. Set the OLD value as COOKIE_SECRET_OLD and the NEW value as
#    COOKIE_SECRET. The app accepts either for verification and
#    signs new cookies with the NEW value.
docker compose exec mcp-hosting-app sh -c "
  COOKIE_SECRET=$NEW_SECRET
  COOKIE_SECRET_OLD=<your previous COOKIE_SECRET>
"
# (or kubectl set env / helm upgrade --set as appropriate)

# 3. Wait for sessions to age out (default 7 days) or for users to
#    naturally re-sign-in.

# 4. Unset COOKIE_SECRET_OLD. Any sessions still signed with the old
#    value will fail next request and the user will see a clean
#    re-login.
```

The Admin → Environment table on a self-host instance shows whether
`COOKIE_SECRET_OLD` is currently set so you can confirm the
rotation window is active.

## 7. Audit log retention + export

The `audit_events` table is append-only. By default it grows
indefinitely. For compliance reviews:

- Use the **Admin → Audit log** page (`/dashboard/admin/audit`) to
  filter by action + date range.
- Click **Export CSV** to download the matching events for a SOC 2
  / ISO 27001 reviewer.
- If you need to keep the table small for storage reasons, schedule
  a monthly job to dump rows older than your retention requirement
  to S3 + DELETE FROM audit_events WHERE created_at < ...

## 8. Egress + ingress controls

- Use a Kubernetes NetworkPolicy (or your VPC's security groups) to
  restrict pod egress to: managed Postgres, Valkey, the upstream MCP
  servers your team uses, `mcp.hosting` (license validation), `ghcr.io`
  (image pulls), AWS SES endpoints (magic-link email).
- Restrict ingress to your TLS-terminating LB only.
- If your team only uses MCP servers inside your corporate VPC, set
  the IP allowlist on each server in dashboard Settings to refuse
  outside traffic.

## 9. Observability

- Scrape `/metrics` with Prometheus; the Helm chart will deploy a
  `ServiceMonitor` if `monitoring.serviceMonitor.enabled=true`.
- Import the starter Grafana dashboard from
  [observability.md](./observability.md).
- Wire alerts on:
  - 5xx rate > 1%
  - Upstream p95 latency > 2s
  - Redis disconnect / Postgres connection exhaustion
  - License grace remaining < 12h
  - Daily backup last-success age > 30h

## 10. Disaster recovery rehearsal

Once a year (calendar event, today):

1. Spin up a completely separate cluster from scratch.
2. Restore the most recent S3 backup into a fresh Postgres in the
   recovery cluster.
3. Boot the app pointing at the restored DB. Confirm: dashboard
   loads, an existing user can sign in, a configured MCP server
   responds.
4. Tear down the recovery environment.

Document the wall-clock time it took. That number is your real RTO.
