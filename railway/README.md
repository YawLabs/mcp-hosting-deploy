# Deploy mcp.hosting on Railway

<!-- TODO: Replace TEMPLATE_ID with actual Railway template ID once created -->
[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/TEMPLATE_ID)

## Quick start

1. Click the deploy button above (once the template is published), or:

```bash
# Clone and deploy manually
railway init
railway up
```

2. Add a Postgres plugin and Redis plugin in the Railway dashboard.

3. Set environment variables in the Railway dashboard:

| Variable | Description |
|---|---|
| `DATABASE_URL` | Auto-set by Postgres plugin |
| `REDIS_URL` | Auto-set by Redis plugin |
| `COOKIE_SECRET` | Random string for session cookies |
| `MCP_HOSTING_LICENSE_KEY` | License key from [mcp.hosting/pricing](https://mcp.hosting/pricing) |
| `BASE_DOMAIN` | Your custom domain |

## Notes

- The `railway.toml` deploys from a pre-built image; no build step is needed.
- To create the Railway template, go to [railway.com/account/templates](https://railway.com/account/templates) and link this repo.
