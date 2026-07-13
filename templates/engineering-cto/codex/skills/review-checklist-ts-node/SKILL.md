---
name: review-checklist-ts-node
description: "R5 review checklist and native verification commands for TypeScript and Node diffs. Load when reviewing a matching stack."
---

# Codex route to the canonical skill

From the repository root, open
`.claude/skills/review-checklist-ts-node/SKILL.md`, read it completely, and
follow it as the authoritative skill body. This shim exists because Codex
discovers repository skills under `.agents/skills/`, while the shared canonical
body is also used by Claude. If the routed file is missing, report template
drift instead of improvising the checklist.
