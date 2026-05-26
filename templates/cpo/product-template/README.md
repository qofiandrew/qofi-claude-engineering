# Product facet template

This directory is the **schema** for a single product's specs. It is instantiated
once per product in the CPO's (operator-owned) product-vision repo, e.g.
`products/product-7/…`, and populated by the operator talking to the CPO — never
hand-authored as doctrine.

**The schema is doctrine.** These files, and the definition at the top of each,
are the routing contract that retrieval depends on (`MEMORY.md` §retrieval). The
CPO files context *into* these facets and **never invents new files, facets, or
categories.** Add a facet only by changing this template in qofi-engineering.

Each facet holds the product **should-be** (requirements/vision), not the as-built
(that lives in the CTO repo). Each file header declares:

- **DEFINITION** — what belongs in this file.
- **ROUTES HERE** — the kind of operator input that gets filed here.
- **GREP FOR** — what a reader looks here to answer.
- **WRITE CLASS** — `auto` (routine capture) or `gated` (operator ratifies before
  the write lands; see `MEMORY.md` §write protocol).

Living facet docs are **rewritten in place and kept lean** ("sharpen the knife").
`decisions/` is append-only but bounded.
