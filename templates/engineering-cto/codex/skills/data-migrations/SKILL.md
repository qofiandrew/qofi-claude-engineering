---
name: data-migrations
description: "Safe schema and data-migration playbook covering expand-contract, batched idempotent backfills, online changes, rollback, and test-on-a-copy discipline."
---

# Codex route to the canonical skill

From the repository root, open `.claude/skills/data-migrations/SKILL.md`, read it
completely, and follow it as the authoritative skill body. This small shim
exists because Codex discovers repository skills under `.agents/skills/`, while
the shared canonical body is also used by Claude. If the routed file is missing,
report template drift instead of improvising the playbook.
