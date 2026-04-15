# Troubleshooting

Common operator-facing issues and the fixes, in rough order of how often they come up.

## Caddy can't get a TLS certificate

Symptom: `https://your-domain.example` either never responds or returns a Caddy self-signed cert warning. Caddy logs show an ACME challenge error.

Causes + fixes:

| Cause | Fix |
|---|---|
| DNS A record doesn't point at this server | `dig your-domain.example +short` — should return your server's public IP |
| DNS record exists but hasn't propagated yet | Wait 5–30 minutes, check again |
| Port 80 isn't open to the internet | Let's Encrypt's HTTP challenge requires inbound 80; check the host firewall + any upstream LB/NAT |
| Cloud provider security group blocks 80/443 | Open both in the instance's SG/firewall |
| You're behind a CGNAT / no public IP | Use a cloud VM with a static IPv4, or use Cloudflare Tunnel in front |

Look at `docker compose logs caddy` — Caddy is explicit about what it tried and why it failed.

## Login emails aren't arriving

Magic-link login is the only login path. If emails don't send, nobody can get in.

Check the app logs for SES errors:

```bash
docker compose logs mcp-hosting-app | grep -i "ses\|email"
```

Common failures:

| Log line | Fix |
|---|---|
| `AWS credentials not provided` | Set `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` in `.env`, restart the app |
| `Email address is not verified` | SES account is in sandbox; verify the recipient in AWS SES, OR request production access |
| `MessageRejected: Email address is not verified` for `EMAIL_FROM` | Verify the sending domain/address in SES |
| `Access Denied ses:SendEmail` | The IAM user needs `ses:SendEmail` + `ses:SendRawEmail` permissions |

You can manually test SES from inside the app container:

```bash
docker compose exec mcp-hosting-app node -e "
  const { sendLoginCode } = require('./dist/lib/email.js');
  sendLoginCode('you@your-domain.example', '123456').then(() => console.log('sent')).catch(e => console.error(e));
"
```

## App container keeps restarting

Check the last ~100 lines of logs:

```bash
docker compose logs --tail=100 mcp-hosting-app
```

Top reasons:

| Symptom | Cause | Fix |
|---|---|---|
| `DATABASE_URL: missing required env var` | `.env` not loaded / missing var | Verify `docker compose config` shows the env var |
| `getaddrinfo EAI_AGAIN postgres` | Postgres container isn't up yet | Wait 30s; if persistent, check `docker compose ps postgres` |
| `Client network socket disconnected before secure TLS` / `FATAL: Database migration failed` | App defaulted `DATABASE_SSL=require` but bundled `postgres:18` has no TLS | Already hard-coded to `DATABASE_SSL=false` in `docker-compose.yml`. If you swap to external managed Postgres, drop the override. |
| `ECONNREFUSED 127.0.0.1:6379` | `REDIS_HOST` resolved to localhost inside the container | Set `REDIS_HOST=redis` (the Docker Compose service name, not localhost) |
| `Missing required env var: REDIS_HOST` | You set `REDIS_URL` instead | The app reads `REDIS_HOST` + `REDIS_PORT` + optional `REDIS_AUTH_TOKEN` separately. Split the URL or set the three pieces directly. |
| `Missing required env var: GITHUB_CLIENT_ID` | GitHub OAuth not configured | Register an OAuth app at github.com/settings/developers, set `GITHUB_CLIENT_ID` + `GITHUB_CLIENT_SECRET` in `.env`. |
| `Database migration failed` | Schema state mismatch | See [docs/upgrade.md](./upgrade.md) — restore the pre-migration snapshot if needed |
| License revalidation exit | Not possible — license failures fall back to free-tier, they don't crash | If you're seeing this, file a bug |

## Dashboard loads but I can't sign in

1. Confirm SES is working (see above).
2. Check your browser dev tools — is the network request to `/auth/email/send-code` returning 200?
3. Rate limit: 5 send-code requests per IP per 15 minutes. If you've been testing, wait out the window.
4. Cookie issues: try in a clean browser profile. `COOKIE_SECRET` changes log everyone out.

## mcph on my client can't connect

Make sure the client config has:

```json
"env": {
  "MCPH_TOKEN": "mcp_pat_...",
  "MCPH_URL": "https://your-domain.example"
}
```

Common mistakes:

| Symptom | Cause |
|---|---|
| `ENOENT: spawn npx` on Windows | Needs `cmd /c` wrapper — see [main docs](https://mcp.hosting/docs) |
| `401 Unauthorized` | Token doesn't belong to the same instance, or was revoked |
| `ECONNREFUSED` / `getaddrinfo ENOTFOUND` | `MCPH_URL` wrong or unreachable from the client machine |
| Works locally but not from a teammate's machine | Their network blocks outbound HTTPS to your instance |

## Database is slow

Check connection pool saturation:

```bash
docker compose exec postgres psql -U mcphosting -c "SELECT count(*) FROM pg_stat_activity;"
```

If that's near `max_connections`, the app is either leaking or genuinely saturated. With the default pool of 10/pod and a small RDS `max_connections=100`, you've got room for 8–10 pods before tuning.

Slow queries:

```bash
docker compose exec postgres psql -U mcphosting -c \
  "SELECT query, total_exec_time, calls FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;"
```

`pg_stat_statements` has to be enabled in `postgresql.conf`. Default is off on the bundled container; enable if debugging.

## How do I reset an account's password / session?

There's no password (magic-link only). To force a fresh login on an account:

```bash
# Invalidate all sessions for one account
docker compose exec mcp-hosting-app node -e "
  require('./dist/auth/session.js').destroyAccountSessions('<account-uuid>').then(n => console.log('revoked', n));
"
```

## How do I delete a test account?

```bash
docker compose exec mcp-hosting-app tsx scripts/delete-account.ts <account-uuid> --dry-run
docker compose exec mcp-hosting-app tsx scripts/delete-account.ts <account-uuid>
```

## How do I see active accounts / usage?

```sql
-- Active accounts
SELECT COUNT(*) FROM accounts WHERE suspended_at IS NULL;

-- Tool calls in the last 7 days (only populated for accounts with logging on)
SELECT COUNT(*) FROM connect_analytics WHERE timestamp > now() - interval '7 days';

-- MCP servers configured
SELECT plan, COUNT(*)
  FROM connect_servers cs
  JOIN accounts a ON a.id = cs.account_id
  GROUP BY plan;
```

## When do I reach out to support?

- License key won't validate despite outbound HTTPS working → [support@mcp.hosting](mailto:support@mcp.hosting).
- Bug in the app that survives an upgrade → GitHub issue on the main repo.
- Security issue → email with `[security]` prefix; 48-hour response target.
