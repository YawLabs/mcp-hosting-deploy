# Deploy mcp.hosting on Fly.io

Single-domain deploy on Fly's managed platform. No wildcard DNS needed — consumer self-host uses one domain.

## Quick start

```bash
# 1. Install flyctl and sign in
curl -L https://fly.io/install.sh | sh
fly auth login

# 2. Launch the app from this directory (reuses fly.toml)
cd fly
fly launch --copy-config --no-deploy

# 3. Provision backing services
fly postgres create      # managed Postgres cluster; attach to your app when prompted
fly redis create          # managed Redis/Valkey (Upstash-backed)

# 4. Set secrets
#    Fly's `redis create` gives you a REDIS_URL like
#    redis://default:PASSWORD@fly-xxx.upstash.io:6379 — split it into
#    REDIS_HOST / REDIS_PORT / REDIS_AUTH_TOKEN because the app reads
#    the three pieces separately (not a URL).
fly secrets set \
  REDIS_HOST="fly-xxx.upstash.io" \
  REDIS_PORT="6379" \
  REDIS_AUTH_TOKEN="..." \
  GITHUB_CLIENT_ID="..." \
  GITHUB_CLIENT_SECRET="..." \
  COOKIE_SECRET="$(openssl rand -hex 32)" \
  AWS_ACCESS_KEY_ID=... \
  AWS_SECRET_ACCESS_KEY=... \
  AWS_REGION=us-east-1 \
  EMAIL_FROM="noreply@your-domain.example" \
  MCP_HOSTING_LICENSE_KEY="mcph_sh_..."   # optional -- omit for free-tier

# DATABASE_URL is set automatically when you attach the Postgres app.

# 5. Deploy
fly deploy
```

## Custom domain

Point a single A/AAAA or CNAME record at your Fly app, then let Fly issue the cert:

```bash
fly certs add your-domain.example
```

Add the DNS records shown by that command. Fly provisions Let's Encrypt automatically.

## Secrets

| Secret | Description |
|---|---|
| `COOKIE_SECRET` | 32+ char random string for session cookies |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub OAuth app credentials (required for dashboard sign-in) |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_AUTH_TOKEN` | Split from the `REDIS_URL` that `fly redis create` emits |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` | SES credentials for magic-link email |
| `EMAIL_FROM` | Verified SES sender identity |
| `MCP_HOSTING_LICENSE_KEY` | Team license key from mcp.hosting (optional; free-tier if unset) |

`DATABASE_URL` is injected by Fly when you attach the Postgres app. The Redis (Upstash) app emits `REDIS_URL` — you need to parse out the host, port, and password yourself and set them as three separate secrets (the app doesn't read `REDIS_URL`).

## Scaling

Bump machine count or size in `fly.toml` or via `flyctl`:

```bash
fly scale count 2             # two machines for HA
fly scale vm shared-cpu-2x    # upgrade CPU/RAM
```

## Notes

- `auto_stop_machines = "stop"` lets Fly suspend idle machines; `min_machines_running = 1` keeps one always warm so magic-link emails don't cold-start.
- Fly's HTTP edge handles TLS, so no Caddy sidecar is needed.
- SSE / Streamable HTTP works over Fly's HTTP service without extra config.
