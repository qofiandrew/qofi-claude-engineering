# cto-watcher

A long-running Node process that shuttles Discord messages between the **CTO
channels** and the shared **`#cpo-cto-bus`** channel, in real time, over the
gateway (websocket). It is the automated relay between the CPO and the CTO
swarms.

```
   #reserve-backend-2 ─┐                          ┌─ CPO bot reads here
   #qofi-ios-app ──────┼──[ cto-watcher ]──▶ #cpo-cto-bus
   #press-backend ─────┘   shuttles both        ◀─ CPO bot writes "[name] …" here
                           directions

   #qofi-product  ← operator ↔ CPO.  The watcher is NOT in it and never touches it.
```

The watcher is its **own Discord bot identity** — separate from the CPO bot and
from every CTO swarm bot.

## Routing rules (exactly as implemented in `routing.js`)

The **`[name]` tag is the routing key**; an **@mention is the "act on this"
trigger**. They are separate concerns on purpose.

1. **CTO channel → bus.** Any message in a CTO channel whose author is *not the
   watcher itself* is prefixed `[<cto-name>] ` and posted to the bus, **@mentioning
   the CPO bot** so it reliably picks it up. `<cto-name>` is the **config map key**
   for that channel (not Discord's display name), so it round-trips through rule 2.
2. **Bus → CTO (CPO only, mention-gated).** A bus message is routed only if **all**
   hold: it is **authored by the CPO bot** (strict `cpoBotUserId` match), it
   **@mentions the watcher** (when `busRequiresMention` is true, the default), and
   after stripping the watcher mention it starts with `[<name>] `. The name is
   looked up in the exact `ctoChannels` map. **Found:** strip the prefix, post the
   remainder to that CTO's channel **by channel id**, **@mentioning that CTO's bot**
   (its `botUserId`) so the CTO swarm acts on it. **Not found:** *fail closed* — do
   not send, log it, and **DM every operator on `alertUserIds`** naming the
   unmatched `[<name>]`. Never guess a destination, never broadcast.
3. **Bus, authored by the watcher itself → ignore.** This is already-shuttled CTO
   traffic; ignoring it is the loop guard.
4. **Anything else → ignore.**

Two independent locks stop accidental routing: a stray **human** message in the
bus fails the author check (it isn't the CPO bot), and a stray **CPO** message
without the watcher @mention fails the trigger check. Author identity is the only
signal used to tell CPO traffic from the watcher's own shuttled traffic — content
is never parsed to guess the author.

> **Why @mention the recipient bot on every hop?** Your swarms run the `bridge/`
> plugin, which *ignores bot messages that don't @mention the receiving bot*. So a
> routed directive that didn't ping the destination CTO bot would silently never be
> acted on. The watcher therefore pings the CPO bot when shuttling to the bus, and
> the destination CTO bot when delivering. A CTO entry given as a bare channel-id
> string (no `botUserId`) is delivered **without** a mention — use that only for
> channels read by a human or a CTO that doesn't require mentions.

> **Belt-and-suspenders on the Discord side:** set `#cpo-cto-bus` permissions so
> only the CPO bot and the watcher can **Send** (deny `@everyone` Send). That
> physically prevents accidental human posts, on top of the two logic locks above.

### Attachments (`.md`/`.txt` files ride along) — `attachments.js`

The watcher **reposts** (composes a fresh message *as itself*); it does **not** use
Discord's native forward, so attachments don't carry over for free. To shuttle a
file it **downloads** the bytes from the attachment's CDN url and **re-uploads** them
on the reposted message. This closes the gap that broke the **message-overflow path**:
a long response is sent as an attached file, and those files used to be dropped.

- **Both directions, only `.md`/`.txt`.** Every shuttle-eligible attachment is
  downloaded and re-attached to the reposted message, with its **original filename
  preserved**; the text still gets its usual treatment (CTO→bus: `[name]` prefix added;
  bus→CTO: `[name]` prefix stripped) and the file(s) ride on that **same** message.
  Any other file type (`.png`, `.zip`, …) is ignored; a mixed message carries only its
  `.md`/`.txt` parts.
- **File-only messages still shuttle.** The empty-content backstop now skips a CTO
  message only when it has **neither text nor a `.md`/`.txt` attachment** — a file-only
  overflow message (empty body, one `.md`) is reposted carrying the file. (A *bus*
  message with no `[name]` directive is still ignored — there's no destination to route a
  bare file to.)
- **Existing gates are unchanged.** The inbound author allowlist (only the channel's CTO
  identity shuttles), the loop guard (the watcher's own reposted file-bearing messages are
  ignored, so a re-upload never re-triggers a shuttle), fail-closed routing, and the
  pause/kill switch all govern the file path exactly as they govern text.
- **Failures degrade, never crash.** A download error/timeout or an oversize file
  (> `maxAttachmentBytes`, default 8 MiB; see [Configuration](#configuration)) posts the
  text plus a `[watcher: could not relay attached <filename>]` note instead of the file.
  If the file-bearing send is itself rejected (e.g. the gateway upload limit), the watcher
  retries text-only so the message is never lost.

## ⚠️ Required manual Developer Portal step (or it silently shuttles nothing)

The message **body** arrives **empty** unless the privileged **Message Content
Intent** is enabled. You must do **both**:

- **In code** (already done in `index.js`): declare `GatewayIntentBits.Guilds`,
  `GuildMessages`, and `MessageContent`.
- **In the portal** (manual): Developer Portal → your app → **Bot** → **Privileged
  Gateway Intents** → toggle **Message Content Intent** ON.

Without the portal toggle the watcher connects, sees every `messageCreate` with an
empty `content`, and relays nothing — a silent no-op.

## Developer Portal setup (one time)

1. **Create the app.** [Discord Developer Portal](https://discord.com/developers/applications)
   → **New Application**. Name it `cto-watcher` so it is visually distinct from the
   CPO and CTO bots.
2. **Bot tab** → set a username/avatar → **Privileged Gateway Intents** → enable
   **Message Content Intent** (see the warning above).
3. **Bot tab** → **Reset Token** → copy it. Put it in `cto-watcher/.env` (below).
   The token is shown once.
4. **Invite with least privilege — per-channel member overwrites, NOT a broad role.**
   Generate an invite (**OAuth2 → URL Generator → scope `bot`**, Integration type
   **Guild Install**) with only **View Channels**, **Send Messages**, **Read
   Message History**, then add the bot to the server. Then, on each channel,
   grant access as a **per-channel permission overwrite on the bot member** so the
   watcher is scoped exactly:
   - **Each CTO channel** (`#reserve-backend-2`, `#qofi-ios-app`, `#press-backend`,
     …): **View Channel** + **Read Message History** (read only — the watcher never
     writes to CTO channels except to deliver a routed CPO directive, which is a
     Send; grant **Send Messages** on CTO channels too so routing can land).
   - **`#cpo-cto-bus`**: **View Channel** + **Read Message History** + **Send
     Messages** (read **and** write).
   - Do **not** add the watcher to `#qofi-product`.

> Fail-closed alerts are **DMs to the operators in `alertUserIds`**, not a channel
> post — so no alert-channel grant is needed. The bot can DM any user it shares a
> server with; just make sure each operator allows DMs from server members.
>
> The watcher needs **Send** on CTO channels (to deliver routed CPO directives) and
> on the bus (to deliver shuttled CTO traffic). It stays out of `#qofi-product`
> entirely by simply never being added to it.

## Configuration

Two files, both gitignored:

### `.env` — the watcher's bot token
```sh
cp .env.example .env
# paste the token from portal step 3 into DISCORD_BOT_TOKEN
```

### `config.json` — operator-owned channel/identity map
```sh
cp config.example.json config.json
```
Fields (all are Discord **snowflakes** — enable Developer Mode in Discord, then
right-click to copy ids):

| field | what it is | how to find it |
| --- | --- | --- |
| `busChannelId` | the `#cpo-cto-bus` channel id | right-click `#cpo-cto-bus` → Copy Channel ID |
| `cpoBotUserId` | the CPO (`qofi-product`) **bot user** id (NOT a channel) | right-click the CPO bot's name → Copy User ID |
| `alertUserIds` | array of operator **user** ids to DM on a fail-closed event | right-click each operator → Copy User ID |
| `busRequiresMention` | require the CPO to @mention the watcher to route (default `true`) | — |
| `ctoChannels` | `{ "<name>": { "channelId": …, "botUserId": … } }` | one entry per CTO; `<name>` is what the CPO uses in `[name]` |

A `ctoChannels` entry may also be the shorthand `"<name>": "<channel_id>"` (no
`botUserId`) — then the routed message is posted **without** a mention. Use the
full `{ channelId, botUserId }` form for any CTO whose swarm only acts on mentions
(the normal case).

Optional **non-snowflake** tuning knobs (liveness thresholds, usage-limit feed, and
the attachment caps `maxAttachmentBytes` / `attachmentDownloadTimeoutSeconds`) all have
sane defaults and may be omitted — each is documented inline in `config.example.json`.

The `ctoChannels` keys are the names the CPO uses in its `[name]` tags — one per
**CTO swarm registered in `../swarm.conf`** (its engineering-cto rows are the
routing authority; `qofi-product` is the CPO, not a CTO channel, so it is not a
key here). The example seeds one entry per current CTO swarm with channel ids
filled and **bot user ids left to fill in** — it intentionally carries no
hardcoded count or roster of its own, so it never goes stale as the fleet grows.
`swarm.conf` is the source of truth for which CTOs exist. **Edit this map whenever a CTO is added or
removed**, then restart the watcher. Config is validated at startup — a malformed
map (non-numeric id, a bus id reused as a CTO channel, the watcher sharing the CPO
identity) aborts with a clear error rather than relaying wrongly.

### ⚠️ Adding a new CTO requires TWO edits — the map *and* the ACL

> **Onboarding does this for you.** `bin/swarm-add.sh` (and therefore
> `bin/swarm-new.sh`, which execs it) performs **both** edits below in its
> phase 4e for any `engineering-cto` swarm — it prompts for the bot user id
> (== the app's Application ID, phase 2b), writes the `ctoChannels` entry, and
> appends the watcher id to the channel's `allowFrom`. The steps below are the
> manual equivalent, for when you're wiring a CTO outside the standup script.
> After either path, **restart the watcher** so it reloads `ctoChannels`.

The `ctoChannels` map is only half the wiring. When you add a new CTO channel you
**must** do both of the following, or the watcher will shuttle directives into the
new CTO's channel and the CTO will **silently drop them**:

1. **Add it to the `ctoChannels` map** above (its `name` → `channelId` + the CTO's
   `botUserId`), then restart the watcher.
2. **Add the WATCHER bot id `1510298728148369448` to the new CTO channel's
   `allowFrom`** in `~/.claude/channels/discord/access.json`
   (`groups[<newCtoChannelId>].allowFrom`).

Why (2) is mandatory: the watcher reposts a `[name]` directive into the CTO's
channel by **posting as itself**, so the message's author is the **watcher bot**
(`1510298728148369448`), not the CPO. The CTO's `bridge/` plugin only honors
messages whose author is in **that channel's `allowFrom`**. Without the watcher id
on the new CTO channel's `allowFrom`, every shuttled directive is rejected by the
new CTO's bridge and the CTO never picks up requests. The edit is purely additive —
append the watcher id, don't remove or reorder existing entries — and back up
`access.json` first (it is a live, shared file every swarm reads).

## Run

```sh
npm install            # installs discord.js + dotenv
npm start              # foreground, for a quick smoke test
```

Under **pm2** (the supervised, auto-restart path):

```sh
npm install -g pm2     # pm2 is not installed on this machine yet
pm2 start ecosystem.config.cjs
pm2 logs cto-watcher
pm2 save               # persist; run `pm2 startup` once to survive reboot
```

`instances: 1` is deliberate — a relay must be a singleton, or two copies would
double-shuttle every message.

## Test (local dry-run, no network)

```sh
npm test               # node --test on routing.test.js
```

The test simulates a CTO-channel message and CPO bus messages with a **known** and
an **unknown** `[name]`, and asserts correct routing plus that the unknown name
**fails closed** to the operator-alert channel. It never touches Discord. The
attachment helpers (`attachments.test.js`) inject a fake downloader/sender, so the
download-failure, oversize, and text-only-fallback paths are exercised with no network.

## Operational notes

- Every shuttle logs to stdout (`[shuttle]`, `[route]`, `[unmatched]`) with
  direction, source/destination, and matched/unmatched — pm2 captures it.
- Attachment shuttling logs `[attach]` lines: which `.md`/`.txt` file(s) were carried,
  and any that couldn't be relayed (with the reason). See
  [Attachments](#attachments-mdtxt-files-ride-along--attachmentsjs).
- Gateway disconnects/reconnects/resumes are logged (`[gateway]`). Silent death
  means shuttling stops invisibly, so reconnection is never silent.
- Loop prevention: the watcher ignores `message.author.id === client.user.id`
  everywhere, so neither its bus posts nor its routed CTO posts are ever
  re-shuttled — including reposts that carry a re-uploaded file.

## Usage-limit state (RATE_LIMITED) — waiting out a Claude cap

A CTO swarm that hits its Claude Max usage / 5-hour limit goes **silent** — but
not because it's stuck: it's throttled and **cannot act** until the cap resets.
Pinging it (or having the CPO re-drive it) is wasted noise. The watcher detects
this and treats it as a distinct state.

**How it learns the cap** — the watcher can't see the tmux pane, so it reads the
signal `swarm-watch.sh` already produces. That watcher scrapes each swarm's pane,
detects the limit message, parses the reset hint, and writes a **`swarm-status/v1`
snapshot** to `status.json` (default `~/.config/swarm/status.json`). The cto-watcher
reads that file each liveness tick: any swarm whose `state` is `paused-limit` is
marked **`RATE_LIMITED`**. This is an **overlay** on the CPO-declared state — the
underlying `DRIVING`/`WAITING_FOR_OPERATOR`/`STOOD_DOWN` (owned solely by the CPO's
`STATE:` lines) is untouched. Override the path with `CTO_WATCHER_SWARM_STATUS_JSON`,
or point `SWARM_STATE_DIR` at the directory.

**Fail-safe, not fail-closed.** If the feed is missing, unreadable, malformed, or
**stale** (older than `swarmStatusMaxAgeSeconds`, i.e. `swarm-watch` is probably
dead), the overlay is left **unchanged** — "don't know" beats guessing a cap on or
off from bad data.

**While `RATE_LIMITED`:** the loop is **never pinged** — the watcher waits for the
cap to clear.

**When the cap clears** (the feed flips `state` away from `paused-limit`, the real
observed lift): the watcher arms a **resume buffer** (`resumeBufferSeconds`, default
3m). After the buffer:

- If the loop **came back on its own** (fresh CTO activity since the clear — Claude
  Code auto-resumes the queued turn at reset), **no nudge** — it already resumed.
- If the underlying state is `WAITING_FOR_OPERATOR` / `STOOD_DOWN` (intentional
  non-driving), **no nudge** — a cap clearing must not shove it back to driving.
- Otherwise (a `DRIVING`/`UNKNOWN` loop still quiet), the watcher posts an **active
  resume nudge** to the bus (@mentioning the CPO, naming the CTO) to resume driving.

After that, **normal ping rules resume** — the silence clock is reset to the clear
time, so the loop isn't pinged for silence accrued during the cap, and is pinged
again only if it goes quiet afresh.

> Both the overlay tracking and the resume nudge live behind `livenessEnabled` (the
> nudge is gated like a revival ping — AUTO-only, suppressed while the kill switch
> is paused). `!watcher state` calls a fresh feed read on demand, so it shows
> `RATE_LIMITED` (with the reset hint) even when liveness is off.

## DM kill switch (soft pause)

Send the watcher bot a **direct message** (DM only — never a guild channel):

- `!watcher stop` — pause: relay shuttles nothing, liveness pings nothing. The
  process stays connected and alive under pm2 (inert, not dead); it keeps tracking
  per-CTO state/activity in memory so resume has current data.
- `!watcher start` — resume.
- `!watcher status` — report PAUSED/ACTIVE + uptime.
- `!watcher state` — read-only per-CTO liveness readout (state, activity, ping
  status). Works while paused and mutates nothing; see "Liveness" below.

The watcher replies in the DM to confirm every recognized command. Commands are
exact and case-insensitive.

**Authorization:** a command is honored only if the sender's id is in the
**operator channel group's `allowFrom`** in `access.json`
(`groups[<operatorChannelId>].allowFrom`, read fresh per command). Add an operator
to `#qofi-product` and they're automatically authorized; the watcher bot / bus
allowlist can **not** drive the switch. If the ACL can't be read, **no one** is
authorized (fail-closed). `operatorChannelId` in `config.json` is a **lookup key
only** — the watcher never joins, posts in, or reads `#qofi-product`.

**State is in-memory: pause does NOT survive a restart.** A `pm2 restart` (or
crash) brings the watcher back **ACTIVE** — a deliberate safe default. Re-issue
`!watcher stop` after a restart if you still want it paused.
