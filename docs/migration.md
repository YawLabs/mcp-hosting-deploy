# Migrating from hosted mcp.hosting to self-host

Moving an existing hosted account onto your own self-host instance in
five steps. Expect the whole thing to take about 30 minutes including
DNS propagation.

## 1. Stand up the destination instance

Follow [getting-started.md](./getting-started.md) and confirm
`https://<your-domain>/health` returns 200. Don't point any MCP clients
at it yet — you need to load the servers first.

The destination runs on a **Team license key**, so have that ready
from your hosted dashboard's **Settings → Self-host** card.

## 2. Export from the source

On your hosted mcp.hosting dashboard: **Settings → Export your data**
→ click **Download migration bundle**.

You get a JSON file shaped like:

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-04-15T12:00:00Z",
  "sourceInstance": "hosted",
  "sourceVersion": "0.9.2",
  "account": { "email": "you@example.com", "name": "You" },
  "servers": [
    { "subdomain": "acme-jira", "name": "Acme Jira", ... },
    ...
  ],
  "notes": [...]
}
```

Inspect it before uploading. The bundle includes subdomains, backend
URLs, and per-server settings (caching, auth, IP allowlists, session
proxy config). It **does not** include:

- **API keys** — hashed in the DB, plaintext unrecoverable. Re-issue
  them on the new instance after migration.
- **Hosted server secrets** (env vars). Encrypted at rest with
  instance-specific keys; copy them across by hand via
  **dashboard → Server → Secrets**.
- **Team membership rosters**. Re-add team members via
  **dashboard → Teams** on the destination.
- **GitHub App installations**. Install the app on the destination
  org/user after you've migrated.
- **Custom domains**. Re-add them on the destination and update your
  DNS before cutting over.

## 3. Create an account on the destination

Sign in at `https://<your-domain>` via GitHub or email magic-link.
The destination will create an account for you with the same email
you used on the source — matching on email is what makes the import
target the right account.

## 4. Import the bundle

On the destination: **/dashboard/admin** (the Admin page) → scroll to
**Migrate in from hosted** → **Upload migration bundle** → pick the
JSON from step 2.

You'll see a toast like `Imported 7 server(s) — 1 skipped`. Skipped
subdomains are either already present on the destination or malformed
in the bundle; the import log prints them to the browser console.

## 5. Cut over clients

For each team member:

1. Replace their `MCPH_URL=https://mcp.hosting` with
   `MCPH_URL=https://<your-domain>` in their mcph config.
2. Re-issue any MCP API keys they were using (hosted dashboard's
   **Settings → API keys → Revoke**; destination dashboard's
   **Settings → API keys → Create**).
3. Reinstall the GitHub App if they used it.
4. Re-add custom domains and update DNS.

Once everyone's moved, cancel the hosted subscription at
**mcp.hosting/dashboard/upgrade → Manage billing** to stop the recurring
charge. The hosted account stays accessible in read-only mode for 30
days in case you need to pull anything else from it.

## Operator notes

- The migration export is **rate-limited to 5 per hour per account**;
  the import is **3 per hour**. Both events are written to the
  `audit_events` table.
- **No transactions across steps**. If a partial upload fails halfway
  through (network blip, etc.) the already-imported servers stay.
  Re-uploading is safe — existing subdomains skip instead of
  overwrite, so running the import twice doesn't clobber anything.
- **Moving back to hosted** isn't supported from the UI today —
  self-host → hosted requires manual recreation. Open an issue or
  email support if you need this.
- The destination's license slot binds on first boot per
  [license.md](./license.md). If you're also standing up a staging
  instance, set `MCP_HOSTING_STAGING=true` on the staging pod so it
  uses the staging slot instead of the prod slot.
