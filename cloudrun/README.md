# Deploy to Google Cloud Run

Cloud Run provides a fully managed serverless container platform with automatic TLS, scaling, and pay-per-use pricing.

## Prerequisites

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`) and [Docker](https://docs.docker.com/engine/install/)
- A GCP project with billing enabled
- Active **Team** subscription at [mcp.hosting/#pricing](https://mcp.hosting/#pricing). Copy your self-host license key and GHCR pull token from the hosted dashboard at **Settings → Self-host**.

## One-command setup (recommended)

The `bootstrap.sh` script in this directory collapses all of the Artifact Registry + Cloud SQL + Memorystore + VPC connector + image-mirror + Secret Manager + Cloud Run deploy into a single interactive run:

```bash
GCP_PROJECT=my-gcp-project REGION=us-central1 bash bootstrap.sh
```

It's idempotent — re-run safely if something fails partway, or use it for upgrades (it'll re-mirror the latest GHCR tag and redeploy). The long form below is the manual equivalent if you want to customise each step or plug into Cloud SQL / Memorystore you already run.

---

## Manual deploy (if you can't run bootstrap.sh)

The manual path mirrors `bootstrap.sh` step-for-step. **Don't skip the VPC connector** — Cloud Run can't reach Memorystore's private IP without one, and the failure mode is "service deploys cleanly, then 502s on every request" which is hard to diagnose after the fact.

### 1. Enable APIs

```bash
gcloud services enable \
  sqladmin.googleapis.com \
  redis.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  vpcaccess.googleapis.com \
  --project=YOUR_PROJECT_ID
```

### 2. Provision Cloud SQL (Postgres)

```bash
SQL_PASSWORD="$(openssl rand -hex 16)"

gcloud sql instances create mcp-hosting-db \
  --database-version=POSTGRES_16 \
  --tier=db-f1-micro \
  --region=us-central1 \
  --storage-size=10GB \
  --storage-auto-increase \
  --backup-start-time=03:00

gcloud sql users set-password postgres \
  --instance=mcp-hosting-db \
  --password="$SQL_PASSWORD"

gcloud sql databases create mcphosting --instance=mcp-hosting-db
```

> **pgvector is required.** The startup migrations call `CREATE EXTENSION IF NOT EXISTS vector`. On Cloud SQL Postgres 15+ pgvector is available out of the box; on older versions enable it from the database flags before first deploy.

Get the connection name (used by the Cloud SQL Auth Proxy sidecar that Cloud Run injects):

```bash
SQL_CONNECTION_NAME="$(gcloud sql instances describe mcp-hosting-db \
  --format='value(connectionName)')"
echo "$SQL_CONNECTION_NAME"
# e.g. my-project:us-central1:mcp-hosting-db
```

The DATABASE_URL uses the unix socket the proxy mounts at `/cloudsql/<CONNECTION_NAME>`:

```bash
DATABASE_URL="postgresql://postgres:${SQL_PASSWORD}@/mcphosting?host=/cloudsql/${SQL_CONNECTION_NAME}"
```

### 3. Provision Memorystore (Redis)

```bash
gcloud redis instances create mcp-hosting-cache \
  --size=1 \
  --region=us-central1 \
  --redis-version=redis_7_0 \
  --tier=basic

REDIS_HOST="$(gcloud redis instances describe mcp-hosting-cache \
  --region=us-central1 --format='value(host)')"
REDIS_PORT="$(gcloud redis instances describe mcp-hosting-cache \
  --region=us-central1 --format='value(port)')"
```

Memorystore basic tier doesn't enforce AUTH; if you provision standard/HA tier with `--enable-auth`, also pull the AUTH string with `gcloud redis instances get-auth-string`.

### 4. Create a VPC connector for Cloud Run → Memorystore

Memorystore exposes a **private IP only** — Cloud Run cannot reach it without a Serverless VPC Access connector. This is the step manual deployers most often miss; without it, the service deploys cleanly and then errors on every request because Redis is unreachable.

```bash
gcloud compute networks vpc-access connectors create mcp-hosting-vpc \
  --region=us-central1 \
  --network=default \
  --range=10.8.0.0/28
```

The `/28` range must not overlap with anything already routed in the VPC. If `default` is taken, pick another `/28` from RFC1918 space.

### 5. Mirror the private GHCR image into Artifact Registry

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

### 6. Write secrets to Secret Manager

```bash
echo -n "$DATABASE_URL"                  | gcloud secrets create mcp-hosting-db-url --data-file=-
echo -n "$(openssl rand -hex 32)"        | gcloud secrets create mcp-hosting-cookie-secret --data-file=-
echo -n "mcph_sh_..."                    | gcloud secrets create mcp-hosting-license-key --data-file=-
echo -n "$GITHUB_CLIENT_ID"              | gcloud secrets create mcp-hosting-gh-client-id --data-file=-
echo -n "$GITHUB_CLIENT_SECRET"          | gcloud secrets create mcp-hosting-gh-client-secret --data-file=-
echo -n "$AWS_ACCESS_KEY_ID"             | gcloud secrets create mcp-hosting-aws-key --data-file=-
echo -n "$AWS_SECRET_ACCESS_KEY"         | gcloud secrets create mcp-hosting-aws-secret --data-file=-
```

Grant the Cloud Run runtime service account access to each secret:

```bash
SA="$(gcloud projects describe YOUR_PROJECT_ID --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
for s in db-url cookie-secret license-key gh-client-id gh-client-secret aws-key aws-secret; do
  gcloud secrets add-iam-policy-binding "mcp-hosting-${s}" \
    --member="serviceAccount:${SA}" \
    --role=roles/secretmanager.secretAccessor
done
```

### 7. Deploy

```bash
gcloud run deploy mcp-hosting \
  --image=us-central1-docker.pkg.dev/YOUR_PROJECT_ID/mcp-hosting/mcp-hosting:latest \
  --platform=managed \
  --region=us-central1 \
  --port=3000 \
  --allow-unauthenticated \
  --min-instances=1 \
  --max-instances=10 \
  --cpu=1 \
  --memory=512Mi \
  --timeout=3600 \
  --cpu-throttling=false \
  --add-cloudsql-instances="$SQL_CONNECTION_NAME" \
  --vpc-connector=mcp-hosting-vpc \
  --vpc-egress=private-ranges-only \
  --set-env-vars="SELF_HOSTED=true,NODE_ENV=production,BASE_DOMAIN=mcp.example.com,REDIS_HOST=${REDIS_HOST},REDIS_PORT=${REDIS_PORT},REDIS_AUTH_TOKEN=,REDIS_TLS=true,DATABASE_SSL=require,AWS_REGION=us-east-1,EMAIL_FROM=noreply@mcp.example.com" \
  --set-secrets="DATABASE_URL=mcp-hosting-db-url:latest,COOKIE_SECRET=mcp-hosting-cookie-secret:latest,MCP_HOSTING_LICENSE_KEY=mcp-hosting-license-key:latest,GITHUB_CLIENT_ID=mcp-hosting-gh-client-id:latest,GITHUB_CLIENT_SECRET=mcp-hosting-gh-client-secret:latest,AWS_ACCESS_KEY_ID=mcp-hosting-aws-key:latest,AWS_SECRET_ACCESS_KEY=mcp-hosting-aws-secret:latest"
```

Notes on the flags above:

- `--cpu-throttling=false` keeps CPU always allocated, so background tasks (license revalidation, magic-link email sends) don't get suspended on idle instances.
- `--add-cloudsql-instances` injects the Cloud SQL Auth Proxy sidecar that backs the unix socket in `DATABASE_URL`.
- `--vpc-connector` routes Memorystore traffic through the connector built in step 4. Without it, the service can't reach Redis.
- `--timeout=3600` matches the SSE / Streamable HTTP long-lived connection requirement.

`MCP_HOSTING_LICENSE_KEY` is required — the app refuses to boot without a valid Team license.

### 8. Migrations

The app runs database migrations automatically on first boot. Watch the deploy logs for migration completion before pointing real traffic at the service:

```bash
gcloud run services logs read mcp-hosting --region=us-central1 --limit=200
```

Look for `migrations applied` (or equivalent) before the readiness probe starts passing.

## Custom domain

1. Map your domain in Cloud Run: `gcloud run domain-mappings create --service mcp-hosting --domain mcp.example.com`
2. Add the DNS records shown by the command

## Notes

- Cloud Run natively handles TLS, so Caddy is not needed.
- SSE / Streamable HTTP connections work with `--timeout 3600`.
- `--cpu-throttling=false` is required to keep background workers (license revalidation, email sends) running on idle instances.
- For upgrades, re-run steps 5 (mirror new GHCR tag) and 7 (redeploy). Steps 1–4 and 6 are one-time setup unless you rotate secrets.
