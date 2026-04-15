# GHCR pull token for the self-host image

The `ghcr.io/yawlabs/mcp-hosting` image is private. You need a scoped pull token to fetch it. Every Team subscription at [mcp.hosting/pricing](https://mcp.hosting/pricing) issues one alongside the license key.

## Where to find the token

1. Sign in at [mcp.hosting](https://mcp.hosting) with the account attached to your Team subscription.
2. Go to **Settings → Self-host**.
3. Copy the value under **GHCR pull token**. Format: `mcph_ghcr_<32-hex-chars>`.

The login username for this token is always `self-host` (the token is scoped to only read `ghcr.io/yawlabs/mcp-hosting` and nothing else in the org).

## Per-deployment-path setup

### Docker Compose

Run `docker login` once on the host; Compose reuses the stored credentials on subsequent `docker compose pull`:

```bash
echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin
docker compose pull   # pulls the private image
docker compose up -d
```

### Kubernetes (Helm)

Create an `imagePullSecret` in the namespace once; reference it from the Helm values:

```bash
kubectl create namespace mcp-hosting
kubectl create secret docker-registry ghcr-mcp-hosting \
  --namespace mcp-hosting \
  --docker-server=ghcr.io \
  --docker-username=self-host \
  --docker-password="$MCPH_GHCR_TOKEN"
```

`helm/mcp-hosting/values.yaml` ships with `imagePullSecrets: [{ name: ghcr-mcp-hosting }]` — no additional config needed as long as the secret name matches.

### Fly.io

Fly can't pull from third-party private registries directly, so mirror the image into Fly's registry:

```bash
echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin
docker pull ghcr.io/yawlabs/mcp-hosting:latest
fly auth docker
docker tag ghcr.io/yawlabs/mcp-hosting:latest registry.fly.io/<app-name>:deployment-$(date +%s)
docker push registry.fly.io/<app-name>:deployment-$(date +%s)
# Update fly.toml's `image = ` to point at the new registry.fly.io tag, then:
fly deploy
```

Re-run these steps on every upgrade (see [docs/upgrade.md](./upgrade.md)).

### Cloud Run

Cloud Run requires the image to live in a Google-owned registry. Mirror from GHCR to Artifact Registry:

```bash
gcloud artifacts repositories create mcp-hosting \
  --repository-format=docker --location=us-central1

echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin
docker pull ghcr.io/yawlabs/mcp-hosting:latest
docker tag ghcr.io/yawlabs/mcp-hosting:latest \
  us-central1-docker.pkg.dev/YOUR_PROJECT_ID/mcp-hosting/mcp-hosting:latest
gcloud auth configure-docker us-central1-docker.pkg.dev
docker push us-central1-docker.pkg.dev/YOUR_PROJECT_ID/mcp-hosting/mcp-hosting:latest
```

Point Cloud Run at the Artifact Registry path, not the GHCR one. Re-mirror on upgrades.

## Token rotation

The token is distinct from the license key and rotates independently. If you believe it's leaked, click **Rotate GHCR token** in **Settings → Self-host**. The previous token is revoked immediately; your existing `docker login` sessions continue to work until they expire, but new pulls require the fresh token.

## Token lifecycle

- **Issued:** automatically on Team subscription creation.
- **Revoked:** automatically when the subscription lapses (cancellation, refund, payment failure past the dunning window). A revoked token returns HTTP 401 from GHCR; existing running containers continue to work, but `docker compose pull` / image upgrades will fail.
- **Scope:** read-only, restricted to `ghcr.io/yawlabs/mcp-hosting` only. It cannot list or pull any other package in the org.

## Troubleshooting

### `unauthorized: authentication required`

The token is missing, expired, or for a different username. Verify:

```bash
cat ~/.docker/config.json | grep -A2 ghcr.io
docker login ghcr.io -u self-host   # re-authenticate
```

### `denied: installation not allowed to Get "mcp-hosting"`

The token has been revoked on the license-server side — your subscription is inactive. Check [LemonSqueezy](https://app.lemonsqueezy.com/) for your subscription status.

### Existing running container is fine, but new pulls fail

Expected behaviour when a token is revoked mid-subscription (e.g. rotation while still active, or a subscription lapse). Running containers keep running; upgrades require a fresh token.
