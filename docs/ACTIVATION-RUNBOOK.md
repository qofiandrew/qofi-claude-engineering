# ACTIVATION RUNBOOK — hybrid multi-account partition (ADR-0018)

This is the ordered procedure to take the multi-account partition from **inert**
(shipped, all `swarm.conf` rows on the default account) to **live** (some swarms
pinned to isolated accounts, producing concurrently). It exists because activation
crosses a **terms-relevant, operator-only gate**: running more than one real Max
subscription in concurrent automation is the act ADR-0004 flagged and ADR-0018
gates. The build never crosses it — this runbook is how *you* do, deliberately.

Each step is tagged:

- **CC-TOOLED** — a script in `bin/` does it; safe, idempotent, reversible.
- **OPERATOR-ONLY** — you do it by hand; it touches a real credential, the live
  fleet, or the terms boundary. No script here performs these.

> **The load-bearing ordering rule:** F1 (per-pane token isolation) must be LIVE on
> the running fleet **before** any real `OAUTH_TOKEN_*` enters `tokens.env`. A
> pre-F1 launcher auto-exports the whole vault into every pane — so a token added
> before F1 is live would leak every account's credential into every swarm. Steps
> 1–2 enforce this; do not reorder them.

---

## Step 0 — Preconditions (CC-TOOLED check)

- The branch is merged and the scripts are on disk: `bin/swarm-account*.sh`,
  `bin/swarm-up.sh` (F1), `bin/swarm-account-{provision,preflight,verify}.sh`.
- You have decided how many real Max accounts you will run, and have a label for
  each (lowercase, leading letter, `[a-z0-9_-]`; **must be unique after the
  `-`/`_` fold** — `max-a` and `max_a` collide on the vault var name).

## Step 1 — Restart the fleet onto the F1 launcher  ·  OPERATOR-ONLY

Merging the branch does **not** make F1 live; the running panes keep their old
(pre-F1) launch until restarted. Restart every swarm so each pane re-launches
under the F1 isolation:

```sh
export SWARM_HOME="$(git rev-parse --show-toplevel)"
"$SWARM_HOME/bin/swarm-up.sh" status      # see what's running
# restart each (respects the BUSY rail; only --force a working swarm deliberately):
"$SWARM_HOME/bin/swarm-restart.sh" <name>
```

This is operator-only because it cycles live swarms (and can interrupt in-RAM
teammate work if forced). Do it while the fleet is quiet.

## Step 2 — Preflight: confirm F1 is live and the vault is clean  ·  CC-TOOLED

```sh
"$SWARM_HOME/bin/swarm-account-preflight.sh"
```

It asserts (loud PASS/FAIL): the on-disk `swarm-up.sh` **is** the F1 launcher
(scrub loop + scoped derive present, no blanket `set -a`), the partition substrate
is present (resolver / 6th field / atomic rewrite / swap actuator), and
`tokens.env` holds **no** `OAUTH_TOKEN_*` yet (checked by NAME only — it never
reads a value). **Do not proceed past a FAIL.** A `set -a`/missing-scrub FAIL means
the running fleet is still pre-F1 — go back to Step 1.

## Step 3 — Provision each account's isolated config-dir skeleton  ·  CC-TOOLED

For each account label you intend to use:

```sh
"$SWARM_HOME/bin/swarm-account-provision.sh" <label>          # or --dry-run first
```

Idempotent. Creates `~/.claude-accounts/<label>` with the qofi-swarm marketplace,
the `discord-b2b` plugin record, and a **symmetric** `access.json` (one group per
`swarm.conf` channel — so a later failover swap is a field edit + restart, no
access rewrite). It reads/writes **no token** and prints the remaining manual
steps.

## Step 4 — Provision the credential for each account  ·  OPERATOR-ONLY  ·  TERMS GATE

This is the terms-relevant act. For each label:

```sh
CLAUDE_CONFIG_DIR="$HOME/.claude-accounts/<label>" claude setup-token
```

Authenticate the account **in-browser** into its own isolated config dir. This is
where you decide, deliberately, to run a second real Max subscription in concurrent
automation. No script does this for you.

## Step 5 — Put each token in the vault, by NAME  ·  OPERATOR-ONLY

Add the token from Step 4 to `$SWARM_HOME/tokens.env`:

```sh
export OAUTH_TOKEN_<LABEL_UPPER>='<token>'     # e.g. label max-b -> OAUTH_TOKEN_MAX_B
```

`tokens.env` is gitignored; never commit it. The var name is
`OAUTH_TOKEN_<LABEL_UPPER>` with `-`→`_`. Re-run preflight with `--allow-tokens` to
confirm the substrate is still happy (it will NOTE the token name, not fail).

## Step 6 — Ratify and apply the label assignment  ·  OPERATOR-ONLY

Decide which swarm goes on which account (see the **DRAFT PROPOSAL** below — it is
a proposal to ratify, **not** applied by anything). Then edit `swarm.conf` field 6
(`ACCOUNT`) for each chosen row to its label. Leave a row blank to keep it on the
default account.

> A swap on an already-running swarm can also be done with the actuator —
> `bin/swarm-account.sh <name> <label>` — which auth-probes the target, checkpoints,
> rewrites field 6, and restarts. For first-time activation, editing `swarm.conf`
> directly then restarting (Step 7) is the simplest path.

## Step 7 — Restart the labeled swarms  ·  OPERATOR-ONLY

```sh
"$SWARM_HOME/bin/swarm-restart.sh" <name>      # each swarm you labeled
```

Each labeled swarm re-launches under its account's `CLAUDE_CONFIG_DIR` +
`CLAUDE_CODE_OAUTH_TOKEN`. Unlabeled swarms are byte-identical to before.

## Step 8 — Verify independence  ·  CC-TOOLED

```sh
"$SWARM_HOME/bin/swarm-account-verify.sh"                         # structural probe
# dynamic proof (optional, strongest):
"$SWARM_HOME/bin/swarm-account-verify.sh" --baseline
#   ... drive a bit of activity on ONE account ...
"$SWARM_HOME/bin/swarm-account-verify.sh" --check --moved <label>
```

The probe confirms each labeled account resolves a **distinct** isolated config dir
and has a token; the `--baseline`/`--check` pair confirms exercising one account
moves **only** that account's usage (others flat). A `PASS*`/INCONCLUSIVE result
just means no usage signal was wired (set `SWARM_ACCOUNT_USAGE_CMD` or install
`ccusage`); the structural isolation still holds.

## Rollback  ·  OPERATOR-ONLY

To return a swarm to the default account: blank its `swarm.conf` field 6 (or
`bin/swarm-account.sh --reset`) and restart it. To back the feature out entirely:
all-empty `ACCOUNT` fields make the mechanism inert and the fleet byte-identical to
pre-activation. De-provisioning is deleting the `~/.claude-accounts/<label>` dirs
and removing the vault tokens.

---

## DRAFT label-assignment PROPOSAL (ratify — NOT applied)

**Stated account pool (assumption — adjust to what you actually provision):** the
existing **default** (keychain) account plus **two** additional Max accounts
labeled `max-a` and `max-b`. Three accounts → three concurrent partitions.

Current `swarm.conf` has six swarms (all on the default today). A balanced 2/2/2
split:

| swarm               | proposed account | rationale                               |
| ------------------- | ---------------- | --------------------------------------- |
| `reserve-backend-2` | *default*        | keep the busiest lane on keychain auth  |
| `qofi-ios-app`      | *default*        | pairs with reserve on the default pool  |
| `qofi-product`      | `max-a`          | move product work to its own window     |
| `press-backend`     | `max-a`          | co-locate the two press-adjacent lanes… |
| `press-fileops`     | `max-b`          | …split across max-a/max-b so neither    |
| `deployment-core`   | `max-b`          | account caps the whole press effort     |

Notes for ratification:

- This is **one** reasonable split, not a recommendation you must take. Concentrate
  or spread differently to taste; blank = default.
- **Co-location is not durable.** Per ADR-0018, the first time an account caps, its
  swarms spread-evacuate to non-capped accounts and **stay there** — any
  intentional co-location above dissolves after the first cap. If a shared-window
  assumption matters, you must re-assert it manually (`--reset`).
- A single Max pool feeds only ~1–2 concurrent teams through a full week; the whole
  point of the pool is to lift that ceiling. Size the pool to your real concurrency.
- Apply by editing `swarm.conf` field 6 (Step 6), not by any script in this repo.
