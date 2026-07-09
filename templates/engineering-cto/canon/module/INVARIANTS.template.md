# INVARIANTS — `<module>`

Canon-derived invariants this module must hold. **Every entry MUST carry
either `tests:` (a real test path proving it) or `gap:` (an explicit GAP id
in `OPEN_GAPS.md`)** — the `canon-check` gate enforces this. An invariant
with neither is an unacknowledged coverage hole.

Format (one line per invariant; entries start at column 0 with `- INV`):

```
  - INV-<module>-<NNN>: <statement> | canon: <ref> | tests: `tests/<path>`
  - INV-<module>-<NNN>: <statement> | canon: <ref> | gap: GAP-<module>-<NNN>
```

(The examples above are indented so the gate doesn't read them as entries;
real entries are flush-left. `tests:` paths must exist; `gap:` ids must be
recorded in this pack's `OPEN_GAPS.md`.)
