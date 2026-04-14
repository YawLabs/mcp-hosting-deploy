# Pointing mcph at your self-host

Each team member who wants to use the orchestrator installs [`@yawlabs/mcph`](https://www.npmjs.com/package/@yawlabs/mcph) in their MCP client and sets `MCPH_URL` to your self-host instance. The rest of the flow is identical to the hosted product.

## 1. Create a token

- Sign in to `https://your-domain.example`.
- **Settings → API Tokens → Create token.**
- Copy the `mcp_pat_...` value — it's shown once.

## 2. Put mcph in your MCP client config

Three client examples below. The `env` block is the same everywhere; the difference is which config file your client reads.

### Claude Code

`~/.claude.json` (global) or `.mcp.json` (project):

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

`cmd /c` is required on Command Prompt, PowerShell, and Git Bash. Not needed in WSL — use the Linux config there.

## 3. Optional tuning

| Env var | Default | Notes |
|---|---|---|
| `MCPH_TOKEN` | — | **Required.** Personal access token from Settings. |
| `MCPH_URL` | `https://mcp.hosting` | Your self-host root URL. Include scheme. |
| `MCPH_POLL_INTERVAL` | `60` | Config-refresh cadence in seconds. `0` disables polling — mcph fetches once at startup and you need to restart the client to pick up dashboard changes. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error`. |

## 4. Verify it works

- Add a server on the dashboard.
- Restart your MCP client.
- In a new chat, ask the AI to list available tools — you should see `mcp_connect_discover`, `mcp_connect_activate`, `mcp_connect_deactivate`, plus any servers you've activated.
- Check the **mcph connected** indicator on `/dashboard/connect` — it flips green when the CLI polls in.

If tools aren't showing, see [docs/troubleshooting.md](./troubleshooting.md) — the top five causes are a missed client restart, a typo in `MCPH_URL`, a revoked token, the Windows `cmd /c` wrapper, or a firewall blocking outbound HTTPS.

## 5. Onboarding the rest of your team

1. Have each team member sign up via magic-link on `https://your-domain.example`. Seat count is enforced per license — see [docs/license.md](./license.md).
2. Each member creates their own token and puts it in their own client config. Tokens are per-user, not per-team.
3. Team-level server config is shared via Team plans — one owner creates the team in the dashboard and invites members.
