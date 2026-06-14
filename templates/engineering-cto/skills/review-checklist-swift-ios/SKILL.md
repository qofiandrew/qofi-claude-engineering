---
name: review-checklist-swift-ios
description: R5 review checklist for Swift / iOS diffs — the language-specific review pass the reviewer/CTO runs over a Swift change, plus the native tools to run (swiftlint, swift build, xcodebuild test). Load when reviewing Swift / iOS code. This concretizes the always-loaded doctrine's review/DoD gates (CLAUDE.md §Definition of done, TEAM_LEAD.md §Independent review & security gates) for this stack; it is an on-demand skill, not a floor, so it costs no context in repos whose stack doesn't match. Inert when there is no Package.swift / .xcodeproj / .xcworkspace.
---

# review-checklist-swift-ios — Swift / iOS R5 review pass

An **on-demand companion** to the always-loaded doctrine, not a replacement.
Where this skill and `CLAUDE.md` overlap, `CLAUDE.md` wins. This is the
*stack-specific concretion* of the independent-review gate (`TEAM_LEAD.md`
§*Independent review & security gates*) and the DoD self-review (`CLAUDE.md`
§*Definition of done*) — what to look at when the diff is Swift / iOS.

**Inert when the stack doesn't match.** No `Package.swift`, `*.xcodeproj`, or
`*.xcworkspace` in the repo → this skill does not apply; produce nothing. (Same
zero-context posture as `ts-node-stack`.)

## Native tools to run first (deterministic, before the human-judgment pass)
Run the repo's own commands / scheme; don't invent flags the repo doesn't use:
- **`swiftlint`** (if configured) — clean. New `// swiftlint:disable` directives
  are a review item, not a free pass (see the suppression check).
- **`swift build`** (SwiftPM) or the project's **`xcodebuild build`** — must
  compile clean; warnings introduced by the diff are review items.
- **`xcodebuild test`** (the repo's scheme) or **`swift test`** for SwiftPM — green,
  at/above the `quality-bar.md` coverage floor. Never lower the floor to pass
  (`CLAUDE.md` §*Verification*).

## Review checklist (human-judgment pass — what the scanners can't see)
- **Optionals handled, not force-unwrapped.** A new `!` force-unwrap or
  `as!`/`try!` that can crash on bad input is a finding — expect `guard let` /
  `if let` / `??`. Force-unwrap is the Swift face of "don't leave half-written
  state on failure" (`CLAUDE.md` §*Error handling*).
- **Errors surfaced, not swallowed.** No `try?` that discards a meaningful error,
  no empty `catch {}` that drops the cause (`CLAUDE.md` §*Error handling* — never
  silently swallow). Handle or propagate with context.
- **Concurrency correctness.** UI/state mutation is on the main actor
  (`@MainActor` / `DispatchQueue.main`); no data race across `Task`s; `async`
  results are awaited, not fire-and-forget; respect Sendable where the compiler
  asks.
- **Retain cycles.** Escaping closures that capture `self` use
  `[weak self]` / `[unowned self]` where a cycle would otherwise form
  (delegates, timers, Combine sinks, async callbacks).
- **No secrets / PII in logs or source.** No API key, token, or raw user content
  in `print`/`os_log` or hardcoded in the binary (`CLAUDE.md` §*Logging &
  observability* / §*Secrets*).
- **No suppression-to-go-green.** A new `// swiftlint:disable`, a warning
  pragma, or a test marked skipped that exists only to silence a real failure is
  a regression (`CLAUDE.md` §*Verification*). Each must be justified at its use
  site or it's a finding.
- **Contract surfaces typed + documented.** A `public`/`open` API the diff adds
  or changes is a contract surface — additive is safe, changing an existing
  signature/semantics is breaking and needs sign-off (`CLAUDE.md` §*Backward
  compatibility*).

## Confidence discipline (carry the gate's rule into the pass)
Report only findings held at **≥80% confidence** (`TEAM_LEAD.md` §*Independent
review*). Consolidate similar findings; order security-first.

## What this skill is not
Not a gate of its own and not a place for logic — it is a *checklist* the
reviewer/CTO applies. The gating authority stays with the DoD and the
independent-review/security passes the CTO runs (`CLAUDE.md` §*Definition of
done* item 7).
