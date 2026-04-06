# Deploy mcp.hosting on Fly.io

## Quick start

```bash
# 1. Launch the app (uses fly.toml from this directory)
fly launch --copy-config

# 2. Create backing services
fly postgres create
fly redis create

# 3. Set secrets
fly secrets set DATABASE_URL=postgres://... REDIS_URL=redis://... COOKIE_SECRET=...

# 4. Deploy
fly deploy
```

## Configuration

Edit `fly.toml` to set your region, environment variables, and scaling preferences.

Secrets (set via `fly secrets set`):

| Secret | Description |
|---|---|
| `DATABASE_URL` | Postgres connection string |
| `REDIS_URL` | Redis/Valkey connection string |
| `COOKIE_SECRET` | Random string for session cookies |
| `MCP_HOSTING_LICENSE_KEY` | License key from [mcp.hosting/pricing](https://mcp.hosting/pricing) |

## DNS

Point your domain and wildcard to the Fly app:

```
CNAME  mcp.example.com    → mcp-hosting.fly.dev
CNAME  *.mcp.example.com  → mcp-hosting.fly.dev
```

Then add the custom domain:

```bash
fly certs add mcp.example.com
fly certs add "*.mcp.example.com"
```
