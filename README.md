# mcp.hosting Self-Hosted Deploy

[![Validate Templates](https://github.com/YawLabs/mcp-hosting-deploy/actions/workflows/validate.yml/badge.svg)](https://github.com/YawLabs/mcp-hosting-deploy/actions/workflows/validate.yml)

Your team's own private instance of [mcp.hosting](https://mcp.hosting) — the cloud orchestrator for MCP servers behind the `mcph` CLI. One deployment, license-key-gated features, same dashboard as the hosted service.

> **Who this is for.** Teams and enterprises that need their own instance for data-sovereignty, compliance, or contract reasons. If you can use the hosted service at [mcp.hosting](https://mcp.hosting), it's cheaper and always current — see the [Managed alternative](#managed-alternative) note below.

## One-click deploy

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/yawlabs/mcp-hosting-deploy) [![Deploy on Fly.io](https://fly.io/static/images/launch/deploy-on-fly.svg)](https://fly.io/launch?source=https://github.com/YawLabs/mcp-hosting-deploy)

## What you get

A self-hosted instance of mcp.hosting that your team can point their MCP clients at. Each team member installs [`@yawlabs/mcph`](https://www.npmjs.com/package/@yawlabs/mcph) in their Claude Desktop / Cursor / VS Code and sets `MCPH_URL=https://your-domain.example` — the rest of the flow is identical to the hosted product.

| Feature | Free tier (no license key) | Paid tier (license key set) |
|---|---|---|
| mcph orchestrator | Yes | Yes |
| Up to 3 MCP servers per user | Yes | Unlimited |
| Dashboard + team sign-up | Yes | Yes |
| Opt-in usage analytics | 7-day retention | 30-day retention |
| Compliance test runner | Yes | Yes |
| Team plan features (shared servers, admin controls, centralised billing) | — | Yes (Team key) |
| Priority support | — | Yes |

License keys are purchased on [mcp.hosting/pricing](https://mcp.hosting/pricing) via LemonSqueezy. The plan attached to the key determines which paid features light up.

## Prerequisites

- Linux server (Ubuntu 22.04+ recommended) or a Kubernetes cluster.
- A domain name pointed at your server (single A record).
- Docker Engine 24+ and Docker Compose v2+ *(for the Compose path)*, or `kubectl` + Helm 3+ *(for the Helm path)*.
- An [AWS SES](https://aws.amazon.com/ses/) sender identity for magic-link authentication (the only supported email provider today).

## Quick start — Docker Compose

```bash
# 1. Clone and move into the Compose directory
git clone https://github.com/yawlabs/mcp-hosting-deploy.git
cd mcp-hosting-deploy/docker-compose

# 2. Generate secrets + copy the env template
cp .env.example .env
# Edit .env — at minimum set DOMAIN, BASE_URL, POSTGRES_PASSWORD, COOKIE_SECRET,
# EMAIL_FROM, and the three AWS_* variables for SES.
# Optional: set MCP_HOSTING_LICENSE_KEY to unlock paid features.

# 3. Point your domain's A record at this server's public IP.

# 4. Bring everything up.
docker compose up -d

# 5. Open https://your-domain.example — Caddy will provision a Let's Encrypt
#    certificate automatically (usually under 60 seconds).
```

For a production deployment (resource limits + log rotation):

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

Your team members then install mcph pointing at your instance:

```json
{
  "mcpServers": {
    "mcp.hosting": {
      "command": "npx",
      "args": ["-y", "@yawlabs/mcph"],
      "env": {
        "MCPH_TOKEN": "mcp_pat_...",
        "MCPH_URL": "https://your-domain.example"
      }
    }
  }
}
```

On Windows, wrap the command in `cmd /c` — see the [main docs](https://mcp.hosting/docs) for the per-client config shapes.

## DNS

Point your domain's A record at the server's public IP:

```
A    your-domain.example    → <your-server-ip>
```

That's it — one record. Caddy handles TLS automatically via Let's Encrypt.

## License key activation

1. Subscribe to the **Team plan** at [mcp.hosting/pricing](https://mcp.hosting/pricing) ($15/seat/mo). Every Team subscription auto-generates a self-host license key, viewable in your hosted dashboard at **Settings → Self-host license key**.
2. Copy the key. Format: `mcph_sh_<hex>`.
3. Set it in your self-host environment:
   ```
   MCP_HOSTING_LICENSE_KEY=mcph_sh_...
   ```
4. Restart the app container: `docker compose restart mcp-hosting-app`.

On first boot, the instance validates against `mcp.hosting/api/license/validate` and stamps itself as the owner of that key — **one key, one instance.** Seat + plan changes propagate within 15 minutes (or click **Revalidate now** in your self-host's Settings for instant sync). If the license API is unreachable, cached paid features continue to work under a 7-day grace period; after that the instance falls back to free-tier features until the next successful validation. Moving to new hardware? Click **Unbind installation** in Settings, then validate on the new instance. See [docs/license.md](./docs/license.md) for the full behaviour.

## Upgrades

```bash
docker compose pull
docker compose up -d
```

The app runs database migrations automatically on boot. No manual step.

If an upgrade goes wrong, roll back to the previous image tag:

```bash
export MCP_HOSTING_IMAGE_TAG=previous-sha
docker compose up -d mcp-hosting-app
```

See [docs/upgrade.md](./docs/upgrade.md) for the full procedure and rollback tips.

## Backups

A backup script ships in `scripts/backup.sh`:

```bash
# Local backup
./scripts/backup.sh

# Backup + upload to S3
./scripts/backup.sh s3://my-bucket/mcp-backups

# Cron: daily at 2am
0 2 * * * /path/to/mcp-hosting-deploy/scripts/backup.sh s3://my-bucket/mcp-backups
```

Restore: see [docs/backup-restore.md](./docs/backup-restore.md).

## Health check

`GET /health` returns HTTP 200 when the service is healthy. Point any uptime monitor at `https://your-domain.example/health`.

## Deployment paths

| Template | Recommended for | Notes |
|---|---|---|
| [Docker Compose](./docker-compose/) | Single VM | Bundles Postgres 18 + Valkey 8 + Caddy. Fastest happy path. |
| [Helm](./helm/) | Existing Kubernetes cluster | Defaults to external managed Postgres (RDS, Cloud SQL) |
| [Render](./render/) | Managed PaaS | Blueprint deploys the app + managed Postgres |
| [Fly.io](./fly/) | Managed PaaS | `flyctl launch` with managed Postgres + Upstash Redis |
| [Cloud Run](./cloudrun/) | GCP serverless | Single-container; bring your own Cloud SQL + Memorystore |

Each path has its own README with exact prerequisites and a first-boot checklist.

**Deploying elsewhere?** The image at `ghcr.io/yawlabs/mcp-hosting:latest` runs on any container platform that gives it Postgres 14+, Redis/Valkey, and a domain. See [docs/getting-started.md](./docs/getting-started.md) for the minimum env var set.

## Operator documentation

- [docs/getting-started.md](./docs/getting-started.md) — full step-by-step walkthrough.
- [docs/upgrade.md](./docs/upgrade.md) — image pull, migration, rollback.
- [docs/backup-restore.md](./docs/backup-restore.md) — scripts/backup.sh and the restore flow.
- [docs/license.md](./docs/license.md) — license key lifecycle and grace periods.
- [docs/troubleshooting.md](./docs/troubleshooting.md) — common operator issues.
- [docs/mcph-client.md](./docs/mcph-client.md) — how team members point their mcph CLI at this instance.

## MCP protocol compatibility

Uses **Streamable HTTP** per the [MCP spec 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25). Caddy forwards `MCP-Session-Id` and `MCP-Protocol-Version` headers and supports long-lived SSE connections.

## Managed alternative

If you don't need self-host specifically, [mcp.hosting](https://mcp.hosting) is the same code running as a managed service — same dashboard, same mcph CLI, no ops. $9/mo Pro, $15/seat Team. Self-host makes sense when data sovereignty or contract terms require it; otherwise the hosted service is faster to set up and always current.

## Testing + validation

Every deployment template is CI-validated (Checkov security scan, cost estimates via Infracost where applicable, and end-to-end deploy tests against real infrastructure for the paths in green above). See [test-results/](./test-results/) for the latest run.

## Security

Vulnerability disclosure: see [SECURITY.md](./SECURITY.md). Short version: email [support@mcp.hosting](mailto:support@mcp.hosting) with a `[security]` subject prefix; we respond within 48 hours.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Source-available; not OSS. You may run this inside your organisation for your own use. Redistribution and operating a competing commercial MCP hosting service are prohibited. See [LICENSE](./LICENSE) for full terms.
