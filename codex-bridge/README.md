# codex-bridge — Discord channel for Codex CLI

The Codex counterpart of `../bridge` (the Claude Code Discord plugin). Same
Discord semantics — pairing, allowlists, per-channel opt-in, hard channel
binding, bot-to-bot @mention rules, 2000-char chunking — but a different
integration shape, because Codex CLI has no equivalent of Claude Code's
channels capability (the MCP hook that pushes inbound messages into a live
session).

So instead of an MCP plugin, this is a **standalone daemon**:

```
Discord gateway ──▶ gate (access.json) ──▶ FIFO queue ──▶ codex exec --json
                                                             │ (resume per-chat thread)
Discord channel ◀── chunk ◀── final agent_message ◀──────────┘
```

- One Codex **thread per Discord chat** (`sessions.json`), resumed with
  `codex exec resume <thread-id>` so conversation context survives both
  message boundaries and daemon restarts.
- Codex's **final agent message** of each turn is posted back to the chat,
  chunked at ≤2000 chars. A first-turn preamble teaches Codex the contract.
- Turns are **globally serialized** (Codex writes to the agent's repo; two
  concurrent turns in one working tree would race).
- Attachments are downloaded to `<state>/inbox/` up front and their paths
  listed in the prompt (Codex has no lazy `download_attachment` tool).

## What's intentionally identical to the Claude plugin

- `access.json` format and location semantics, the pairing flow (6-char code,
  1h expiry, resend cap 2, pending cap 3), `approved/<senderId>` confirmation
  protocol, `DISCORD_ACCESS_MODE=static`, `DISCORD_BOUND_CHANNEL` binding,
  delivery config (`ackReaction`, `replyToMode`, `textChunkLimit`,
  `chunkMode`, `mentionPatterns`).
- Bot-to-bot rules: own messages ignored; bot messages ignored unless they
  @mention this bot — so a Codex agent slots into the existing swarm bus and
  cto-watcher routing unchanged.
- The `<channel source="discord" ...>` inbound envelope format.

`binding.ts` and `normalize.ts` are imported from `../bridge` directly (both
are pure modules); the gate/chunking logic is ported into `gate.ts`/`chunk.ts`
with tests, keeping the plugin itself untouched and self-contained.

## What's different

| | Claude plugin (`../bridge`) | codex-bridge |
| --- | --- | --- |
| Shape | MCP server inside a live session | standalone daemon driving `codex exec` |
| Inbound delivery | `notifications/claude/channel` | prompt envelope per turn |
| Session | the one live Claude session | one Codex thread per chat, resumed |
| Outbound | `reply`/`react`/`edit_message` tools | final agent message auto-posted |
| Permission relay | Discord buttons / `yes <code>` | none — sandbox policy instead (`CODEX_SANDBOX`) |
| Access admin | `/discord:access` skill | `bun cli.ts …` on the host |

There is no permission relay: `codex exec` is non-interactive, so the safety
boundary is the Codex sandbox mode, not per-call approval. Default is
`workspace-write`.

## Setup

1. Create a Discord bot (same steps as `../bridge/README.md` §1 — enable the
   Message Content intent, invite it to the server).
2. Put the token in the state dir:

   ```sh
   mkdir -p ~/.codex/channels/discord
   echo 'DISCORD_BOT_TOKEN=MTIz...' > ~/.codex/channels/discord/.env
   chmod 600 ~/.codex/channels/discord/.env
   ```

3. Run the daemon from the agent's repo:

   ```sh
   cd /path/to/agent-repo
   CODEX_BRIDGE_CWD=$PWD DISCORD_BOUND_CHANNEL=<channel-id> \
     bun ~/qofirepos/qofi-claude-engineering/codex-bridge/daemon.ts
   ```

4. Opt in the channel and (for DMs) approve pairings:

   ```sh
   cd codex-bridge
   bun cli.ts group add <channel-id> --require-mention
   bun cli.ts pair <code>        # after the bot replies with a pairing code
   bun cli.ts status
   ```

## Environment

| Var | Default | Meaning |
| --- | --- | --- |
| `DISCORD_BOT_TOKEN` | — (required) | bot identity; may live in `<state>/.env` |
| `DISCORD_BOUND_CHANNEL` | unset | comma-separated channel ids the bot answers in |
| `DISCORD_STATE_DIR` | `~/.codex/channels/discord` | access.json, sessions.json, inbox/ |
| `DISCORD_ACCESS_MODE` | dynamic | `static` pins access.json to its boot snapshot |
| `CODEX_BRIDGE_CWD` | `$PWD` | working dir Codex runs in (the agent's repo) |
| `CODEX_SANDBOX` | `workspace-write` | `read-only` \| `workspace-write` \| `danger-full-access` |
| `CODEX_MODEL` | codex default | model override |
| `CODEX_PROFILE` | unset | `-p` config profile |
| `CODEX_TURN_TIMEOUT_MS` | `1800000` | hard kill for a stuck turn (30 min) |
| `CODEX_BIN` | `codex` | binary path override |
| `CODEX_BRIDGE_PREAMBLE_EXTRA` | unset | extra brief appended to the first-turn preamble (swarm-up.sh injects the doctrine directive here) |

Multiple agents on one machine: give each its own `DISCORD_STATE_DIR` (own
token, own sessions) — exactly like running multiple Claude bridge identities
with per-session env.

## Tests

```sh
bun test codex-bridge
```

Covers the gate decision table, pairing lifecycle, chunking, the JSONL event
parser (fixtures captured from codex-cli 0.142.3), arg construction (note:
`exec resume` rejects `-s`/`-m` — sandbox/model ride as `-c` overrides),
session persistence, and the access CLI including the `approved/` protocol.
