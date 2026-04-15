# mcp-hosting-deploy redesign plan — consumer pivot

Written 2026-04-14 alongside the consumer-pivot work on the main repo. This
document is the source of truth for how the self-host distribution is being
reshaped after the 2026-04-12 pivot away from the Business-tier
(Test/Proxy/Hosting) product.

## 2026-04-14 late-evening update — revised decisions

The original plan below assumed self-host would keep a free tier and
ship across six deploy paths. Several product + security decisions
superseded parts of the plan the same day:

- **Self-host is paid-only.** Free tier is hosted-only at mcp.hosting;
  self-host requires an active Team subscription. App refuses to boot
  without a valid `MCP_HOSTING_LICENSE_KEY`. (See section "Getting-started
  guide" — the free-tier fallback bullet is obsolete.)
- **Grace period: 24 hours, not 7 days.** Short enough to surface
  genuine network-policy issues fast; long enough to tolerate a brief
  egress outage. (See "Operator runbooks → docs/license.md".)
- **Relicense MIT → Elastic License 2.0.** The old LICENSE/README
  mismatch had no legal force; ELv2 permits redistribution + self-host
  but prohibits hosted-service resale and license-key circumvention.
- **GHCR image flipped private** (2026-04-14 ~18:15 PT). Pull requires
  a `self-host` token minted alongside the license key on Team
  subscription creation. Every deploy path's README now documents the
  `docker login` / `imagePullSecret` / registry-mirror step.
- **Deploy paths trimmed to four: Compose, Helm, Fly, Cloud Run.**
  Render removed (no bundled Redis, weaker private-image UX than the
  others). CloudFormation + Terraform paths described in the original
  plan were never shipped; no longer on the near-term roadmap.
- **Repo currently private.** The `git clone` + Fly.io-launch-button
  UX in the README assumes a public-flip or tarball-distribution path
  at launch; neither is wired up yet. README now carries a banner
  flagging the TBD.

Inline sections below that conflict with the above have been marked
`[obsolete: see 2026-04-14 update]` rather than rewritten, to preserve
the design trajectory.

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
mcph orchestrator. Self-host is bundled with every Team subscription
($15/seat/mo). [obsolete: see 2026-04-14 update — "no key = free-tier
features" is no longer true; self-host is paid-only.]

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

## Deployment paths we ship [obsolete: see 2026-04-14 update]

The shipping matrix is now: **Docker Compose, Helm, Fly.io, Cloud Run.**
Render was added then removed; CloudFormation and Terraform were
planned here but never shipped. The four-path list below is
paraphrased to match reality; original ranking (six paths) archived
below it.

**Shipping (2026-04-14 evening):**

1. **Docker Compose (single-host).** `docker compose up` on a VM.
   Bundles Caddy + Postgres 18 + Valkey 8 + app. HTTP challenge via
   Caddy. Fully zero-external-services.
2. **Helm chart (Kubernetes).** External managed Postgres required
   (RDS / Cloud SQL / AlloyDB); in-cluster Valkey bundled; Caddy for
   TLS or BYO ingress. `imagePullSecrets` wired to a
   `ghcr-mcp-hosting` secret.
3. **Fly.io.** Operator runs `fly postgres create` + `fly redis create`
   during setup; image is mirrored from GHCR into `registry.fly.io`
   (Fly can't pull from private third-party registries).
4. **Cloud Run.** Operator provisions Cloud SQL + Memorystore; image
   is mirrored from GHCR into Artifact Registry.

**Original six-path plan (archived):**

1. Docker Compose — shipped.
2. Helm chart — shipped.
3. CloudFormation (AWS ECS Fargate or EC2) — not shipped, dropped.
4. Terraform (AWS / GCP / Azure) — not shipped, dropped.
5. Cloud Run — shipped.
6. Render / Railway — Render shipped 2026-04-14 morning, removed
   2026-04-14 evening (no bundled Redis, private-image UX gap); Railway
   never shipped.
7. ~~Fly.io~~ — the original plan removed Fly; the late-evening
   revision added it back (in place of Render).

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
- License key section: explain that the key is required on first boot
  and the app refuses to serve requests without a valid one; 24-hour
  offline grace period. [obsolete: see 2026-04-14 update — the
  original "without a key, free-tier" bullet is superseded.]
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
