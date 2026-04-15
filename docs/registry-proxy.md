# Registry proxy — per-account image pulls

An alternative to the shared GHCR pull token. Lets each self-host instance
authenticate directly with its own **license key** when pulling the
image, so rotating the token isn't a global event and revoking a
subscription instantly revokes pull access for that customer.

> **This is optional.** The default flow described in
> [`self-host-token.md`](./self-host-token.md) (shared GHCR pull token)
> still works — use whichever suits your operations.

## How it works

1. mcp.hosting runs an OCI-compliant registry proxy at
   `registry.mcp.hosting/v2/*`.
2. Your docker client does `docker login registry.mcp.hosting` with the
   license key (`mcph_sh_...`) as the password.
3. The proxy validates the license against the hosted accounts table,
   signs a 15-minute bearer token, and returns it.
4. Subsequent `docker pull` requests attach that bearer and the proxy
   forwards them to `ghcr.io`, using its own service PAT upstream.
5. GHCR's blob redirects are passed through, so actual layer downloads
   still go directly from CloudFront to your docker client.

No shared PAT ever leaves the hosted instance.

## Switching an existing install

### Docker Compose

```bash
# 1. docker login against the proxy instead of GHCR.
echo "$MCP_HOSTING_LICENSE_KEY" | docker login registry.mcp.hosting \
  --username self-host --password-stdin

# 2. Update the image reference in docker-compose.yml:
#      image: registry.mcp.hosting/yawlabs/mcp-hosting:latest
#    (from ghcr.io/yawlabs/mcp-hosting:latest)

docker compose pull mcp-hosting-app
docker compose up -d mcp-hosting-app
```

### Helm

```yaml
# values.yaml
imagePullSecrets:
  - name: mcp-hosting-registry-pull

app:
  image: registry.mcp.hosting/yawlabs/mcp-hosting
  tag: latest
```

```bash
kubectl -n mcp-hosting create secret docker-registry mcp-hosting-registry-pull \
  --docker-server=registry.mcp.hosting \
  --docker-username=self-host \
  --docker-password="$MCP_HOSTING_LICENSE_KEY"
```

### Fly / Cloud Run

Mirror the image from `registry.mcp.hosting` into your platform's
private registry the same way you would from `ghcr.io` — just swap the
source. Authenticate with your license key.

## Revocation

If a subscription lapses, the proxy's `/v2/auth` endpoint returns 403
on the next login, and any existing 15-minute bearer token expires on
its own schedule. No manual revocation needed.

## Audit

Every pull attempt lands in `audit_events` with
`action: 'ghcr_token.reveal'`, `resource: 'yawlabs/mcp-hosting'`, plus
IP + user-agent. Visible in the dashboard at
**Settings → Admin → Audit log** or via
`GET /api/account/audit?action=ghcr_token.reveal`.

## Performance

The proxy forwards blob requests as 307 redirects to GHCR's CloudFront
origin, so the actual image bytes don't flow through mcp.hosting.
Only the thin manifest + token-exchange traffic does. For a typical
image pull (20 layers, ~450 MB), the proxy sees <1 MB of traffic.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `docker login` returns 401 `license not recognised` | The key isn't in the hosted accounts table. Check Settings → Self-host license key. |
| `docker login` returns 403 `subscription inactive` | Team plan cancelled or account suspended. Check billing. |
| `docker pull` returns 401 after successful login | Bearer token expired (15-min TTL). Re-run `docker login`. |
| `docker pull` returns 502 | Hosted instance couldn't reach GHCR. Retry in a minute; if persistent, email support. |
