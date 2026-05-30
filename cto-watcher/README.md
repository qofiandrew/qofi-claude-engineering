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

The `ctoChannels` keys are the names the CPO must use in its `[name]` tags. The
example is pre-filled with the three current CTO swarms from `../swarm.conf`
(`reserve-backend-2`, `qofi-ios-app`, `press-backend`) — channel ids filled,
**bot user ids left to fill in**. **Edit this map whenever a CTO is added or
removed**, then restart the watcher. Config is validated at startup — a malformed
map (non-numeric id, a bus id reused as a CTO channel, the watcher sharing the CPO
identity) aborts with a clear error rather than relaying wrongly.

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
**fails closed** to the operator-alert channel. It never touches Discord.

## Operational notes

- Every shuttle logs to stdout (`[shuttle]`, `[route]`, `[unmatched]`) with
  direction, source/destination, and matched/unmatched — pm2 captures it.
- Gateway disconnects/reconnects/resumes are logged (`[gateway]`). Silent death
  means shuttling stops invisibly, so reconnection is never silent.
- Loop prevention: the watcher ignores `message.author.id === client.user.id`
  everywhere, so neither its bus posts nor its routed CTO posts are ever
  re-shuttled.
