# License keys

Paid features on a self-hosted instance are gated by `MCP_HOSTING_LICENSE_KEY`. Without a key, the instance runs as free-tier — the mcph orchestrator, dashboard, 3-server-per-user limit, 7-day analytics retention. With a key, the plan attached to it enables Pro or Team features (unlimited servers, 30-day retention, Team admin controls, priority support).

## Lifecycle

### Purchase

Buy a plan at [mcp.hosting/pricing](https://mcp.hosting/pricing). LemonSqueezy emails the key immediately after checkout. Format: `lk_live_<random>`.

### Activation

Set the env var and restart the app container:

```bash
# Docker Compose
echo "MCP_HOSTING_LICENSE_KEY=lk_live_..." >> .env
docker compose restart mcp-hosting-app

# Helm
helm upgrade mcp-hosting ./helm/mcp-hosting \
  --set licenseKey=lk_live_... \
  --reuse-values
```

### Validation flow

On every boot:

1. App reads `MCP_HOSTING_LICENSE_KEY` from the environment.
2. POSTs to `https://mcp.hosting/api/license/validate` with the key in the body.
3. Caches the response in memory for 24 hours.
4. Sets up a background timer that revalidates every 24 hours.

If the initial validation succeeds, the plan + features are applied immediately. If it fails (network error, API down), the app boots in free-tier mode and logs a warning — the background timer keeps retrying.

### Grace period

If the license API becomes unreachable AFTER a successful validation (e.g. your egress firewall starts blocking outbound HTTPS), the cached license stays active for **7 days**. During that window the app keeps revalidating in the background. After 7 days with no successful check, the app drops back to free-tier features until the next successful validation.

Grace-period tuning is intentional: self-hosted instances in restrictive networks need a buffer, but we don't want permanent offline use of paid features. 7 days is roughly one business-week of downtime, which covers all sensible network outages.

## Troubleshooting

### "I set the key but paid features aren't on"

Check the app startup logs:

```bash
docker compose logs mcp-hosting-app | grep -i license
```

Expected on a healthy activation:

```
license_init: Validating license key on startup...
license_init: License validated: plan=pro, valid=true
```

Failure modes:

| Log line | Cause | Fix |
|---|---|---|
| `No MCP_HOSTING_LICENSE_KEY set, license features disabled` | Env var not passed through | Check `.env` is loaded; redeploy |
| `Could not reach license API on startup. Starting with free features.` | Outbound HTTPS to mcp.hosting blocked | Allow egress to `mcp.hosting` port 443 |
| `License validated: plan=free, valid=false` | Key is revoked, refunded, or expired | Check subscription status on LemonSqueezy; contact support |

### "Do I need to keep the key secret?"

Yes — treat it like any other credential. Anyone with the key can turn on paid features on their own instance. Rotate by cancelling + re-buying if you believe it's leaked.

### "What happens on key rotation?"

Update the env var, restart the app. Old key is invalidated immediately on the license API side. Current-app cached state is torn down on container restart.

### "Will my existing data survive license changes?"

Yes. License state is orthogonal to data — user accounts, MCP servers, tokens, analytics all persist through activation / deactivation / key rotation. Downgrades to free-tier just disable features (e.g. pause servers beyond the 3-per-user limit); data is preserved.

### "Can I run fully offline / air-gapped?"

Today, no. The license validation handshake requires reachability to `mcp.hosting` at boot, and re-validation within the 7-day grace window. If you need fully-air-gapped operation, email [support@mcp.hosting](mailto:support@mcp.hosting) — we're open to exceptions for specific use cases (typically involves a time-bound offline license with manual renewal).

## Related

- [docs/troubleshooting.md](./troubleshooting.md) — broader issue list.
- [LemonSqueezy subscription management](https://app.lemonsqueezy.com/) — cancel, change plan, view invoices.
