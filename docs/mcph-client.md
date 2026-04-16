# Pointing mcph at your self-host

Each team member who wants to use the orchestrator runs [`@yawlabs/mcph`](https://www.npmjs.com/package/@yawlabs/mcph) in their MCP client and points it at your self-host. The rest of the flow is identical to the hosted product.

## 1. Create a token

- Sign in to `https://your-domain.example`.
- **Settings → API Tokens → Create token.**
- Copy the `mcp_pat_...` value — it's shown once.

## 2. Run the install command (recommended)

mcph v0.11.0+ ships an `install` subcommand that edits the right MCP client config file for the user — no JSON pasting, no per-OS file-path archaeology, no Windows `cmd /c` wrapper to remember:

```bash
# Pick one: claude-code | claude-desktop | cursor | vscode
npx -y @yawlabs/mcph install claude-code --token mcp_pat_...
```

Two files are touched per run:

1. **The client's config file** (e.g. `~/.claude/settings.json`) — the `mcp.hosting` launch entry is merged in, preserving any other servers you already had.
2. **`~/.mcph.json`** (user-global) — created if missing, the token is written here so the launch entry stays env-free and the next `install` invocation on a different client doesn't re-prompt.

Then add the self-host URL to `~/.mcph.json` so mcph talks to your instance instead of the hosted one:

```jsonc
{
  "version": 1,
  "token": "mcp_pat_...",
  // Self-host operators: point mcph at your instance.
  "apiBase": "https://your-domain.example"
}
```

`apiBase` in `~/.mcph.json` is read by every mcph invocation on the machine, so you only set it once per user — `install` on additional clients (Cursor, VS Code, etc.) inherits it for free.

Verify the wiring with `npx -y @yawlabs/mcph doctor` — it prints the resolved token + apiBase + their sources, then probes `/api/connect/discover` against your instance.

Restart the client after `install` so it re-reads the config.

## 3. Or hand-edit the client config

Per-client file paths and JSON shapes follow. The `env` block is the same everywhere; the difference is which config file your client reads.

### Claude Code

`~/.claude/settings.json` (User scope) or `<project>/.claude/settings.local.json` (project scope):

```json
{
  "mcpServers": {
    "mcp.hosting": {
      "command": "npx",
      "args": ["-y", "@yawlabs/mcph"],
      "env": {
        "MCPH_TOKEN": "mcp_pat_...",
        "MCPH_URL": "https://your-domain.example"
      }
    }
  }
}
```

### Claude Desktop

macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
Windows: `%APPDATA%\Claude\claude_desktop_config.json`
Linux: `~/.config/Claude/claude_desktop_config.json`

Same JSON shape as above. Restart the app after editing.

### Cursor

`~/.cursor/mcp.json` (global) or `.cursor/mcp.json` (project). Same JSON shape.

### VS Code

`.vscode/mcp.json` — **different top-level shape, no `mcpServers` wrapper**:

```json
{
  "mcp.hosting": {
    "command": "npx",
    "args": ["-y", "@yawlabs/mcph"],
    "env": {
      "MCPH_TOKEN": "mcp_pat_...",
      "MCPH_URL": "https://your-domain.example"
    }
  }
}
```

### Windows note

`npx` on native Windows is a `.cmd` shim and MCP clients can't spawn it directly (you'll see `ENOENT`). Swap the two lines:

```json
"command": "cmd",
"args": ["/c", "npx", "-y", "@yawlabs/mcph"]
```

`cmd /c` is required on Command Prompt, PowerShell, and Git Bash. Not needed in WSL — use the Linux config there. **`mcph install` writes this wrapper for you** when it detects native Windows; only relevant if you're hand-editing.

## 4. Optional tuning

mcph reads two kinds of config: env vars in the launch entry, and `~/.mcph.json` (or a per-project `.mcph.local.json`). Precedence is `env > .mcph.local.json (cwd) > ~/.mcph.json > defaults`. Both files are JSONC — comments are allowed.

| Env var | `.mcph.json` key | Default | Notes |
|---|---|---|---|
| `MCPH_TOKEN` | `token` | — | **Required.** Personal access token from Settings. |
| `MCPH_URL` | `apiBase` | `https://mcp.hosting` | Your self-host root URL. Include scheme. |
| `MCPH_POLL_INTERVAL` | — | `60` | Config-refresh cadence in seconds. `0` disables polling — mcph fetches once at startup and you need to restart the client to pick up dashboard changes. |
| `LOG_LEVEL` | — | `info` | `debug`, `info`, `warn`, or `error`. |

## 5. Verify it works

Run `npx -y @yawlabs/mcph doctor` first — it prints the resolved token + apiBase + the source of each (env, local, project, global, default), then probes `/api/connect/discover` against your instance. Most config typos surface here in <2 seconds.

Then in your MCP client:

- Add a server on the dashboard.
- Restart your MCP client.
- In a new chat, ask the AI to list available tools — you should see `mcp_connect_discover`, `mcp_connect_activate`, `mcp_connect_deactivate`, plus any servers you've activated.
- Check the **mcph connected** indicator on `/dashboard/connect` — it flips green when the CLI polls in.

If tools aren't showing, see [docs/troubleshooting.md](./troubleshooting.md) — the top five causes are a missed client restart, a typo in `MCPH_URL`/`apiBase`, a revoked token, the Windows `cmd /c` wrapper (auto-handled by `mcph install`), or a firewall blocking outbound HTTPS.

## 6. Onboarding the rest of your team

1. Have each team member sign up via magic-link on `https://your-domain.example`. Seat count is enforced per license — see [docs/license.md](./license.md).
2. Each member creates their own token and puts it in their own client config. Tokens are per-user, not per-team.
3. Team-level server config is shared via Team plans — one owner creates the team in the dashboard and invites members.
