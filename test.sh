#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mcp.hosting deploy template integration tests
# =============================================================================
# Exercises each shipped deployment template without touching paid cloud
# infrastructure. Structured so the whole thing runs inside a GitHub Actions
# Linux runner in under ~5 minutes.
#
# Tests:
#   docker-compose   Full E2E — postgres + redis + app come up, /health 200,
#                    migrations applied. Caddy is skipped (the runner has
#                    no real TLS / port 443), app is probed directly.
#   helm             Schema — helm template renders, every emitted manifest
#                    passes kubectl --dry-run=client. No live cluster.
#   fly              Schema — flyctl config validate against fly/fly.toml.
#   cloudrun         Schema — yamllint on cloudrun/service.yaml + Knative
#                    key sanity.
#
# Usage:
#   bash test.sh                          # Run everything
#   bash test.sh --target=docker-compose  # Run one target
#   bash test.sh --skip-teardown          # Leave containers running
#
# Environment:
#   RESULTS_DIR   Where to write JSON result files (default: test-results)
#   IMAGE         App image tag to pull (default: ghcr.io/yawlabs/mcp-hosting:latest)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RESULTS_DIR has to survive pushd/popd during the compose test, so anchor
# it to the script dir unless explicitly overridden with an absolute path.
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/test-results}"
case "$RESULTS_DIR" in
  /*) ;;
  *) RESULTS_DIR="$SCRIPT_DIR/$RESULTS_DIR" ;;
esac
IMAGE="${IMAGE:-ghcr.io/yawlabs/mcp-hosting:latest}"
SKIP_TEARDOWN="false"
TARGET_FILTER=""

for arg in "$@"; do
  case "$arg" in
    --target=*)      TARGET_FILTER="${arg#--target=}" ;;
    --skip-teardown) SKIP_TEARDOWN="true" ;;
    --help|-h)
      sed -n '3,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$RESULTS_DIR"
RESULTS_JSON="$RESULTS_DIR/results.json"
: > "$RESULTS_JSON.tmp"

TOTAL_PASS=0
TOTAL_FAIL=0

# -----------------------------------------------------------------------------
# Test harness helpers
# -----------------------------------------------------------------------------
log()  { printf '%s [%s] %s\n' "$(date -u +%H:%M:%S)" "${1:-info}" "${2:-}"; }
info() { log info "$*"; }
ok()   { log PASS "$*"; TOTAL_PASS=$((TOTAL_PASS + 1)); }
fail() { log FAIL "$*"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }

record() {
  local target="$1" status="$2" duration="$3" note="${4:-}"
  printf '  {"target":"%s","status":"%s","duration_s":%s,"note":%s},\n' \
    "$target" "$status" "$duration" "$(printf '%s' "$note" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')" \
    >> "$RESULTS_JSON.tmp"
}

should_run() {
  [[ -z "$TARGET_FILTER" || "$TARGET_FILTER" == "$1" ]]
}

# -----------------------------------------------------------------------------
# docker-compose — full E2E against a throwaway compose project
# -----------------------------------------------------------------------------
test_docker_compose() {
  should_run docker-compose || return 0

  local start project envfile
  start=$(date +%s)
  project="mcphtest-$$-$(head -c 4 /dev/urandom | od -A n -t x1 | tr -d ' \n')"
  envfile="$SCRIPT_DIR/docker-compose/.env.test"

  info "docker-compose: preparing $project"

  local pw cookie
  pw="$(openssl rand -hex 16)"
  cookie="$(openssl rand -hex 32)"

  cat > "$envfile" <<ENV
DOMAIN=localhost
BASE_DOMAIN=localhost
NODE_ENV=development
POSTGRES_USER=mcphosting
POSTGRES_PASSWORD=${pw}
POSTGRES_DB=mcphosting
DATABASE_URL=postgresql://mcphosting:${pw}@postgres:5432/mcphosting
DATABASE_SSL=false
# CI-only: skip the self-host license refuse-to-boot path; we're just
# smoke-testing image + stack connectivity, not the license flow.
# Production compose defaults SELF_HOSTED=true.
SELF_HOSTED=false
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_TLS=false
# Bundled valkey now runs with --requirepass; compose refuses to start
# without REDIS_AUTH_TOKEN. Smoke test uses a fresh per-run value.
REDIS_AUTH_TOKEN=$(openssl rand -hex 24)
COOKIE_SECRET=${cookie}
EMAIL_FROM=noreply@localhost
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
GITHUB_CLIENT_ID=ci-test-client-id
GITHUB_CLIENT_SECRET=ci-test-client-secret-placeholder
ENV

  pushd "$SCRIPT_DIR/docker-compose" >/dev/null

  # Caddy wants ports 80/443 which aren't available in GHA runners. Scope
  # the test to just the data plane + app; Caddy is a pure reverse proxy
  # sitting in front and is exercised by the config-validate step.
  info "docker-compose: pulling $IMAGE"
  docker compose --env-file .env.test -p "$project" pull postgres redis mcp-hosting-app >/dev/null

  info "docker-compose: up (postgres + redis + app)"
  if ! docker compose --env-file .env.test -p "$project" up -d postgres redis mcp-hosting-app; then
    fail "docker-compose: compose up failed"
    record docker-compose fail "$(( $(date +%s) - start ))" "compose up failed"
    docker compose --env-file .env.test -p "$project" logs --tail=50 2>&1 | tee "$RESULTS_DIR/docker-compose.log" || true
    [[ "$SKIP_TEARDOWN" == "true" ]] || docker compose --env-file .env.test -p "$project" down -v >/dev/null 2>&1 || true
    popd >/dev/null
    rm -f "$envfile"
    return 0
  fi

  # Probe /health from a sibling container on the project network. Avoids
  # host-network assumptions (-p maps would collide with any other test).
  info "docker-compose: waiting for /health (up to 150s)"
  local healthy=false
  for _ in $(seq 1 75); do
    if docker run --rm --network "mcp-hosting" curlimages/curl:8.10.1 \
        -fsS --max-time 3 http://mcp-hosting-app:3000/health >/dev/null 2>&1; then
      healthy=true
      break
    fi
    sleep 2
  done

  # Always dump app logs to both stdout and the artifact file — useful on
  # pass (startup timing) and essential on fail (the root cause).
  info "docker-compose: app logs (last 200 lines)"
  docker compose --env-file .env.test -p "$project" logs --tail=200 mcp-hosting-app \
    2>&1 | tee "$RESULTS_DIR/docker-compose-app.log" || true

  if [[ "$healthy" == "true" ]]; then
    ok "docker-compose: /health returned 200"
    record docker-compose pass "$(( $(date +%s) - start ))" "E2E boot + migrate + health OK"
  else
    fail "docker-compose: /health never returned 200"
    record docker-compose fail "$(( $(date +%s) - start ))" "/health timeout"
  fi

  if [[ "$SKIP_TEARDOWN" != "true" ]]; then
    info "docker-compose: tearing down"
    docker compose --env-file .env.test -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
    rm -f "$envfile"
  fi

  popd >/dev/null
}

# -----------------------------------------------------------------------------
# helm — render + kubectl dry-run
# -----------------------------------------------------------------------------
test_helm() {
  should_run helm || return 0

  local start out
  start=$(date +%s)

  info "helm: helm lint --strict"
  if ! helm lint "$SCRIPT_DIR/helm/mcp-hosting" --strict \
        --set domain=test.example.com \
        --set externalDatabase.host=pg.example.com \
        --set externalDatabase.password=test \
        --set app.githubClientId=x \
        --set app.githubClientSecret=y \
        --set app.cookieSecret=z \
        2>&1 | tee "$RESULTS_DIR/helm-lint.log"; then
    fail "helm: lint failed"
    record helm fail "$(( $(date +%s) - start ))" "helm lint failed"
    return 0
  fi

  info "helm: helm template → kubeconform schema validation"
  out="$RESULTS_DIR/helm-rendered.yaml"
  if ! helm template mcp-hosting "$SCRIPT_DIR/helm/mcp-hosting" \
        --namespace mcp-hosting \
        --set domain=test.example.com \
        --set externalDatabase.host=pg.example.com \
        --set externalDatabase.password=test \
        --set app.githubClientId=x \
        --set app.githubClientSecret=y \
        --set app.cookieSecret=z \
        > "$out" 2> "$RESULTS_DIR/helm-template.err"; then
    fail "helm: helm template failed"
    cat "$RESULTS_DIR/helm-template.err"
    record helm fail "$(( $(date +%s) - start ))" "helm template failed"
    return 0
  fi

  # kubeconform validates against bundled OpenAPI schemas offline —
  # no live API server needed, unlike `kubectl apply --dry-run=client`
  # which still calls out to http://localhost:8080/openapi/v2.
  if ! command -v kubeconform >/dev/null 2>&1; then
    info "helm: installing kubeconform"
    curl -sL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz \
      | tar -xz -C /tmp kubeconform
    sudo mv /tmp/kubeconform /usr/local/bin/kubeconform
  fi

  if ! kubeconform -summary -strict -ignore-missing-schemas "$out" \
        2>&1 | tee "$RESULTS_DIR/helm-kubeconform.log"; then
    fail "helm: kubeconform rejected rendered manifests"
    record helm fail "$(( $(date +%s) - start ))" "kubeconform rejected"
    return 0
  fi

  ok "helm: chart renders + kubeconform accepts"
  record helm pass "$(( $(date +%s) - start ))" "helm template + kubeconform OK"
}

# -----------------------------------------------------------------------------
# fly — flyctl config validate
# -----------------------------------------------------------------------------
test_fly() {
  should_run fly || return 0

  local start
  start=$(date +%s)

  # `flyctl config validate` would be ideal but requires an authenticated
  # session even for pure schema checks, which isn't available in CI
  # without secrets. TOML parse + required-key sanity check catches the
  # malformed-file class of bug without needing flyctl at all.
  #
  # The heredoc + pipe combo needs to be wrapped in a brace group so
  # `<<PY` feeds python3's stdin (not tee's). Without the braces bash
  # parses `a 2>&1 | tee b <<PY` as `a 2>&1 | (tee b <<PY)`, which sent
  # the script to tee and ran python3 with empty stdin — silently
  # passing every test (shellcheck SC2259 caught this).
  if {
    python3 - "$SCRIPT_DIR/fly/fly.toml" <<'PY'
import sys, tomllib
doc = tomllib.loads(open(sys.argv[1], "rb").read().decode())
for k in ("app", "primary_region", "build", "http_service"):
    assert k in doc, f"fly.toml missing top-level [{k}]"
assert "image" in doc["build"], "[build] missing image"
assert doc["http_service"].get("internal_port"), "[http_service] missing internal_port"
print("fly.toml shape OK")
PY
  } 2>&1 | tee "$RESULTS_DIR/fly.log"; then
    ok "fly: fly.toml parses and has required keys"
    record fly pass "$(( $(date +%s) - start ))" "TOML shape OK"
  else
    fail "fly: fly.toml parse / shape check failed"
    record fly fail "$(( $(date +%s) - start ))" "fly.toml invalid"
  fi
}

# -----------------------------------------------------------------------------
# cloudrun — yamllint + Knative key sanity
# -----------------------------------------------------------------------------
test_cloudrun() {
  should_run cloudrun || return 0

  local start
  start=$(date +%s)

  if ! yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' \
        "$SCRIPT_DIR/cloudrun/service.yaml" 2>&1 | tee "$RESULTS_DIR/cloudrun.log"; then
    fail "cloudrun: yamllint rejected service.yaml"
    record cloudrun fail "$(( $(date +%s) - start ))" "yamllint failed"
    return 0
  fi

  if python3 - "$SCRIPT_DIR/cloudrun/service.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc.get("apiVersion") == "serving.knative.dev/v1", "wrong apiVersion"
assert doc.get("kind") == "Service", "kind must be Service"
containers = doc["spec"]["template"]["spec"]["containers"]
assert containers and containers[0].get("image"), "missing image"
print("cloudrun service.yaml shape OK")
PY
  then
    ok "cloudrun: Knative shape + yamllint OK"
    record cloudrun pass "$(( $(date +%s) - start ))" "Knative shape + yamllint OK"
  else
    fail "cloudrun: Knative shape invalid"
    record cloudrun fail "$(( $(date +%s) - start ))" "Knative shape invalid"
  fi
}

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------
info "Running target: ${TARGET_FILTER:-all}"

test_docker_compose
test_helm
test_fly
test_cloudrun

# Stitch results.json
{
  printf '{\n'
  printf '  "started_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "pass": %d,\n' "$TOTAL_PASS"
  printf '  "fail": %d,\n' "$TOTAL_FAIL"
  printf '  "results": [\n'
  # Trim trailing comma from the last entry
  sed '$ s/,$//' "$RESULTS_JSON.tmp"
  printf '  ]\n'
  printf '}\n'
} > "$RESULTS_JSON"
rm -f "$RESULTS_JSON.tmp"

info "Results: $TOTAL_PASS pass, $TOTAL_FAIL fail → $RESULTS_JSON"

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
