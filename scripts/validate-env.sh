#!/usr/bin/env bash
# =============================================================================
# validate-env.sh — preflight for Docker Compose self-host deployments
# =============================================================================
# Reads docker-compose/.env and refuses to let you proceed if any
# required variable is missing, blank, or still set to the .env.example
# placeholder. Catches the most common first-boot failure modes (typos,
# forgot to change placeholder password, DATABASE_URL doesn't match
# POSTGRES_PASSWORD) before you burn 20 minutes debugging container
# crash loops.
#
# Usage:
#   bash scripts/validate-env.sh                  # checks docker-compose/.env
#   bash scripts/validate-env.sh path/to/.env     # checks specified file
#
# Exit code 0 on pass, 1 on validation failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/../docker-compose/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found" >&2
  echo "       copy docker-compose/.env.example to .env first: " >&2
  echo "         cp docker-compose/.env.example docker-compose/.env" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

ERRORS=()

require() {
  local var_name="$1" description="$2"
  local value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    ERRORS+=("$var_name is empty — $description")
  fi
}

require_nonplaceholder() {
  local var_name="$1" description="$2" banned_pattern="$3"
  local value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    ERRORS+=("$var_name is empty — $description")
  elif [[ "$value" =~ $banned_pattern ]]; then
    ERRORS+=("$var_name still set to a placeholder ('$value') — $description")
  fi
}

require DOMAIN "set your public domain (e.g. mcp.example.com, no scheme)"
require MCP_HOSTING_LICENSE_KEY "your mcph_sh_* key from hosted mcp.hosting Settings"
require_nonplaceholder POSTGRES_PASSWORD "run 'openssl rand -hex 24' to generate" "changeme|^$"
require DATABASE_URL "shape: postgresql://\$POSTGRES_USER:\$POSTGRES_PASSWORD@postgres:5432/\$POSTGRES_DB"
require_nonplaceholder COOKIE_SECRET "run 'openssl rand -hex 32' to generate" "changeme|^$"
require GITHUB_CLIENT_ID "register an OAuth app at https://github.com/settings/developers"
require GITHUB_CLIENT_SECRET "from the same OAuth app as GITHUB_CLIENT_ID"
require EMAIL_FROM "verified SES sender identity (e.g. noreply@mcp.example.com)"
require AWS_REGION "SES region (e.g. us-east-1)"
require AWS_ACCESS_KEY_ID "IAM key with ses:SendEmail + ses:SendRawEmail"
require AWS_SECRET_ACCESS_KEY "partner of AWS_ACCESS_KEY_ID"
require_nonplaceholder REDIS_AUTH_TOKEN "run 'openssl rand -hex 24' to generate — bundled valkey runs with --requirepass and refuses unauthenticated connections" "changeme|^$"

# Cross-check: DATABASE_URL must embed POSTGRES_PASSWORD — this catches
# the "set the password in one place, forgot the other" class of bug.
if [[ -n "${DATABASE_URL:-}" && -n "${POSTGRES_PASSWORD:-}" ]]; then
  if ! [[ "$DATABASE_URL" == *"$POSTGRES_PASSWORD"* ]]; then
    ERRORS+=("DATABASE_URL does not contain POSTGRES_PASSWORD — one of them is out of date")
  fi
fi

# License key shape sanity: mcph_sh_ followed by hex. Doesn't validate
# against the server — that happens at boot — but catches "I pasted
# the GHCR pull token into MCP_HOSTING_LICENSE_KEY".
if [[ -n "${MCP_HOSTING_LICENSE_KEY:-}" ]]; then
  if ! [[ "$MCP_HOSTING_LICENSE_KEY" =~ ^mcph_sh_[0-9a-f]+$ ]]; then
    ERRORS+=("MCP_HOSTING_LICENSE_KEY doesn't match mcph_sh_<hex> — check you pasted the license key, not the GHCR pull token")
  fi
fi

if (( ${#ERRORS[@]} > 0 )); then
  echo "Environment validation failed:" >&2
  for err in "${ERRORS[@]}"; do
    echo "  - $err" >&2
  done
  echo "" >&2
  echo "Fix these in $ENV_FILE and re-run. See docs/getting-started.md step 4." >&2
  exit 1
fi

echo "ok — all required env vars look reasonable. Safe to \`docker compose up -d\`."
exit 0
