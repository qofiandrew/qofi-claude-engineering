# OPEN_GAPS — `<module>`

Known drift and gaps for this module, classified per CLAUDE.md §*External
canon sync* (drift rule). Classes: editorial · propagation-only ·
schema-detail · implementation-choice · semantic `[adr-required]` · conflict
`[adr-required]`. **Every `[adr-required]` entry MUST also have a row in root
`docs/GAP_LEDGER.md`** — the `canon-check` gate enforces this.

Format:

```
- GAP-<module>-<NNN> (<class>): <one-line summary> [adr-required]?
```
