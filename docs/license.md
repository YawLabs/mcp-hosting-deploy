# License keys

Self-hosted instances are gated by `MCP_HOSTING_LICENSE_KEY`. Self-host is a **Team**-plan capability — every Team subscription at [mcp.hosting/pricing](https://mcp.hosting/pricing) auto-issues a self-host license key. Without a valid key, the app refuses to boot.

Free tier is hosted-only. There is no free self-host mode.

## Lifecycle

### Purchase

Buy a Team subscription at [mcp.hosting/pricing](https://mcp.hosting/pricing). On checkout, the hosted dashboard at **Settings → Self-host** shows your self-host license key and the GHCR pull token used to fetch the image.

Key format: `mcph_sh_<32-hex-chars>`.

### Activation

Set the env var and start the stack:

```bash
# Docker Compose
echo "MCP_HOSTING_LICENSE_KEY=mcph_sh_..." >> .env
docker compose up -d

# Helm
helm upgrade mcp-hosting ./helm/mcp-hosting \
  --set licenseKey=mcph_sh_... \
  --reuse-values
```

GHCR pull-token setup is a separate step — see [self-host-token.md](./self-host-token.md).

### Validation flow

On every boot:

1. App reads `MCP_HOSTING_LICENSE_KEY` from the environment.
2. POSTs to `https://mcp.hosting/api/license/validate` with the key in the body.
3. First boot: the license server stamps this instance as the owner of the key (one key, one instance).
4. Caches the response in memory; sets a background revalidation timer (every hour).

If the initial validation fails (invalid key, network error, API down, key already bound to a different instance), the app logs the reason and exits. No partial-functionality fallback.

### Grace period

If the license API becomes unreachable **after** a successful validation (e.g. egress firewall blocks outbound HTTPS), the cached validation stays valid for **24 hours**. During that window the app keeps serving requests and keeps retrying in the background. After 24 hours with no successful recheck, the app returns HTTP 503 on all routes until validation recovers.

24 hours is deliberately short — long enough to tolerate a DNS blip or a brief egress-firewall change window, short enough to surface actual network policy issues quickly. If you need longer offline tolerance, email [support@mcp.hosting](mailto:support@mcp.hosting).

### Rebinding to new hardware

On the original instance, click **Unbind installation** in **Settings → Self-host**. Then activate on the new instance. The unbind is idempotent and takes effect within 15 minutes, or instantly if you click **Revalidate now** on both sides.

## Troubleshooting

### "I set the key but the app won't start"

Check the app startup logs:

```bash
docker compose logs mcp-hosting-app | grep -i license
```

Failure modes:

| Log line | Cause | Fix |
|---|---|---|
| `No MCP_HOSTING_LICENSE_KEY set; refusing to boot` | Env var not passed through | Check `.env` is loaded; redeploy |
| `License validation failed: could not reach mcp.hosting` | Outbound HTTPS to mcp.hosting blocked | Allow egress to `mcp.hosting` port 443 |
| `License validation failed: key bound to a different installation` | Same key already activated on another instance | Unbind on the original; see "Rebinding" above |
| `License validation failed: subscription inactive` | Subscription cancelled, refunded, or past-due | Check subscription status on LemonSqueezy |

### "Do I need to keep the key secret?"

Yes — treat it like any other credential. The GHCR pull token is separate; both should be protected. If either leaks, rotate by contacting [support@mcp.hosting](mailto:support@mcp.hosting).

### "What happens on key rotation?"

Update the env var, restart the app. Old key is invalidated immediately on the license API side. The new key re-binds the instance on first successful validation.

### "Will my existing data survive license changes?"

Yes. License state is orthogonal to data — user accounts, MCP servers, tokens, analytics all persist through key rotation. A key that lapses (subscription ends) stops the app from booting but does not delete data; reactivate by renewing the subscription.

### "Can I run fully offline / air-gapped?"

Today, no. The license validation handshake requires reachability to `mcp.hosting` at boot and within the 24-hour grace window. If you need fully-air-gapped operation, email [support@mcp.hosting](mailto:support@mcp.hosting) — air-gapped deployments are handled as custom contracts.

## Related

- [docs/self-host-token.md](./self-host-token.md) — GHCR pull token / image-access setup.
- [docs/troubleshooting.md](./troubleshooting.md) — broader issue list.
- [LemonSqueezy subscription management](https://app.lemonsqueezy.com/) — cancel, change plan, view invoices.
