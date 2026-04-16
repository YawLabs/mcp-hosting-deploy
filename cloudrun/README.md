# Deploy to Google Cloud Run

Cloud Run provides a fully managed serverless container platform with automatic TLS, scaling, and pay-per-use pricing.

## Prerequisites

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`) and [Docker](https://docs.docker.com/engine/install/)
- A GCP project with billing enabled
- Active **Team** subscription at [mcp.hosting/#pricing](https://mcp.hosting/#pricing). Copy your self-host license key and GHCR pull token from the hosted dashboard at **Settings → Self-host**.

## One-command setup

The `bootstrap.sh` script in this directory collapses all of the Artifact Registry + Cloud SQL + Memorystore + VPC connector + image-mirror + Secret Manager + Cloud Run deploy into a single interactive run:

```bash
GCP_PROJECT=my-gcp-project REGION=us-central1 bash bootstrap.sh
```

It's idempotent — re-run safely if something fails partway, or use it for upgrades (it'll re-mirror the latest GHCR tag and redeploy). The long form below is the manual equivalent if you want to customise each step or plug into existing Cloud SQL / Memorystore you already run.

## Manual steps (if not using bootstrap.sh)

Manual prerequisites beyond the above:
- Cloud SQL PostgreSQL instance (or use [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/postgres/connect-run))
- Memorystore Redis instance (or use the Valkey sidecar pattern)

## Mirror the private image into Artifact Registry

Cloud Run can only pull images from registries where its service account has read access. Mirror the private GHCR image into your project's Artifact Registry once, then point Cloud Run at the mirror:

```bash
# One-time: create an Artifact Registry repository
gcloud artifacts repositories create mcp-hosting \
  --repository-format=docker \
  --location=us-central1

# Pull the private image from GHCR, retag for Artifact Registry, push
echo $MCPH_GHCR_TOKEN | docker login ghcr.io -u self-host --password-stdin
docker pull ghcr.io/yawlabs/mcp-hosting:latest
docker tag ghcr.io/yawlabs/mcp-hosting:latest \
  us-central1-docker.pkg.dev/YOUR_PROJECT_ID/mcp-hosting/mcp-hosting:latest
gcloud auth configure-docker us-central1-docker.pkg.dev
docker push us-central1-docker.pkg.dev/YOUR_PROJECT_ID/mcp-hosting/mcp-hosting:latest
```

Re-run the pull/tag/push on every upgrade to pick up a new GHCR tag.

## Deploy

```bash
# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Deploy the service (pointing at the Artifact Registry mirror, not GHCR)
gcloud run deploy mcp-hosting \
  --image us-central1-docker.pkg.dev/YOUR_PROJECT_ID/mcp-hosting/mcp-hosting:latest \
  --platform managed \
  --region us-central1 \
  --port 3000 \
  --allow-unauthenticated \
  --min-instances 1 \
  --max-instances 10 \
  --cpu 1 \
  --memory 512Mi \
  --timeout 3600 \
  --set-env-vars "SELF_HOSTED=true" \
  --set-env-vars "NODE_ENV=production" \
  --set-env-vars "BASE_DOMAIN=mcp.example.com" \
  --set-env-vars "REDIS_HOST=YOUR_REDIS_HOST" \
  --set-env-vars "REDIS_PORT=6379" \
  --set-env-vars "REDIS_TLS=true" \
  --set-env-vars "DATABASE_SSL=require" \
  --set-secrets "REDIS_AUTH_TOKEN=mcp-hosting-redis-auth:latest" \
  --set-secrets "GITHUB_CLIENT_ID=mcp-hosting-gh-client-id:latest" \
  --set-secrets "GITHUB_CLIENT_SECRET=mcp-hosting-gh-client-secret:latest" \
  --set-secrets "DATABASE_URL=mcp-hosting-db-url:latest" \
  --set-secrets "COOKIE_SECRET=mcp-hosting-cookie-secret:latest" \
  --set-secrets "MCP_HOSTING_LICENSE_KEY=mcp-hosting-license-key:latest"
```

`MCP_HOSTING_LICENSE_KEY` is required — the app refuses to boot without a valid Team license. Store it in Secret Manager alongside your other secrets.

## Secrets

Store sensitive values in [Secret Manager](https://cloud.google.com/secret-manager):

```bash
echo -n "postgresql://user:pass@host:5432/mcphosting" | \
  gcloud secrets create mcp-hosting-db-url --data-file=-

echo -n "$(openssl rand -hex 32)" | \
  gcloud secrets create mcp-hosting-cookie-secret --data-file=-
```

## Custom domain

1. Map your domain in Cloud Run: `gcloud run domain-mappings create --service mcp-hosting --domain mcp.example.com`
2. Add the DNS records shown by the command

## Notes

- Cloud Run natively handles TLS, so Caddy is not needed
- SSE / Streamable HTTP connections work with `--timeout 3600`
- Set `--cpu-throttling=false` to keep the CPU always allocated (required for background tasks)
