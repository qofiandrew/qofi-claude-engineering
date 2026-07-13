---
name: dead-code-scan
description: "Operator-invoked, detection-only scan for dead-code and unused-dependency candidates in TypeScript and Node repositories; it reports and never deletes."
---

# Codex route to the canonical skill

From the repository root, open `.claude/skills/dead-code-scan/SKILL.md`, read it
completely, and follow it as the authoritative skill body. This small shim
exists because Codex discovers repository skills under `.agents/skills/`, while
the shared canonical body is also used by Claude. If the routed file is missing,
report template drift instead of improvising the scan.
