# LEARNINGS.md — repo-local lessons (CTO-maintained, evidence-cited)

Repo-local engineering lessons for **this** swarm, authored and maintained by the
CTO — the same authority class as `PROJECT_SPEC.md` and the ADRs in `docs/adr/`.
Teammates **read** this for hard-won context; they do **not** add to or
generalize it (`CLAUDE.md` §*Learnings*). This is the **Tier-1** half of the
learning loop (`TEAM_LEAD.md` §*Learning loop*).

## What belongs here
- A lesson from a **real incident in this repo** — a regression, a failed
  approach, a footgun that bit us — with **cited evidence**: the commit SHA, the
  PR, the failing test, or the approach that didn't work. A learning without
  evidence is an opinion; don't record it.
- It is **strictly subordinate to doctrine.** A lesson that appears to contradict
  the floor (`_base` doctrine in `CLAUDE.md`, `ESCALATION.md`, the spec, an ADR,
  or a contract another module depends on) is a `§Conflict handling` surfacing,
  **never** a quiet local override.

## What does NOT belong here
- Generalizable doctrine. When a lesson looks like it transcends this one repo
  (it **recurs** across ≥2 incidents or repos), it is **proposed, never
  self-applied** — surfaced through the CPO for the operator to ratify
  (`TEAM_LEAD.md` §*Learning loop*, Tier 2; `ESCALATION.md` §*Doctrine-
  generalization proposal*). You never promote a learning into `templates/`
  yourself.

## Format (one entry per lesson)
```
### <short title> — <YYYY-MM-DD>
- **What happened:** <the incident, one or two lines>
- **Evidence:** <commit SHA / PR / failing test / cite — required>
- **Lesson:** <what to do differently, concretely>
- **Scope:** repo-local (Tier 1) | candidate for generalization → flagged to CPO
```

<!-- The CTO appends entries below as incidents teach us something. An empty
     LEARNINGS.md is correct on a new repo — this file earns its content from
     real events, not up front. -->
