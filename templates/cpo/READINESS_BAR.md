# CPO — READINESS BAR (the portfolio-wide enterprise standard)

> The shared definition of what "a fully-formed enterprise product" means. Authored
> **once**, in qofi-engineering, and applied to **every** product. This is the
> ruler; each product's facet docs hold that product's specific requirements; the
> CTO repos hold the as-built status measured against it.

---

## How this is used

- This bar is the **baseline requirement** every product inherits. A product's
  facet docs (`operability.md`, `reliability.md`, `quality-bar.md`, `security.md`)
  hold the shared bar **plus** any product-specific requirements above it.
- You **audit** each product against this bar by asking its CTO to investigate and
  report (`SURFACING.md` §gap analysis), comparing the report to the bar, and
  surfacing gaps. *"Your report shows no rollback path; the bar requires one."*
- You **do not store status.** The bar is the requirement; the CTO report is the
  current state. You hold the should-be.
- **Change the bar here → every product is re-gradeable against the new bar.** That
  is the leverage of a central standard across tens of products.

## The bar

A product is **enterprise-ready** only when each of the following has a real,
reported answer — *"we haven't addressed that"* is a gap, not an N/A. N/A must be
justified per product.

**Operability** — it can be run in production by someone who isn't its author:
- Monitoring of the things that matter; alerting on the things that page.
- Deploy and **rollback** paths that are exercised, not theoretical.
- Logs sufficient to diagnose a failure at 3am.
- A runbook for the known failure modes.

**Reliability / safe-fail** — it fails without making things worse:
- Known failure modes enumerated; each has a defined behavior (degrade, not
  collapse).
- No silent data loss; integrity preserved across failures.
- Idempotency / safe-retry where operations can be repeated.
- A recovery path from its plausible bad states.

**Quality bar** — it is proven, not asserted:
- A **live test suite** that runs and gates changes.
- Coverage of the core flows and the failure paths, not just the happy path.
- A clear definition of "done" that includes the non-functional surround, not just
  the feature working once.

**Security** — its blast radius is bounded:
- Authn/authz appropriate to the data it touches.
- Secrets handled correctly (never in code/history/logs).
- Data protected in transit and at rest as the data class requires.
- The damage from a compromise is understood and contained.

## The CPO's stance

The CTO's instinct is to ship the feature. **Your job is to hold the line that a
feature is not done until it meets this bar** — and to make that argument in
product terms the operator cares about, not as engineering pedantry: *"shipping
this without a rollback path means a bad deploy takes the product down with no way
back — that's a product risk, not just an eng nicety."* The bar is how you force
robustness without owning the implementation.
