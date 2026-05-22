#!/usr/bin/env bash
# swarm-lib.sh — shared helpers for swarm-watch.sh and swarm-typing.sh.
#
# Sourced, not executed. Bash 3.2-safe. Does NOT call `set` — the caller owns
# shell options. python3 is the only non-shell dependency (already required
# by both callers).
#
# The "is this swarm producing work?" signal that lives here is shared so the
# watcher (state machine) and the typing pinger (boolean fire) can never drift.
#
# Why python3 and not `stat -f`: `stat -f` is BSD-only (it silently no-ops or
# errors out on the GNU stat shipped by some installs / Linux CI). The rest
# of the swarm scripts already use python3 for mtimes for the same reason.

# repo_activity REPO_PATH CLAUDE_PROJECTS_DIR STALE_SECONDS
#
# Walks every Claude Code project dir associated with REPO_PATH — the lead's
# own dir AND every per-teammate worktree dir — recursively, including the
# subagents/ subdir where teammate transcripts live. Returns:
#
#     "<newest_age_seconds>|<active_teammate_count>"
#
# - newest_age_seconds: integer seconds since the most recently modified
#   *.jsonl anywhere under those dirs. Empty if NO jsonl exists at all
#   (swarm just started, transcripts not yet flushed).
# - active_teammate_count: number of distinct teammate worktree dirs whose
#   most recent jsonl is ≤ STALE_SECONDS old. 0 if none.
#
# Matching is by encoded-path prefix (Claude Code encodes a project's cwd
# by replacing every '/' and '.' with '-' and prepending '-'). Teammate
# worktree dirs match the prefix "<lead-encoded>--claude-worktrees-" so
# this never accidentally folds in a similarly-named sibling repo.
repo_activity() {
  local repo="$1" projects="$2" stale="$3"
  python3 - "$repo" "$projects" "$stale" <<'PY'
import os, re, sys, time
repo, projects, stale = sys.argv[1], sys.argv[2], int(sys.argv[3])

# Lead's project dir name = the repo path with '/' and '.' replaced by '-'.
lead_enc = re.sub(r"[/.]", "-", repo)
teammate_prefix = lead_enc + "--claude-worktrees-"

now = time.time()
newest_age = None
teammate_newest = {}  # encoded_dir -> newest jsonl age in that dir

try:
    entries = os.listdir(projects)
except FileNotFoundError:
    print("|0")
    raise SystemExit(0)

for entry in entries:
    is_lead = (entry == lead_enc)
    is_teammate = entry.startswith(teammate_prefix)
    if not (is_lead or is_teammate):
        continue
    for root, _, files in os.walk(os.path.join(projects, entry)):
        for f in files:
            if not f.endswith(".jsonl"):
                continue
            try:
                mt = os.path.getmtime(os.path.join(root, f))
            except OSError:
                continue
            age = int(now - mt)
            if age < 0:
                age = 0
            if newest_age is None or age < newest_age:
                newest_age = age
            if is_teammate:
                prev = teammate_newest.get(entry)
                if prev is None or age < prev:
                    teammate_newest[entry] = age

active = sum(1 for a in teammate_newest.values() if a <= stale)
age_str = "" if newest_age is None else str(newest_age)
print(f"{age_str}|{active}")
PY
}
