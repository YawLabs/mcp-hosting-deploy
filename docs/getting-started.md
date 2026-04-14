# Getting started

Step-by-step walkthrough for bringing up a production self-hosted instance of mcp.hosting on a single Linux server via Docker Compose. For Kubernetes, jump to the [Helm chart](../helm/mcp-hosting/).

## 1. Server

- Ubuntu 22.04+ (or any modern Linux) with a public IPv4 address.
- Docker Engine 24+ and Docker Compose v2+ installed.
- 2 GB RAM / 2 vCPU / 20 GB disk is the minimum. For a team of 25 active users, double that.
- Ports 80 and 443 open to the internet (Caddy binds them for TLS).

## 2. Domain + DNS

Point a single A record at your server's public IP:

```
A    mcp.example.com   →   203.0.113.10
```

One A record is all you need. Caddy handles TLS automatically.

Verify the A record with `dig mcp.example.com +short` before moving on. DNS propagation is usually fast but can take up to 48 hours.

## 3. Email (AWS SES)

Magic-link login needs a verified SES sender.

1. In the AWS console → SES, verify either a sending domain or a sender address (`noreply@mcp.example.com` is a reasonable default).
2. If your SES account is still in the sandbox, either verify every recipient you intend to log in, or request production access.
3. Create an IAM user with `ses:SendEmail` + `ses:SendRawEmail` and save the access key / secret.

Without SES credentials, logins will fail — nobody can get into the dashboard.

## 4. Configure

```bash
git clone https://github.com/yawlabs/mcp-hosting-deploy.git
cd mcp-hosting-deploy/docker-compose
cp .env.example .env
```

Edit `.env` and fill in the required variables:

| Variable | Required | Notes |
|---|---|---|
| `DOMAIN` | Yes | `mcp.example.com` — no protocol prefix |
| `BASE_URL` | Yes | `https://mcp.example.com` — full URL with scheme |
| `POSTGRES_PASSWORD` + `DATABASE_URL` | Yes | Match both — the URL embeds the password |
| `COOKIE_SECRET` | Yes | `openssl rand -hex 32` |
| `EMAIL_FROM` | Yes | Verified SES sender |
| `AWS_REGION` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Yes | For SES |
| `MCP_HOSTING_LICENSE_KEY` | No | Paid features; free tier works without |

## 5. Boot

```bash
docker compose up -d
```

Then wait ~60 seconds for Caddy to provision the Let's Encrypt certificate. Check status:

```bash
docker compose ps
docker compose logs -f caddy
```

All four containers should be healthy: `mcp-hosting-app`, `postgres`, `redis`, `caddy`.

For a production deploy (resource limits + log rotation) add the prod overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

## 6. First sign-in

Open `https://mcp.example.com` in a browser. You should land on the mcp.hosting sign-in page. Enter your email — SES sends a magic-link code. Paste it in, and you're signed in as the first account on your instance.

## 7. Point mcph at your instance

Every team member who wants to use the orchestrator installs `@yawlabs/mcph` in their MCP client config, with `MCPH_URL` set to your instance:

```json
{
  "mcpServers": {
    "mcp.hosting": {
      "command": "npx",
      "args": ["-y", "@yawlabs/mcph"],
      "env": {
        "MCPH_TOKEN": "mcp_pat_...",
        "MCPH_URL": "https://mcp.example.com"
      }
    }
  }
}
```

Tokens are created in the dashboard under **Settings → API Tokens**. See [docs/mcph-client.md](./mcph-client.md) for per-client config paths (Claude Desktop, Cursor, VS Code).

## 8. License key (optional)

Running as free-tier is fine for evaluation. To unlock Pro or Team features on your self-hosted instance:

1. Buy a plan at [mcp.hosting/pricing](https://mcp.hosting/pricing). LemonSqueezy emails the key.
2. Set `MCP_HOSTING_LICENSE_KEY=lk_live_...` in `.env`.
3. `docker compose restart mcp-hosting-app`.

The app validates the key on boot, caches the result for 24 hours, and re-validates in the background. Grace period is 7 days if the license API becomes unreachable. Full lifecycle: [docs/license.md](./license.md).

## 9. Health check + monitoring

`GET /health` returns 200 when the service is up. Point any uptime monitor at `https://mcp.example.com/health`.

## 10. Backups + upgrades

- Set up `scripts/backup.sh` on a nightly cron — see [docs/backup-restore.md](./backup-restore.md).
- When a new image ships, `docker compose pull && docker compose up -d`. Migrations run automatically on boot. Rollback procedure: [docs/upgrade.md](./upgrade.md).

## 11. Hardening

- **Firewall:** only 80 and 443 should be open. Block direct access to 5432 (Postgres) and 6379 (Redis).
- **Backups:** tested restore end-to-end at least once before you rely on them.
- **Secrets:** `.env` is gitignored. Don't commit it. Store it outside the repo or in your secret manager.
- **License:** the license grace-period window is 7 days. If your firewall blocks outbound HTTPS to `mcp.hosting`, paid features drop back to free-tier after that window.

## 12. What to read next

- [docs/mcph-client.md](./mcph-client.md) — team member onboarding.
- [docs/license.md](./license.md) — license behaviour + troubleshooting.
- [docs/troubleshooting.md](./troubleshooting.md) — common issues.
- [docs/upgrade.md](./upgrade.md) — rolling a new image + rollback.
- [docs/backup-restore.md](./backup-restore.md) — Postgres dump + restore.
