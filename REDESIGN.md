# mcp-hosting-deploy redesign plan — consumer pivot

Written 2026-04-14 alongside the consumer-pivot work on the main repo. This
document is the source of truth for how the self-host distribution is being
reshaped after the 2026-04-12 pivot away from the Business-tier
(Test/Proxy/Hosting) product.

## Why this repo is being re-shaped

The repo was built for the previous business: self-host the
Test/Proxy/Hosting stack, monetise via a $19/mo "licensed proxy" tier, and
require wildcard DNS so customers could host their own MCP servers behind
subdomains. The consumer launch changed the product shape entirely:

- The primary product is now the **mcph orchestrator** — a single CLI
  (`@yawlabs/mcph`) users install in their MCP client that pulls config
  from a cloud dashboard.
- Pricing is Free / Pro ($9/mo) / Team ($15/seat/mo). The $19 "licensed
  proxy" tier is archived.
- No wildcard DNS is required for the consumer product — users interact
  with a single dashboard domain. Wildcard subdomains only matter if you
  operate the Business-tier proxy (and Business is flag-gated off in
  hosted mcp.hosting today).

Self-host still matters, but for a different audience: enterprises /
regulated teams that need their own private instance of the dashboard +
mcph orchestrator. License key enables the paid tiers (Pro / Team
features) on their self-hosted instance; no key = free-tier features.

## Target audience

1. **Teams that want their own private mcp.hosting** — mcph orchestrator,
   dashboard, compliance runner — inside their own VPC. Typical reasons:
   data sovereignty, contract requirements, or "we just want this to be
   on-prem."
2. **Enterprises evaluating consumer mcp.hosting** before committing to
   the hosted service. Self-host lets them poke at the full product
   without trusting our cloud.

Explicitly **not** the target:
- Solo developers — the hosted mcp.hosting at $9/mo dominates on TCO.
- Customers who want to resell MCP hosting — that was the Business-tier
  use case and isn't the current product.

## Deployment paths we ship

Ranked by how many users we expect per path. Each path is "production
ready" meaning: reproducible from this repo, HTTPS out of the box, a
documented upgrade procedure, and a backup/restore story.

1. **Docker Compose (single-host).** The "one VM, `docker compose up`"
   story. Default path for teams without a k8s cluster. Bundles Caddy +
   Postgres 18 + Valkey 8 + app. Caddy uses HTTP challenge by default so
   no DNS provider credentials are needed.
2. **Helm chart (Kubernetes).** For teams that already run k8s. Defaults
   to external managed Postgres (RDS / Cloud SQL / AlloyDB); in-cluster
   Valkey is fine for production. Caddy handles TLS or you bring your own
   ingress.
3. **CloudFormation (AWS ECS Fargate or EC2).** The AWS-native option for
   teams that want IaC and don't have k8s. Both sub-templates exist and
   are CI-tested.
4. **Terraform (AWS / GCP / Azure).** Same concept as CloudFormation but
   multi-cloud. AWS module is production-tested; GCP + Azure are in
   progress and clearly marked.
5. **Cloud Run (GCP serverless).** Single-container path for small teams
   that don't want to run a VM.
6. **Render / Railway (PaaS).** One-click "Deploy" buttons for the
   smallest installs.
7. ~~**Fly.io**~~ — removed in this pass. Lower priority and duplicate
   capability with Render / Railway.

## What changes in the redesign

### README
- Feature table switches from "$19/mo Licensed Proxy" to the current
  Free / Pro / Team tiers.
- Remove "MCP proxy (auth, rate limiting, routing)" as the headline
  feature — that was the Business tier. Replace with mcph orchestrator
  + dashboard + compliance runner.
- Drop the wildcard DNS requirement from the quick-start. Mention it
  only as an "advanced — only needed if you're running the Business
  proxy".

### Caddyfile
- Single-domain only (HTTP challenge via Let's Encrypt). No DNS provider
  plugin. Works out of the box on any VPS with port 80 open.
- Wildcard / DNS-challenge support is removed entirely — the old
  Business-tier use case isn't part of the consumer product.
- Drop the `CF_API_TOKEN` requirement from `.env.example`.

### Getting-started guide
- Remove the wildcard DNS step from the default path.
- Reframe "what you get": "this is your team's private instance of the
  mcp.hosting dashboard; members install `@yawlabs/mcph` pointing at
  `MCPH_URL=https://your-domain.example`."
- License key section: explain that without a key the instance runs as
  free-tier (3 servers per account, 7-day log retention). With a key,
  the plan on the key determines enabled features.
- Drop the "MCP gateway" framing.

### Helm values
- `wildcardDomain` demoted to advanced / optional.
- `licenseKey` stays at top level.
- Add `mcphClientGuidance` NOTES.txt pointer so operators know to tell
  their team to set `MCPH_URL` to the new instance.

### Operator runbooks (new / tightened)
- `docs/upgrade.md` — pull image, migrations auto-apply, rollback tips.
- `docs/backup-restore.md` — scripts/backup.sh usage + restore flow +
  RPO guidance.
- `docs/license.md` — how the license key flows from LemonSqueezy →
  `MCP_HOSTING_LICENSE_KEY` → the /api/license/validate handshake, and
  how to recover if the license API is unreachable (7-day grace).
- `docs/troubleshooting.md` — the 5–10 most common operator-facing
  issues (email not sending, Caddy certs stuck, DB auth, etc.).
- `docs/mcph-client.md` — how team members point their mcph CLI at
  the self-hosted instance instead of mcp.hosting.

### Root-repo alignment
- Main repo `dashboard/src/pages/SelfHost.tsx` gets rewritten to
  describe this distribution accurately: buy license → clone deploy →
  pick compose/helm → boot. Replace the "early access via email"
  copy.

## Not in scope for this pass

- A `docs/architecture.md` with full system diagrams. The existing
  one-paragraph description is enough for operators; a diagram doc
  belongs in a marketing or sales context.
- Translated docs.
- A `docs/migration-from-hosted.md` guide. We'll write it when the
  first customer actually migrates.
- Auth integrations beyond email magic-link + GitHub OAuth. The hosted
  product supports both; self-host inherits them without extra work.
- SSO (SAML, OIDC) — this is a reasonable Enterprise-tier follow-up
  but not urgent at launch.

## Checklist for "production-ready"

Every shipped deployment path must pass:

- [ ] Reproducible from a fresh clone with only documented prerequisites.
- [ ] HTTPS working by default (HTTP challenge at minimum, DNS challenge
      if wildcard is needed).
- [ ] Health check endpoint reachable at the chosen domain.
- [ ] Dashboard loads at `/dashboard`, login works, first server can be
      added.
- [ ] `MCPH_URL` configurable on the mcph CLI — a teammate on another
      machine can point their CLI at the instance and see the org's
      servers.
- [ ] Upgrade path documented and tested: pull image → migrations run →
      no data loss.
- [ ] Backup script runs, produces a file, file restores cleanly on a
      fresh instance.
- [ ] `MCP_HOSTING_LICENSE_KEY` validated against the license API; paid
      features gate correctly when the key is missing / expired.
- [ ] Secrets (license key, cookie secret, DB password) never appear in
      repo, logs, or example config.
