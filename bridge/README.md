# claude-discord-bot-to-bot

A fork of Anthropic's official [Discord channel plugin](https://github.com/anthropics/claude-code-plugins) for Claude Code, modified to support **bot-to-bot messaging**. Multiple Claude Code sessions can coordinate with each other (and with human users) in shared Discord channels via @mentions.

## What's different from the official plugin?

The official Discord plugin ignores all messages from other bots (`if (msg.author.bot) return`). This fork changes that to:

1. Ignore own messages (self-loop prevention)
2. Ignore bot messages that don't @mention this bot (noise filter)
3. **Process bot messages that DO @mention this bot** (bot-to-bot communication)

This lets you run multiple Claude Code agents — each with its own Discord bot identity — and have them talk to each other in shared Discord channels.

## Prerequisites

- [Bun](https://bun.sh) runtime (`curl -fsSL https://bun.sh/install | bash`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) CLI installed
- A Discord account

## Setup

### 1. Create a Discord bot for each agent

Each Claude Code session that needs to send/receive on Discord needs its own bot. Go through these steps once per agent identity:

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications) and click **New Application**. Name it after the agent role (e.g., "Coder", "Reviewer", "Architect").

2. Navigate to **Bot** in the sidebar. Set a username. Optionally set an avatar to visually distinguish agents.

3. Under **Privileged Gateway Intents**, enable **Message Content Intent** — without this the bot receives messages with empty content.

4. Under **Bot** > **Token**, click **Reset Token** and copy it. You'll need this in step 3. The token is only shown once.

5. Navigate to **OAuth2** > **URL Generator**. Select the `bot` scope. Under **Bot Permissions**, enable:
   - View Channels
   - Send Messages
   - Send Messages in Threads
   - Read Message History
   - Attach Files
   - Add Reactions

6. Set **Integration type** to **Guild Install**. Copy the generated URL and open it to add the bot to your server.

7. Repeat for each agent identity.

For the full Discord bot setup guide, see [Anthropic's plugin docs](https://docs.anthropic.com/en/docs/claude-code/plugins).

### 2. Install the plugin

The bridge lives at `bridge/` inside the parent repo and is a self-contained Claude Code plugin directory — `.claude-plugin/plugin.json`, `.mcp.json`, `package.json`, and `server.ts` are all here.

**a. Clone the parent repo:**

```sh
git clone <parent-repo-url> ~/claude-swarm
```

**b. Register `bridge/` directly as a marketplace from inside a Claude Code session:**

```
/plugin marketplace add ~/claude-swarm/bridge
```

This points Claude Code at this directory as a single-plugin marketplace. The marketplace name is the directory name (`bridge`).

**c. Install the plugin:**

```
/plugin install discord-b2b@bridge
```

The plugin name `discord-b2b` comes from `.claude-plugin/plugin.json` in this directory.

If you also have the official `discord` plugin installed, uninstall it from a Claude Code session to avoid conflicts:

```
/plugin uninstall discord
```

### 3. Configure the bot token

Each agent needs its own bot token. There are two ways to set it:

**Option A: Per-session environment variable (recommended for multi-agent)**

Set `DISCORD_BOT_TOKEN` as a session environment variable when launching Claude Code. Each terminal session uses a different token, so each agent gets its own Discord identity:

```sh
# Terminal 1 — "Coder" agent
DISCORD_BOT_TOKEN=MTIz... claude --channels plugin:discord-b2b

# Terminal 2 — "Reviewer" agent  
DISCORD_BOT_TOKEN=NDU2... claude --channels plugin:discord-b2b

# Terminal 3 — "Architect" agent
DISCORD_BOT_TOKEN=Nzg5... claude --channels plugin:discord-b2b
```

The environment variable takes precedence over the `.env` file, so you can run multiple identities on the same machine without conflicts.

**Option B: Config file (single-agent setups)**

From inside a Claude Code session:

```
/discord:configure MTIz...
```

This writes `DISCORD_BOT_TOKEN=...` to `~/.claude/channels/discord/.env`.

### 4. Launch with the channel flag

Claude Code won't connect to Discord unless you pass `--channels` with the full plugin reference:

```sh
claude --channels plugin:discord-b2b
```

Or with the token inline:

```sh
DISCORD_BOT_TOKEN=MTIz... claude --channels plugin:discord-b2b
```

The plugin name `discord-b2b` comes from `.claude-plugin/plugin.json`. The `--channels` flag uses the plugin name — no marketplace qualifier needed.

### 5. Pair and allow

The first time a user or bot DMs your agent's bot, it gets a pairing code. Approve it from the Claude Code session:

```
/discord:access pair <code>
```

For guild channels (shared server channels), opt in by channel ID:

```
/discord:access group add <channel-id>
```

Once everyone is added, lock down the policy:

```
/discord:access policy allowlist
```

## Multi-agent setup

A typical multi-agent setup:

1. **One Discord server** shared by all bots and the human operator
2. **One bot per agent role** — each with a distinct name, avatar, and token
3. **Shared channels** for coordination (e.g., `#dev`, `#reviews`)
4. **Separate terminal sessions**, each launched with a different `DISCORD_BOT_TOKEN`

Agents communicate by @mentioning each other's bots in channels. Messages from bots that don't @mention the receiving bot are ignored (no noise).

## Tools

The plugin exposes these MCP tools to the Claude Code session:

| Tool | Purpose |
| --- | --- |
| `reply` | Send a message. Takes `chat_id` + `text`, optional `reply_to` for threading and `files` for attachments (max 10, 25MB each). |
| `react` | Add an emoji reaction to a message. |
| `edit_message` | Edit a message the bot previously sent. |
| `fetch_messages` | Pull recent history (up to 100 messages, oldest-first). |
| `download_attachment` | Download attachments from a message to the local inbox. |

## License

Apache 2.0 — see [LICENSE](./LICENSE).

---

Fork maintained by [@dsieczko](https://github.com/dsieczko). Original plugin by [Anthropic](https://github.com/anthropics/claude-code-plugins).
