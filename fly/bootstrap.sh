#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mcp.hosting self-host — Fly.io bootstrap
# =============================================================================
# One-shot setup script: provisions the Fly app, managed Postgres, Upstash
# Redis, mirrors the private GHCR image into registry.fly.io, sets the
# required secrets, and runs fly deploy.
#
# Idempotent: re-running skips resources that already exist. Safe to run
# again after a partial failure.
#
# Prerequisites on the running machine:
#   - flyctl installed and authenticated (fly auth login)
#   - docker running (used to mirror the private image)
#   - An active Team subscription at mcp.hosting with:
#       * License key (mcph_sh_<hex>)
#       * GHCR pull token
#     Both visible at https://mcp.hosting/settings/self-host.
#   - A GitHub OAuth app registered at github.com/settings/developers
#     with callback URL https://<your-app>.fly.dev/auth/github/callback
#     (or your custom domain's equivalent).
#   - AWS SES credentials with a verified sender identity.
#
# Usage:
#   APP_NAME=my-mcph REGION=iad bash bootstrap.sh
#
# All values needed beyond APP_NAME/REGION are prompted interactively.
# =============================================================================

# Fly app names must match [a-z0-9-]+ -- slugify whoami because some
# users have uppercase, dots, or other illegal chars in their login
# (corp SSO usernames like "John.Doe" are common).
_user_slug="$(whoami | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"
APP_NAME="${APP_NAME:-mcp-hosting-${_user_slug}}"
REGION="${REGION:-iad}"

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

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
require_cmd fly
require_cmd docker
require_cmd openssl

log "Checking fly auth status"
fly auth whoami >/dev/null || die "Not logged in to Fly. Run: fly auth login"

# -----------------------------------------------------------------------------
# Gather secrets interactively
# -----------------------------------------------------------------------------
log "Gathering secrets (use ctrl-c to abort; values are not echoed)"
prompt_secret MCPH_GHCR_TOKEN           "GHCR pull token (mcph_ghcr_...)"
prompt_secret MCP_HOSTING_LICENSE_KEY   "License key (mcph_sh_...)"
prompt_value  GITHUB_CLIENT_ID          "GitHub OAuth client ID"
prompt_secret GITHUB_CLIENT_SECRET      "GitHub OAuth client secret"
prompt_value  AWS_REGION                "AWS region for SES" "us-east-1"
prompt_value  AWS_ACCESS_KEY_ID         "AWS access key ID (for SES)"
prompt_secret AWS_SECRET_ACCESS_KEY     "AWS secret access key"
prompt_value  EMAIL_FROM                "Verified SES sender address" "noreply@$APP_NAME.fly.dev"
prompt_value  DOMAIN                    "Public domain" "$APP_NAME.fly.dev"

# Catch typos / empty paste BEFORE we do 5 minutes of Postgres + Redis
# provisioning that would only fail at the final `fly deploy` step.
[[ -n "$MCPH_GHCR_TOKEN"         ]] || die "GHCR pull token is empty"
[[ -n "$MCP_HOSTING_LICENSE_KEY" ]] || die "License key is empty"
[[ "$MCP_HOSTING_LICENSE_KEY" == mcph_sh_* ]] \
  || die "License key must start with 'mcph_sh_'. Copy it again from mcp.hosting → Settings → Self-host."
[[ -n "$GITHUB_CLIENT_SECRET"    ]] || die "GitHub OAuth client secret is empty"
[[ -n "$AWS_SECRET_ACCESS_KEY"   ]] || die "AWS secret access key is empty"

COOKIE_SECRET="$(openssl rand -hex 32)"

# -----------------------------------------------------------------------------
# 1. Create the Fly app if it doesn't exist
# -----------------------------------------------------------------------------
log "1/6 Ensuring Fly app: $APP_NAME"
if fly apps list --json 2>/dev/null | grep -q "\"Name\":\"$APP_NAME\""; then
  log "Fly app $APP_NAME already exists, skipping launch"
else
  log "Creating Fly app $APP_NAME in $REGION"
  fly apps create "$APP_NAME" --org personal
fi

# -----------------------------------------------------------------------------
# 2. Ensure managed Postgres (attach if exists, create+attach otherwise)
# -----------------------------------------------------------------------------
PG_APP="${APP_NAME}-db"
log "2/6 Ensuring Postgres cluster: $PG_APP"
if fly apps list --json 2>/dev/null | grep -q "\"Name\":\"$PG_APP\""; then
  log "Postgres cluster $PG_APP already exists"
else
  log "Creating Postgres cluster $PG_APP"
  fly postgres create \
    --name "$PG_APP" \
    --region "$REGION" \
    --initial-cluster-size 1 \
    --vm-size shared-cpu-1x \
    --volume-size 10 \
    --password "$(openssl rand -hex 16)"
fi

# Attach is idempotent-ish: it sets DATABASE_URL on the app. If already
# attached, it 422s with "database already attached" -- tolerate that
# specifically. The naive `... | grep -v "already attached" || true`
# under `set -euo pipefail` swallows EVERY failure (auth, network,
# 5xx), leaving DATABASE_URL unset and crash-looping the app at boot.
# Capture output, check exit, and only forgive the known-benign case.
log "Attaching Postgres to $APP_NAME (creates DATABASE_URL secret)"
set +e
attach_output="$(fly postgres attach "$PG_APP" --app "$APP_NAME" --database-name mcphosting 2>&1)"
attach_exit=$?
set -e
if [[ $attach_exit -ne 0 ]]; then
  if grep -q "already attached" <<<"$attach_output"; then
    log "Postgres already attached to $APP_NAME"
  else
    printf '%s\n' "$attach_output" >&2
    die "fly postgres attach failed (see error above)"
  fi
fi

# -----------------------------------------------------------------------------
# 3. Ensure Upstash Redis; split the emitted REDIS_URL into HOST/PORT/AUTH
# -----------------------------------------------------------------------------
REDIS_APP="${APP_NAME}-cache"
log "3/6 Ensuring Upstash Redis: $REDIS_APP"

REDIS_URL=""
if fly redis list --json 2>/dev/null | grep -q "\"Name\":\"$REDIS_APP\""; then
  log "Redis $REDIS_APP already exists"
  REDIS_URL="$(fly redis status "$REDIS_APP" --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("PrivateURL","") or d.get("PublicURL",""))')"
else
  log "Creating Upstash Redis $REDIS_APP"
  # `fly redis create` is interactive by default. --plan free + --region
  # inline + --no-replicas avoid the prompts.
  REDIS_URL="$(fly redis create \
    --name "$REDIS_APP" \
    --region "$REGION" \
    --plan free \
    --no-replicas 2>&1 | grep -oE 'redis://[^ ]+' | head -1)"
fi

[[ -n "$REDIS_URL" ]] || die "Could not determine REDIS_URL for $REDIS_APP"

# Parse redis://default:PASSWORD@HOST:PORT
REDIS_HOST="$(printf '%s' "$REDIS_URL" | sed -E 's|redis://[^@]+@([^:]+):.*|\1|')"
REDIS_PORT="$(printf '%s' "$REDIS_URL" | sed -E 's|redis://[^@]+@[^:]+:([0-9]+).*|\1|')"
REDIS_AUTH_TOKEN="$(printf '%s' "$REDIS_URL" | sed -E 's|redis://[^:]+:([^@]+)@.*|\1|')"

# -----------------------------------------------------------------------------
# 4. Mirror private GHCR image into registry.fly.io
# -----------------------------------------------------------------------------
log "4/6 Mirroring ghcr.io/yawlabs/mcp-hosting into registry.fly.io"
echo "$MCPH_GHCR_TOKEN" | docker login ghcr.io -u self-host --password-stdin

docker pull ghcr.io/yawlabs/mcp-hosting:latest

FLY_TAG="registry.fly.io/$APP_NAME:deployment-$(date +%s)"
docker tag ghcr.io/yawlabs/mcp-hosting:latest "$FLY_TAG"

fly auth docker
docker push "$FLY_TAG"

# -----------------------------------------------------------------------------
# 5. Set all secrets
# -----------------------------------------------------------------------------
log "5/6 Setting secrets on $APP_NAME"
fly secrets set \
  --app "$APP_NAME" \
  REDIS_HOST="$REDIS_HOST" \
  REDIS_PORT="$REDIS_PORT" \
  REDIS_AUTH_TOKEN="$REDIS_AUTH_TOKEN" \
  REDIS_TLS="true" \
  COOKIE_SECRET="$COOKIE_SECRET" \
  GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
  GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
  AWS_REGION="$AWS_REGION" \
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  EMAIL_FROM="$EMAIL_FROM" \
  BASE_DOMAIN="$DOMAIN" \
  MCP_HOSTING_LICENSE_KEY="$MCP_HOSTING_LICENSE_KEY"

# -----------------------------------------------------------------------------
# 6. Deploy, pointing at the mirrored image
# -----------------------------------------------------------------------------
log "6/6 Deploying $APP_NAME from $FLY_TAG"
fly deploy \
  --app "$APP_NAME" \
  --image "$FLY_TAG" \
  --config "$(dirname "$0")/fly.toml"

# Issue a managed TLS cert for any DOMAIN that isn't the default
# <app>.fly.dev (which Fly's edge already covers). `fly certs add` is
# idempotent -- re-running for an existing cert prints status and exits 0.
if [[ "$DOMAIN" != "$APP_NAME.fly.dev" ]]; then
  log "Issuing TLS cert for $DOMAIN"
  if ! fly certs add "$DOMAIN" --app "$APP_NAME"; then
    warn "fly certs add did not succeed -- add it manually:"
    warn "  fly certs add $DOMAIN --app $APP_NAME"
    warn "Then add the DNS records the command prints."
  fi
fi

log "Done. App URL: https://$DOMAIN"
log "Health: curl -sf https://$DOMAIN/health"
log ""
log "Upgrades: re-run this script. Steps 1-3 are idempotent; steps 4-6"
log "pull the latest GHCR tag, push a fresh registry.fly.io tag, and"
log "fly deploy with it."
