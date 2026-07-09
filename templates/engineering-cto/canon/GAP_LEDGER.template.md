# GAP_LEDGER — root roll-up of ADR-required / conflict gaps

Every module `OPEN_GAPS.md` entry tagged `[adr-required]` (or classified
*conflict*) MUST have a row here; the `canon-check` gate enforces it. This is
the queue of drift that must route **upstream** to the canon/spec repo — a
gap here is closed by a canon patch (per the canon repo's propagation
process), never by silently adjusting the implementation to taste.

| Gap id | Module | Class | Summary | Upstream status |
|--------|--------|-------|---------|-----------------|
| GAP-`<module>`-`<NNN>` | `<module>` | adr-required / conflict | `<one line>` | open / escalated / canon-patched / closed |
