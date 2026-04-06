# mcp.hosting Self-Hosted Deploy

Self-host the [mcp.hosting](https://mcp.hosting) platform on your own infrastructure. One deployment -- a license key determines what features are enabled.

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

## DNS setup

Point both your root domain and a wildcard to your server's IP:

```
A    mcp.example.com      → 203.0.113.10
A    *.mcp.example.com    → 203.0.113.10
```

Wildcard subdomains are used for per-server routing (e.g. `my-server.mcp.example.com`).

For wildcard TLS certificates, Caddy uses the DNS challenge. The default Caddyfile is configured for Cloudflare -- set `CF_API_TOKEN` in your `.env`. For other DNS providers, swap the Caddy image for one with your provider's plugin and update the Caddyfile accordingly.

## Email setup

Magic link authentication requires an email provider. The default configuration uses AWS SES. Set `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `EMAIL_FROM` in your `.env`.

If no AWS credentials are provided, email sending is disabled.

## Upgrading

```bash
docker compose pull
docker compose up -d
```

The app container runs database migrations automatically on startup.

## Deploy templates

| Template | Status | Notes |
|---|---|---|
| [Docker Compose](./docker-compose/) | Ready | Bundles Postgres for simplicity |
| [Helm](./helm/) | Ready | Defaults to external database (RDS, Cloud SQL, etc.) |
| [CloudFormation](./cloudformation/) | Coming soon | |
| [Terraform](./terraform/) | Coming soon | |

> **Helm chart note:** The Helm chart defaults to an **external managed database** (e.g. AWS RDS, Cloud SQL, AlloyDB). Set `externalDatabase.host` and credentials in your values. In-cluster Postgres is available for development by setting `postgres.enabled: true`. In-cluster Valkey is used by default and is fine for production.

## Managed alternative

Don't want to manage infrastructure? Use [mcp.hosting](https://mcp.hosting) -- the fully managed version with the same features, zero ops.

## Detailed guide

See [docs/getting-started.md](./docs/getting-started.md) for a step-by-step walkthrough including DNS, email, and production hardening.

## License

MIT
