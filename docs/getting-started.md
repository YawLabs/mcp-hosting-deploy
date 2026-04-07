# Getting Started with mcp.hosting Self-Hosted

This guide walks through setting up a production mcp.hosting instance using Docker Compose.

## 1. Server requirements

- Linux server (Ubuntu 22.04+ recommended) with a public IP
- Docker Engine 24+ and Docker Compose v2+
- At least 2 GB RAM, 2 vCPUs, 20 GB disk
- Ports 80 and 443 open to the internet

## 2. Domain and DNS

You need a domain (or subdomain) with both a root record and a wildcard record pointing to your server.

Example using `mcp.example.com`:

```
A    mcp.example.com      → <your-server-ip>
A    *.mcp.example.com    → <your-server-ip>
```

The wildcard is required because each hosted MCP server gets its own subdomain (e.g. `my-server.mcp.example.com`).

**DNS propagation** can take up to 48 hours, but usually completes within minutes. You can verify with:

```bash
dig mcp.example.com
dig test.mcp.example.com
```

Both should resolve to your server's IP.

## 3. Wildcard TLS certificates

Caddy handles TLS automatically via Let's Encrypt. For wildcard certificates (`*.mcp.example.com`), the ACME DNS challenge is required -- HTTP challenges only work for individual domains, not wildcards.

The included Caddyfile uses the Cloudflare DNS plugin. To use it:

1. Create a Cloudflare API token with `Zone:DNS:Edit` permissions for your domain.
2. Set `CF_API_TOKEN` in your `.env` file.
3. Use the Caddy image with the Cloudflare plugin. You can build one with:

```Dockerfile
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

Or update `docker-compose.yml` to use a pre-built image that includes the Cloudflare module.

**Other DNS providers:** Caddy has plugins for most providers (Route53, DigitalOcean, etc.). Replace the `dns cloudflare` line in the Caddyfile with your provider and build Caddy with the corresponding plugin.

**No wildcard (simpler setup):** If you don't need per-server subdomains, you can remove the wildcard block from the Caddyfile entirely and use only the root domain. Caddy will provision a standard certificate via HTTP challenge with no DNS plugin needed.

## 4. Configure environment

```bash
cd mcp-hosting-deploy/docker-compose
cp .env.example .env
```

Edit `.env` and set at minimum:

| Variable | Required | Notes |
|---|---|---|
| `DOMAIN` | Yes | Your domain, e.g. `mcp.example.com` |
| `BASE_URL` | Yes | Full URL, e.g. `https://mcp.example.com` |
| `POSTGRES_PASSWORD` | Yes | Use a strong, random password |
| `COOKIE_SECRET` | Yes | Generate with `openssl rand -hex 32` |
| `MCP_HOSTING_LICENSE_KEY` | No | Leave empty for free tier |
| `EMAIL_FROM` | For auth | The sender address for magic link emails |
| `AWS_*` | For auth | AWS SES credentials for sending email |
| `CF_API_TOKEN` | For wildcard TLS | Cloudflare API token for DNS challenge |

## 5. Start the stack

```bash
docker compose up -d
```

For production, use the production overlay for resource limits and log rotation:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

Check that everything is running:

```bash
docker compose ps
```

You should see four containers: `mcp-hosting-app`, `postgres`, `redis`, and `caddy` -- all healthy.

View logs if something isn't right:

```bash
docker compose logs -f mcp-hosting-app
docker compose logs -f caddy
```

## 6. Email configuration (AWS SES)

Magic link authentication sends a login link to the user's email. This requires **AWS SES** -- it is the only supported email provider.

### AWS SES setup

1. In the AWS console, go to SES and verify your sending domain or email address.
2. If your SES account is in sandbox mode, you can only send to verified addresses. Request production access for unrestricted sending.
3. Create an IAM user with `ses:SendEmail` and `ses:SendRawEmail` permissions.
4. Add the credentials to your `.env`:

```
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
EMAIL_FROM=noreply@mcp.example.com
```

5. Restart the app: `docker compose restart mcp-hosting-app`

**If no email credentials are configured, login will not work.** Email is required for magic link authentication.

## 7. Health check

The app exposes `GET /health` at the root domain. This endpoint returns HTTP 200 when the service is running and can accept requests. Use it for uptime monitoring:

```bash
curl -s https://mcp.example.com/health
```

## 8. Verify your deployment

1. Open `https://mcp.example.com` in your browser. You should see the mcp.hosting dashboard.
2. Try logging in with a magic link (requires email to be configured).
3. Create a test MCP server and verify it's reachable at its subdomain.

## 9. Production hardening

**Backups:** Use the included backup script for scheduled PostgreSQL backups:

```bash
# One-time backup
./scripts/backup.sh

# Backup with S3 upload
./scripts/backup.sh s3://my-bucket/mcp-backups

# Schedule daily at 2am via cron
0 2 * * * /path/to/mcp-hosting-deploy/scripts/backup.sh s3://my-bucket/mcp-backups
```

To restore from a backup:

```bash
gunzip -c backup-file.sql.gz | docker compose exec -T postgres psql -U mcphosting mcphosting
```

**Firewall:** Only ports 80 and 443 need to be open. Block direct access to ports 5432 (Postgres) and 6379 (Redis) from the internet.

**Monitoring:** Point your uptime monitor at `https://mcp.example.com/health`.

**Updates:**

```bash
docker compose pull
docker compose up -d
```

Database migrations run automatically on app startup. There is no manual migration step.

## 10. License key

To unlock proxy features (auth, rate limiting, routing):

1. Purchase a license at [mcp.hosting/pricing](https://mcp.hosting/pricing).
2. Add the key to your `.env`:

```
MCP_HOSTING_LICENSE_KEY=lk_live_...
```

3. Restart: `docker compose restart mcp-hosting-app`

Proxy features activate immediately. No data loss or downtime.

## 11. MCP protocol notes

### Streamable HTTP transport

This platform uses **Streamable HTTP** as the production transport, per the [MCP specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25). The reverse proxy is configured to:

- Forward MCP-specific headers (`MCP-Session-Id`, `MCP-Protocol-Version`)
- Support long-lived SSE connections (1-hour timeout)
- Disable response buffering for real-time event streaming

### Authentication (licensed tier)

The licensed proxy tier implements authentication and rate limiting for MCP server access. This aligns with the MCP spec's requirements for OAuth 2.1 with PKCE on HTTP-based transports.

### Server discovery

The MCP spec roadmap includes `.well-known` metadata for server discovery (targeted for the June 2026 spec release). This will allow clients to discover MCP server capabilities without establishing a live connection. Future versions of mcp.hosting will support this once the spec is finalized.
