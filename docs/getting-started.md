# Getting started

Step-by-step walkthrough for bringing up a production self-hosted instance of mcp.hosting on a single Linux server via Docker Compose. For Kubernetes, jump to the [Helm chart](../helm/mcp-hosting/).

> **Looking for a faster path?** If you're deploying to **Fly.io** or **Google Cloud Run**, the [`fly/bootstrap.sh`](../fly/bootstrap.sh) and [`cloudrun/bootstrap.sh`](../cloudrun/bootstrap.sh) scripts collapse all the provisioning (app + Postgres + Redis + image mirror + secrets + deploy) into one interactive command. Use those if you want one-liner setup; follow this guide for the Compose-on-a-VM path.

## 0. Prerequisite — Team subscription

Self-host is a **Team**-plan capability. Before anything else:

1. Buy a Team subscription at [mcp.hosting/pricing](https://mcp.hosting/pricing) ($15/seat/month).
2. Open the hosted dashboard at **Settings → Self-host**.
3. Copy two values that were issued on subscription creation:
   - **License key** — `mcph_sh_<hex>`. Sets `MCP_HOSTING_LICENSE_KEY` inside the running container.
   - **GHCR pull token** — `mcph_ghcr_<hex>`. Used once with `docker login ghcr.io` so your Docker client can fetch the private image.

Without an active Team subscription there is no path to self-host — free tier is hosted-only at [mcp.hosting](https://mcp.hosting).

## 1. Server

- Ubuntu 22.04+ (or any modern Linux) with a public IPv4 address.
- Docker Engine 24+ and Docker Compose v2+ installed.
- 2 GB RAM / 2 vCPU / 20 GB disk is the minimum. For a team of 25 active users, double that.
- Ports 80 and 443 open to the internet (Caddy binds them for TLS).

> **Bringing your own Postgres?** The bundled Compose uses
> `pgvector/pgvector:pg18`, which is PostgreSQL 18 with the `vector`
> extension pre-installed. If you're pointing at external managed
> Postgres (RDS, Cloud SQL, Supabase, Azure Database, etc.), **enable
> pgvector before first boot**:
>
> ```sql
> CREATE EXTENSION IF NOT EXISTS vector;
> ```
>
> The startup migrations assume it's available. Without it, the app
> crash-loops on the very first migration. AWS RDS enables it from the
> Parameter Group or via `CREATE EXTENSION`; Cloud SQL exposes it as a
> flag; managed Postgres providers generally list pgvector among their
> supported extensions — check your provider's docs if you don't see
> it available.

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

# Authenticate to the private GHCR image (one-time per host)
echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin

cp .env.example .env
```

Edit `.env` and fill in the required variables:

| Variable | Required | Notes |
|---|---|---|
| `DOMAIN` | Yes | `mcp.example.com` — no protocol prefix. Passed to the app as `BASE_DOMAIN`. |
| `POSTGRES_PASSWORD` + `DATABASE_URL` | Yes | Match both — the URL embeds the password |
| `COOKIE_SECRET` | Yes | `openssl rand -hex 32` |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | Yes | GitHub OAuth app — dashboard sign-in |
| `EMAIL_FROM` | Yes | Verified SES sender |
| `AWS_REGION` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Yes | For SES |
| `MCP_HOSTING_LICENSE_KEY` | Yes | `mcph_sh_<hex>` from mcp.hosting → Settings → Self-host. App refuses to boot without it. |

## 5. Boot

Before the first boot, run the preflight check — catches typos,
forgotten placeholders, and mismatched password-vs-DATABASE_URL combos:

```bash
bash ../scripts/validate-env.sh
```

If that reports `ok`, bring the stack up:

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

## 8. License validation behaviour

The license key set in step 4 validates against `mcp.hosting/api/license/validate` on first boot and once per hour after that. If the license server is unreachable after a successful validation, the cached state stays valid for 24 hours; after that the app returns HTTP 503 until validation recovers. Full lifecycle: [docs/license.md](./license.md).

## 9. Health check + monitoring

`GET /health` returns 200 when the service is up. Point any uptime monitor at `https://mcp.example.com/health`.

## 10. Backups + upgrades

- Set up `scripts/backup.sh` on a nightly cron — see [docs/backup-restore.md](./backup-restore.md).
- When a new image ships, `docker compose pull && docker compose up -d`. Migrations run automatically on boot. Rollback procedure: [docs/upgrade.md](./upgrade.md).

## 11. Hardening

- **Firewall:** only 80 and 443 should be open. Block direct access to 5432 (Postgres) and 6379 (Redis).
- **Backups:** tested restore end-to-end at least once before you rely on them.
- **Secrets:** `.env` is gitignored. Don't commit it. Store it outside the repo or in your secret manager.
- **License + image pull:** both the license validation and the GHCR pull token require outbound HTTPS. Whitelist `mcp.hosting:443` and `ghcr.io:443`. If either is blocked, the app either refuses to boot or degrades to 503 after the 24-hour grace window.

## 12. What to read next

- [docs/mcph-client.md](./mcph-client.md) — team member onboarding.
- [docs/license.md](./license.md) — license behaviour + troubleshooting.
- [docs/troubleshooting.md](./troubleshooting.md) — common issues.
- [docs/upgrade.md](./upgrade.md) — rolling a new image + rollback.
- [docs/backup-restore.md](./backup-restore.md) — Postgres dump + restore.
