# _base/ — universal doctrine shared across swarm archetypes

Fragments in this directory are role-AGNOSTIC: the foundational rules
(`§Honesty`, `§Conflict handling`, `§Cost & blast radius`, `§Secrets`,
`§When blocked or unsure`, `§When stuck on implementation`, the universal
escalation contract) that apply to ANY archetype — engineering-cto today;
cpo / company-brain when those overlays land.

Each archetype's overlay (`engineering-cto/`, future `cpo/`,
`company-brain/`) supplies its own preamble + role-specific sections,
and the per-archetype `manifest.tsv` composes the final stamped
artifact from `[overlay-preamble, _base/X, overlay-body]`.

## Compose mechanism

The `compose` manifest behavior takes a `+`-joined list of source paths
and concatenates them with **literal `cat`** to produce the stamped
artifact. No separator is injected.

```
compose | engineering-cto/CLAUDE.preamble.md+_base/CLAUDE.md+engineering-cto/CLAUDE.md | CLAUDE.md
```

### Optional per-profile overlay (engineering-cto, ADR-0013)

The composed `CLAUDE.md` gains **one** dynamically-sourced final fragment when
the repo carries a `.claude/swarm-profile` marker: `manifest_apply_compose`
(in `bin/swarm-lib.sh`) appends
`engineering-cto/profiles/<profile>/CLAUDE.md` to the `+`-joined list above
when that fragment exists and the resolved type is `engineering-cto`. This is
the only compose source NOT declared on the manifest line — the manifest stays
profile-agnostic. An absent marker, or a label-only profile with no fragment
(v1 `backend`), appends nothing, so a markerless swarm composes
byte-identically to a pre-profile swarm. Because the profile fragment is the
new *final* source, the previously-final `engineering-cto/CLAUDE.md` is now a
non-final source and must obey the trailing-newline invariant below (it does).

### Trailing-newline invariant (load-bearing)

For literal `cat` to produce well-formed markdown across the seam, each
non-final source MUST end with at least one `\n` (typically `\n\n`, where
the second newline is the blank-line separator before the next fragment's
heading). The final source ends with a single `\n` (file EOF convention).

`_compose_to_tmp` in `bin/swarm-lib.sh` asserts this at load time and
fails loudly if any non-final source lacks a trailing newline — a fragment
accidentally stripped of trailing blank-line whitespace (e.g. by an editor
that "cleans up" the file) would otherwise silently run two sections
together at composition time.

### Round-trip test

`tests/test-doctrine-compose.sh` proves byte-identity:

  composed(engineering-cto fragments) ≡ tests/fixtures/CLAUDE.engineering-cto.expected.md

so editing any fragment is provably safe — the composed output is what
it claims to be.
