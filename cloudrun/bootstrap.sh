#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mcp.hosting self-host — Google Cloud Run bootstrap
# =============================================================================
# One-shot setup script: creates Artifact Registry, Cloud SQL (Postgres),
# Memorystore (Redis), mirrors the private GHCR image into Artifact
# Registry, writes secrets to Secret Manager, and deploys to Cloud Run.
#
# Idempotent: re-running skips resources that already exist. Safe to run
# again after a partial failure.
#
# Prerequisites on the running machine:
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - docker running (used to mirror the private image)
#   - A GCP project with billing enabled
#   - An active Team subscription at mcp.hosting with:
#       * License key (mcph_sh_<hex>)
#       * GHCR pull token
#     Both visible at https://mcp.hosting/settings/self-host.
#   - A GitHub OAuth app registered at github.com/settings/developers
#     with callback URL https://<cloud-run-url>/auth/github/callback
#   - AWS SES credentials with a verified sender identity.
#
# Usage:
#   GCP_PROJECT=my-project REGION=us-central1 bash bootstrap.sh
#
# All values needed beyond GCP_PROJECT/REGION are prompted interactively.
# =============================================================================

GCP_PROJECT="${GCP_PROJECT:-}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-mcp-hosting}"
AR_REPO="${AR_REPO:-mcp-hosting}"
SQL_INSTANCE="${SQL_INSTANCE:-mcp-hosting-db}"
REDIS_INSTANCE="${REDIS_INSTANCE:-mcp-hosting-cache}"

log()  { printf '\n\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH. Install and re-run."
}

prompt_secret() {
  local varname="$1" prompt="$2" current
  current="${!varname:-}"
  if [[ -n "$current" ]]; then return 0; fi
  printf '%s: ' "$prompt" >&2
  IFS= read -rs value
  printf '\n' >&2
  export "$varname=$value"
}

prompt_value() {
  local varname="$1" prompt="$2" default="${3:-}" current
  current="${!varname:-}"
  if [[ -n "$current" ]]; then return 0; fi
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r value
  value="${value:-$default}"
  export "$varname=$value"
}

ensure_secret() {
  local name="$1" value="$2"
  if gcloud secrets describe "$name" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=- --project="$GCP_PROJECT"
  else
    printf '%s' "$value" | gcloud secrets create "$name" --data-file=- --project="$GCP_PROJECT"
  fi
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
require_cmd gcloud
require_cmd docker
require_cmd openssl

[[ -n "$GCP_PROJECT" ]] || prompt_value GCP_PROJECT "GCP project ID"
gcloud config set project "$GCP_PROJECT" >/dev/null

log "Enabling required GCP services (sqladmin, redis, artifactregistry, run, secretmanager)"
gcloud services enable \
  sqladmin.googleapis.com \
  redis.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  vpcaccess.googleapis.com \
  --project="$GCP_PROJECT"

# -----------------------------------------------------------------------------
# Gather secrets interactively
# -----------------------------------------------------------------------------
log "Gathering secrets (use ctrl-c to abort; secret values are not echoed)"
prompt_secret MCPH_GHCR_TOKEN           "GHCR pull token (mcph_ghcr_...)"
prompt_secret MCP_HOSTING_LICENSE_KEY   "License key (mcph_sh_...)"
prompt_value  GITHUB_CLIENT_ID          "GitHub OAuth client ID"
prompt_secret GITHUB_CLIENT_SECRET      "GitHub OAuth client secret"
prompt_value  AWS_REGION                "AWS region for SES" "us-east-1"
prompt_value  AWS_ACCESS_KEY_ID         "AWS access key ID (for SES)"
prompt_secret AWS_SECRET_ACCESS_KEY     "AWS secret access key"
prompt_value  EMAIL_FROM                "Verified SES sender address"
prompt_value  DOMAIN                    "Public domain (passed to the app as BASE_DOMAIN)"

COOKIE_SECRET="$(openssl rand -hex 32)"
SQL_PASSWORD="$(openssl rand -hex 16)"

# -----------------------------------------------------------------------------
# 1. Artifact Registry repo
# -----------------------------------------------------------------------------
log "1/7 Ensuring Artifact Registry repo: $AR_REPO"
if gcloud artifacts repositories describe "$AR_REPO" \
    --location="$REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  log "Artifact Registry $AR_REPO already exists"
else
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$GCP_PROJECT"
fi

# -----------------------------------------------------------------------------
# 2. Cloud SQL Postgres
# -----------------------------------------------------------------------------
log "2/7 Ensuring Cloud SQL instance: $SQL_INSTANCE"
if gcloud sql instances describe "$SQL_INSTANCE" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  log "Cloud SQL instance $SQL_INSTANCE already exists"
else
  log "Creating Cloud SQL instance (this takes ~5 minutes)"
  gcloud sql instances create "$SQL_INSTANCE" \
    --database-version=POSTGRES_16 \
    --tier=db-f1-micro \
    --region="$REGION" \
    --storage-size=10GB \
    --storage-auto-increase \
    --backup-start-time=03:00 \
    --project="$GCP_PROJECT"

  gcloud sql users set-password postgres \
    --instance="$SQL_INSTANCE" \
    --password="$SQL_PASSWORD" \
    --project="$GCP_PROJECT"
fi

if gcloud sql databases describe mcphosting \
    --instance="$SQL_INSTANCE" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  log "Database 'mcphosting' already exists"
else
  gcloud sql databases create mcphosting \
    --instance="$SQL_INSTANCE" --project="$GCP_PROJECT"
fi

SQL_CONNECTION_NAME="$(gcloud sql instances describe "$SQL_INSTANCE" \
  --project="$GCP_PROJECT" \
  --format='value(connectionName)')"

# Cloud Run connects to Cloud SQL via the unix socket the sidecar mounts
# at /cloudsql/<CONNECTION>. The DB URL uses host=/cloudsql/... and the
# driver reads it as a unix socket.
DATABASE_URL="postgresql://postgres:${SQL_PASSWORD}@/mcphosting?host=/cloudsql/${SQL_CONNECTION_NAME}"

# -----------------------------------------------------------------------------
# 3. Memorystore Redis
# -----------------------------------------------------------------------------
log "3/7 Ensuring Memorystore Redis: $REDIS_INSTANCE"
if gcloud redis instances describe "$REDIS_INSTANCE" \
    --region="$REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  log "Memorystore instance $REDIS_INSTANCE already exists"
else
  log "Creating Memorystore Redis (this takes ~3 minutes)"
  gcloud redis instances create "$REDIS_INSTANCE" \
    --size=1 \
    --region="$REGION" \
    --redis-version=redis_7_0 \
    --tier=basic \
    --project="$GCP_PROJECT"
fi

REDIS_HOST="$(gcloud redis instances describe "$REDIS_INSTANCE" \
  --region="$REGION" --project="$GCP_PROJECT" \
  --format='value(host)')"
REDIS_PORT="$(gcloud redis instances describe "$REDIS_INSTANCE" \
  --region="$REGION" --project="$GCP_PROJECT" \
  --format='value(port)')"

# Memorystore basic tier doesn't require AUTH, but the app reads the
# env var regardless — set it empty (app treats '' as no-auth).
REDIS_AUTH_TOKEN=""

# Cloud Run needs a VPC connector to reach Memorystore's private IP.
VPC_CONNECTOR="${SERVICE_NAME}-vpc"
log "Ensuring VPC access connector: $VPC_CONNECTOR"
if gcloud compute networks vpc-access connectors describe "$VPC_CONNECTOR" \
    --region="$REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  log "VPC connector $VPC_CONNECTOR already exists"
else
  gcloud compute networks vpc-access connectors create "$VPC_CONNECTOR" \
    --region="$REGION" \
    --network=default \
    --range=10.8.0.0/28 \
    --project="$GCP_PROJECT"
fi

# -----------------------------------------------------------------------------
# 4. Mirror GHCR image into Artifact Registry
# -----------------------------------------------------------------------------
log "4/7 Mirroring ghcr.io/yawlabs/mcp-hosting into Artifact Registry"
echo "$MCPH_GHCR_TOKEN" | docker login ghcr.io -u self-host --password-stdin

docker pull ghcr.io/yawlabs/mcp-hosting:latest

AR_IMAGE="${REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/mcp-hosting:latest"
docker tag ghcr.io/yawlabs/mcp-hosting:latest "$AR_IMAGE"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker push "$AR_IMAGE"

# -----------------------------------------------------------------------------
# 5. Write secrets to Secret Manager
# -----------------------------------------------------------------------------
log "5/7 Writing secrets to Secret Manager"
ensure_secret "${SERVICE_NAME}-db-url"        "$DATABASE_URL"
ensure_secret "${SERVICE_NAME}-cookie-secret" "$COOKIE_SECRET"
ensure_secret "${SERVICE_NAME}-license-key"   "$MCP_HOSTING_LICENSE_KEY"
ensure_secret "${SERVICE_NAME}-gh-client-id"  "$GITHUB_CLIENT_ID"
ensure_secret "${SERVICE_NAME}-gh-client-secret" "$GITHUB_CLIENT_SECRET"
ensure_secret "${SERVICE_NAME}-aws-key"       "$AWS_ACCESS_KEY_ID"
ensure_secret "${SERVICE_NAME}-aws-secret"    "$AWS_SECRET_ACCESS_KEY"

# Grant the Cloud Run service account access to the secrets
SA="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
for secret in db-url cookie-secret license-key gh-client-id gh-client-secret aws-key aws-secret; do
  gcloud secrets add-iam-policy-binding "${SERVICE_NAME}-${secret}" \
    --member="serviceAccount:${SA}" \
    --role=roles/secretmanager.secretAccessor \
    --project="$GCP_PROJECT" \
    --quiet >/dev/null 2>&1 || true
done

# -----------------------------------------------------------------------------
# 6. Deploy to Cloud Run
# -----------------------------------------------------------------------------
log "6/7 Deploying to Cloud Run"
gcloud run deploy "$SERVICE_NAME" \
  --image="$AR_IMAGE" \
  --platform=managed \
  --region="$REGION" \
  --project="$GCP_PROJECT" \
  --port=3000 \
  --allow-unauthenticated \
  --min-instances=1 \
  --max-instances=10 \
  --cpu=1 \
  --memory=512Mi \
  --timeout=3600 \
  --cpu-throttling=false \
  --add-cloudsql-instances="$SQL_CONNECTION_NAME" \
  --vpc-connector="$VPC_CONNECTOR" \
  --vpc-egress=private-ranges-only \
  --set-env-vars="SELF_HOSTED=true,NODE_ENV=production,BASE_DOMAIN=${DOMAIN},REDIS_HOST=${REDIS_HOST},REDIS_PORT=${REDIS_PORT},REDIS_AUTH_TOKEN=${REDIS_AUTH_TOKEN},AWS_REGION=${AWS_REGION},EMAIL_FROM=${EMAIL_FROM}" \
  --set-secrets="DATABASE_URL=${SERVICE_NAME}-db-url:latest,COOKIE_SECRET=${SERVICE_NAME}-cookie-secret:latest,MCP_HOSTING_LICENSE_KEY=${SERVICE_NAME}-license-key:latest,GITHUB_CLIENT_ID=${SERVICE_NAME}-gh-client-id:latest,GITHUB_CLIENT_SECRET=${SERVICE_NAME}-gh-client-secret:latest,AWS_ACCESS_KEY_ID=${SERVICE_NAME}-aws-key:latest,AWS_SECRET_ACCESS_KEY=${SERVICE_NAME}-aws-secret:latest"

# -----------------------------------------------------------------------------
# 7. Post-deploy
# -----------------------------------------------------------------------------
SERVICE_URL="$(gcloud run services describe "$SERVICE_NAME" \
  --region="$REGION" --project="$GCP_PROJECT" \
  --format='value(status.url)')"

log "7/7 Deployed."
log "Cloud Run URL: $SERVICE_URL"
log "Health: curl -sf ${SERVICE_URL}/health"
log ""
log "Custom domain: run"
log "  gcloud run domain-mappings create \\"
log "    --service=$SERVICE_NAME --domain=$DOMAIN --region=$REGION"
log ""
log "Upgrades: re-run this script. Steps 1-3 are idempotent; steps 4-6"
log "pull the latest GHCR tag, push a fresh Artifact Registry tag, and"
log "redeploy."
