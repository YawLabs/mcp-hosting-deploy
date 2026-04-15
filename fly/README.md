# Deploy mcp.hosting on Fly.io

Single-domain deploy on Fly's managed platform. No wildcard DNS needed — consumer self-host uses one domain.

## Prerequisites

Grab your self-host license key + GHCR pull token from [mcp.hosting](https://mcp.hosting) → Settings → Self-host. Both are issued with every Team subscription. You need both to deploy.

## One-command setup

The `bootstrap.sh` script in this directory collapses all of the Fly app + Postgres + Redis + image-mirror + secrets setup into a single interactive run:

```bash
APP_NAME=my-mcph REGION=iad bash bootstrap.sh
```

It's idempotent — re-run safely if something fails partway, or use it for upgrades (it'll re-mirror the latest GHCR tag and redeploy). The long form below is the manual equivalent if you want to customise each step.

## Quick start

```bash
# 1. Install flyctl and sign in
curl -L https://fly.io/install.sh | sh
fly auth login

# 2. Pull the private image locally + re-push it into Fly's registry.
#    Fly pulls images as an unauthenticated client by default, so you
#    mirror the image into registry.fly.io (where Fly auths as you).
echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin
docker pull ghcr.io/yawlabs/mcp-hosting:latest
docker tag ghcr.io/yawlabs/mcp-hosting:latest registry.fly.io/<app-name>:deployment-$(date +%s)
fly auth docker
docker push registry.fly.io/<app-name>:deployment-$(date +%s)

# 3. Launch the app from this directory (reuses fly.toml).
#    Update fly.toml's `image =` to point at the registry.fly.io tag you
#    just pushed, or pass --image on the command line.
cd fly
fly launch --copy-config --no-deploy

# 4. Provision backing services
fly postgres create      # managed Postgres cluster; attach to your app when prompted
fly redis create          # managed Redis/Valkey (Upstash-backed)

# 5. Set secrets
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
  MCP_HOSTING_LICENSE_KEY="mcph_sh_..."   # REQUIRED — app refuses to boot without it

# DATABASE_URL is set automatically when you attach the Postgres app.

# 6. Deploy
fly deploy
```

Upgrades require re-running steps 2 (pull new tag from GHCR, push to registry.fly.io) before each `fly deploy`.

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
| `MCP_HOSTING_LICENSE_KEY` | Team license key from mcp.hosting (required; app refuses to boot without it) |

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
