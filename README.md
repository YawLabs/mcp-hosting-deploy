# mcp.hosting Self-Hosted Deploy

[![Validate Templates](https://github.com/YawLabs/mcp-hosting-deploy/actions/workflows/validate.yml/badge.svg)](https://github.com/YawLabs/mcp-hosting-deploy/actions/workflows/validate.yml)

Your team's own private instance of [mcp.hosting](https://mcp.hosting) — the cloud orchestrator for MCP servers behind the `mcph` CLI. One deployment, license-key-gated features, same dashboard as the hosted service.

> **Who this is for.** Teams and enterprises that need their own instance for data-sovereignty, compliance, or contract reasons. If you can use the hosted service at [mcp.hosting](https://mcp.hosting), it's cheaper and always current — see the [Managed alternative](#managed-alternative) note below.

## One-click deploy

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/yawlabs/mcp-hosting-deploy) [![Deploy on Fly.io](https://fly.io/static/images/launch/deploy-on-fly.svg)](https://fly.io/launch?source=https://github.com/YawLabs/mcp-hosting-deploy)

## What you get

A self-hosted instance of mcp.hosting that your team can point their MCP clients at. Each team member installs [`@yawlabs/mcph`](https://www.npmjs.com/package/@yawlabs/mcph) in their Claude Desktop / Cursor / VS Code and sets `MCPH_URL=https://your-domain.example` — the rest of the flow is identical to the hosted product.

Self-host is a **Team plan** capability and requires an active Team license key (`mcph_sh_<hex>`). Feature set:

- mcph orchestrator + dashboard + team sign-up
- Unlimited MCP servers per user
- Opt-in usage analytics (30-day retention)
- Compliance test runner
- Shared servers, admin controls, centralised billing
- Priority support

Free tier is hosted-only at [mcp.hosting](https://mcp.hosting) — no self-host install. License keys are purchased on [mcp.hosting/pricing](https://mcp.hosting/pricing) via LemonSqueezy. Every Team subscription auto-generates a self-host license key + GHCR pull token in your hosted dashboard at **Settings → Self-host**.

## Prerequisites

- An active **Team** subscription at [mcp.hosting/pricing](https://mcp.hosting/pricing). Copy your self-host license key and GHCR pull token from the hosted dashboard at **Settings → Self-host**. You need both to deploy.
- Linux server (Ubuntu 22.04+ recommended) or a Kubernetes cluster.
- A domain name pointed at your server (single A record).
- Docker Engine 24+ and Docker Compose v2+ *(for the Compose path)*, or `kubectl` + Helm 3+ *(for the Helm path)*.
- An [AWS SES](https://aws.amazon.com/ses/) sender identity for magic-link authentication (the only supported email provider today).

## Quick start — Docker Compose

```bash
# 1. Clone and move into the Compose directory
git clone https://github.com/yawlabs/mcp-hosting-deploy.git
cd mcp-hosting-deploy/docker-compose

# 2. Authenticate to GHCR with your self-host pull token
#    (obtainable at mcp.hosting Settings → Self-host → GHCR token)
echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin

# 3. Copy the env template + fill in required values
cp .env.example .env
# Edit .env — set DOMAIN, BASE_URL, POSTGRES_PASSWORD, COOKIE_SECRET,
# MCP_HOSTING_LICENSE_KEY, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET,
# EMAIL_FROM, and the three AWS_* variables for SES.

# 4. Point your domain's A record at this server's public IP.

# 5. Bring everything up.
docker compose up -d

# 6. Open https://your-domain.example — Caddy will provision a Let's Encrypt
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

The license key is **required on first boot** — the app will not start without it. Subscribe to the **Team plan** at [mcp.hosting/pricing](https://mcp.hosting/pricing) ($15/seat/mo). Every Team subscription auto-generates a self-host license key (`mcph_sh_<hex>`) and a scoped GHCR pull token, both visible in your hosted dashboard at **Settings → Self-host**.

1. Copy the license key and set it in `.env`:
   ```
   MCP_HOSTING_LICENSE_KEY=mcph_sh_...
   ```
2. Copy the GHCR pull token and authenticate your Docker client once:
   ```
   echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin
   ```
3. Start the stack: `docker compose up -d`.

On first boot, the instance validates against `mcp.hosting/api/license/validate` and stamps itself as the owner of that key — **one key, one instance.** Seat + plan changes propagate within 15 minutes (or click **Revalidate now** in your self-host's Settings for instant sync). If the license API is unreachable, cached capabilities continue to work under a 24-hour grace period; after that the instance refuses to serve requests until the next successful validation. Moving to new hardware? Click **Unbind installation** in Settings, then activate on the new instance. See [docs/license.md](./docs/license.md) for the full behaviour, [docs/self-host-token.md](./docs/self-host-token.md) for GHCR auth details.

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

[mcp.hosting](https://mcp.hosting) runs the same code as a managed service — same dashboard, same mcph CLI, no ops. Free tier and $9/mo Pro are hosted-only. Self-host is bundled with every **Team** subscription ($15/seat/mo) alongside the hosted Team features. Pick self-host when data sovereignty or contract terms require it; otherwise the hosted Team plan is faster to set up and always current.

## Testing + validation

Every deployment template is CI-validated (Checkov security scan, cost estimates via Infracost where applicable, and end-to-end deploy tests against real infrastructure for the paths in green above). See [test-results/](./test-results/) for the latest run.

## Security

Vulnerability disclosure: see [SECURITY.md](./SECURITY.md). Short version: email [support@mcp.hosting](mailto:support@mcp.hosting) with a `[security]` subject prefix; we respond within 48 hours.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Source-available under the [Elastic License 2.0](./LICENSE) — not OSS. You may use, copy, modify, and redistribute the software, including for internal production use by your organisation. You may **not** offer it to third parties as a hosted or managed MCP service, disable or circumvent the license-key functionality, or remove the copyright and licensing notices. See [LICENSE](./LICENSE) for full terms.
