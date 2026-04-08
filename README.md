# mcp.hosting Self-Hosted Deploy

[![Validate Templates](https://github.com/YawLabs/mcp-hosting-deploy/actions/workflows/validate.yml/badge.svg)](https://github.com/YawLabs/mcp-hosting-deploy/actions/workflows/validate.yml) [![mcp.hosting tested](./test-results/badge.svg)](https://mcp.hosting/verified)

Self-host the [mcp.hosting](https://mcp.hosting) platform on your own infrastructure. One deployment -- a license key determines what features are enabled.

## One-click deploy

[![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/YawLabs/mcp-hosting-deploy/tree/master) [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/yawlabs/mcp-hosting-deploy) [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home#/stacks/create/review?stackName=mcp-hosting&templateURL=https://raw.githubusercontent.com/YawLabs/mcp-hosting-deploy/master/cloudformation/ec2/template.yaml)

## Install

```bash
# Docker
docker pull ghcr.io/yawlabs/mcp-hosting:latest

# Helm
helm install mcp-hosting oci://ghcr.io/yawlabs/charts/mcp-hosting
```

## What's included

| Feature | Free | Licensed ($19/mo) |
|---|---|---|
| MCP server hosting | Yes | Yes |
| Compliance & audit logging | Yes | Yes |
| MCP proxy (auth, rate limiting, routing) | -- | Yes |
| Priority support | -- | Yes |

Get a license key at [mcp.hosting/pricing](https://mcp.hosting/pricing).

## Prerequisites

- Docker and Docker Compose v2+
- A domain name (e.g. `mcp.example.com`)
- DNS: `mcp.example.com` and `*.mcp.example.com` pointing to your server
- AWS SES credentials for email (required for magic link login)

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/yawlabs/mcp-hosting-deploy.git
cd mcp-hosting-deploy/docker-compose

# 2. Configure your environment
cp .env.example .env
# Edit .env -- at minimum set DOMAIN, BASE_URL, POSTGRES_PASSWORD, and COOKIE_SECRET

# 3. Start everything
docker compose up -d
```

Your instance will be live at `https://your-domain.com` once Caddy provisions the TLS certificate (usually under a minute).

For production deployments, use the production overlay for resource limits and log rotation:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

## DNS setup

Point both your root domain and a wildcard to your server's IP:

```
A    mcp.example.com      → 203.0.113.10
A    *.mcp.example.com    → 203.0.113.10
```

Wildcard subdomains are used for per-server routing (e.g. `my-server.mcp.example.com`).

For wildcard TLS certificates, Caddy uses the DNS challenge. The default Caddyfile is configured for Cloudflare -- set `CF_API_TOKEN` in your `.env`. For other DNS providers, swap the Caddy image for one with your provider's plugin and update the Caddyfile accordingly.

## Email setup

Magic link authentication requires AWS SES. Set `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `EMAIL_FROM` in your `.env`.

If no AWS credentials are provided, email sending is disabled and **login will not work**.

## Health check

The app exposes `GET /health` which returns HTTP 200 when the service is running. Point your uptime monitor at `https://mcp.example.com/health`.

## Upgrading

```bash
docker compose pull
docker compose up -d
```

The app container runs database migrations automatically on startup.

## Backups

Use the included backup script for scheduled PostgreSQL backups:

```bash
# Local backup
./scripts/backup.sh

# Backup and upload to S3
./scripts/backup.sh s3://my-bucket/mcp-backups

# Schedule daily backups via cron (2am)
# 0 2 * * * /path/to/mcp-hosting-deploy/scripts/backup.sh s3://my-bucket/mcp-backups
```

See [scripts/backup.sh](./scripts/backup.sh) for restore instructions and configuration options.

## Deploy templates

| Template | Status | Notes |
|---|---|---|
| [Docker Compose](./docker-compose/) | Ready | Bundles Postgres for simplicity |
| [Helm](./helm/) | Ready | Defaults to external database (RDS, Cloud SQL, etc.) |
| [Cloud Run](./cloudrun/) | Ready | Serverless containers on GCP |
| [Fly.io](./fly/) | Ready | Managed Postgres & Redis via `fly` CLI |
| [Railway](./railway/) | Ready | One-click deploy button |
| [Render](./render/) | Ready | Blueprint with managed Postgres |
| [CloudFormation](./cloudformation/) | Ready | AWS-native with ECS Fargate |
| [Terraform](./terraform/) | Ready | Multi-cloud (AWS, GCP, Azure) |

> **Helm chart note:** The Helm chart defaults to an **external managed database** (e.g. AWS RDS, Cloud SQL, AlloyDB). Set `externalDatabase.host` and credentials in your values. In-cluster Postgres is available for development by setting `postgres.enabled: true`. In-cluster Valkey is used by default and is fine for production.

## Testing

Deploy templates are tested weekly against real infrastructure. Each test deploys the full template, verifies the application health check, and tears down all resources. See [test-results/](./test-results/) for the latest run.

| Template | Tested | Method |
|---|---|---|
| CloudFormation EC2 | Yes | Full AWS deploy + HTTP health check |
| CloudFormation ECS Fargate | Yes | Full AWS deploy + ECS/ALB status |
| Terraform AWS | Yes | Full AWS deploy + SSM health check |
| Docker Compose | Yes | Local Docker health check |
| Helm | Planned | Needs Kubernetes cluster |
| Cloud Run | Planned | Needs GCP |
| Terraform GCP | Planned | Needs GCP |
| Terraform Azure | Planned | Needs Azure |
| Fly.io | Planned | Needs account |
| DigitalOcean | Planned | Needs account |
| Render | Planned | Needs account |
| Railway | Planned | Needs account |

Templates are also scanned with [Checkov](https://www.checkov.io/) for security best practices, and cost estimates are generated via [Infracost](https://www.infracost.io/).

## MCP protocol compatibility

This platform uses **Streamable HTTP** as the production transport (per the [MCP spec 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)). The Caddy reverse proxy is configured to forward MCP-specific headers (`MCP-Session-Id`, `MCP-Protocol-Version`) and supports long-lived SSE connections.

The licensed proxy tier implements authentication and rate limiting aligned with the MCP specification's OAuth 2.1 requirements for HTTP-based transports.

## Managed alternative

Don't want to manage infrastructure? Use [mcp.hosting](https://mcp.hosting) -- the fully managed version with the same features, zero ops.

## Detailed guide

See [docs/getting-started.md](./docs/getting-started.md) for a step-by-step walkthrough including DNS, email, and production hardening.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

## License

MIT
