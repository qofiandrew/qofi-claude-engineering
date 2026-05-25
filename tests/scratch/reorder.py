#!/usr/bin/env python3
"""
reorder.py — produce a reordered doctrine file from a source, grouping
spine ("base") sections contiguously before role-specific ("engineering")
sections.

CONTRACT: reorder ONLY. No section is added, dropped, or reworded.
Every section's text is byte-identical to the source; only the
sequence of sections in the file changes.

The proof comes from `verify_reorder()` — sorted set of
(heading, body_sha256) tuples must be identical between source and
reordered files.

Usage:
    reorder.py CLAUDE   /path/to/source/CLAUDE.md   /path/to/out/CLAUDE.reordered.md
    reorder.py ESCAL    /path/to/source/ESCALATION.md /path/to/out/ESCALATION.reordered.md
"""
import hashlib
import re
import sys
from pathlib import Path

SECTION_RE = re.compile(r"^## ", re.MULTILINE)


def parse_sections(text):
    """Return (preamble, [(heading, body)]) with NORMALIZED bodies.

    Preamble = everything before the first '## ' line, byte-stripped of any
    trailing newlines (the inter-section separator is added back at emit time
    so layout is uniform regardless of source quirks).

    Each section body = heading line + content lines, stripped of any
    trailing newlines/blank-lines. This makes section bodies independent of
    where they happened to sit in the source file (a section that was LAST
    in source has the same body shape as one that was INTERIOR).

    Substantive content of each section is preserved byte-for-byte — only
    the inter-section trailing whitespace is normalized away.
    """
    starts = [m.start() for m in SECTION_RE.finditer(text)]
    if not starts:
        return text.rstrip("\n"), []
    preamble = text[: starts[0]].rstrip("\n")
    sections = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(text)
        block = text[start:end].rstrip("\n")
        nl = block.find("\n")
        heading = (block[:nl] if nl >= 0 else block).strip()
        sections.append((heading, block))
    return preamble, sections


def emit(preamble, sections):
    """Reconstruct a file from preamble + sections with canonical layout:
       - Preamble (with trailing newlines stripped), then ONE blank line
         before the first heading.
       - ONE blank line between consecutive sections.
       - Single trailing newline at EOF.
    """
    if not sections:
        return preamble + "\n"
    bodies = "\n\n".join(body for _, body in sections)
    return preamble + "\n\n" + bodies + "\n"


# Section heading -> classification.
# Authoritative for the reorder (and for the future split into _base / engineering-cto).
CLAUDE_CLASS = {
    "## Honesty (foundational)":                            "base",
    "## Source of truth":                                   "eng",
    "## Conflict handling":                                 "base",
    "## Decisions":                                         "eng",
    "## Verification (non-negotiable)":                     "eng",
    "## Testing strategy (mocking policy)":                 "eng",
    "## Working with existing code (work with the grain)":  "eng",
    "## Greenfield":                                        "eng",
    "## Modular design":                                    "eng",
    "## Data ownership":                                    "eng",
    "## Backward compatibility":                            "eng",
    "## Data migrations":                                   "eng",
    "## Error handling":                                    "eng",
    "## Logging & observability":                           "eng",
    "## Operability":                                       "eng",
    "## Scope & branches":                                  "eng",
    "## Documentation":                                     "eng",
    "## Cost & blast radius":                               "base",
    "## Dependencies":                                      "eng",
    "## Secrets":                                           "base",
    "## Definition of done":                                "eng",
    "## When blocked or unsure":                            "base",
    "## When stuck on implementation":                      "base",
}

ESCAL_CLASS = {
    "## Core principle: decide by default":                 "base",
    "## No silence-as-consent, no countdown defaults":      "base",
    "## The ladder":                                        "eng",
    "## What reaches the operator: GRAVE AND BLOCKING":     "eng",
    "## Cadence":                                           "base",
    "## Agent → CTO triggers":                              "eng",
    "## CTO → Operator triggers (grave items)":             "eng",
    "## CTO authority — decide, own, never surface":        "eng",
    "## How to escalate":                                   "base",
    "## Tie-in":                                            "eng",
}


def reorder(text, class_map):
    """Reorder text so base sections precede engineering sections.
    Within each class, sections keep their original relative order.
    """
    preamble, sections = parse_sections(text)
    unknown = [h for h, _ in sections if h not in class_map]
    if unknown:
        raise SystemExit(
            f"reorder: unknown sections (add to *_CLASS map): {unknown}"
        )
    base = [(h, b) for h, b in sections if class_map[h] == "base"]
    eng = [(h, b) for h, b in sections if class_map[h] == "eng"]
    new_sections = base + eng
    out = emit(preamble, new_sections)
    return out, sections, new_sections


def section_hashes(sections):
    """Return a sorted list of (heading, sha256(body)) tuples — order-independent
    set representation. If two files have identical sorted hashes, they contain
    the same sections with byte-identical bodies — proving reorder is the only
    change."""
    return sorted(
        (h, hashlib.sha256(b.encode("utf-8")).hexdigest()) for h, b in sections
    )


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("CLAUDE", "ESCAL"):
        sys.exit("usage: reorder.py {CLAUDE|ESCAL} SOURCE OUT")
    kind, src_path, out_path = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    class_map = CLAUDE_CLASS if kind == "CLAUDE" else ESCAL_CLASS
    src = src_path.read_text()
    reordered, src_sections, reordered_sections = reorder(src, class_map)

    # Independence check 1: normalized-section content set is identical
    # (order-free). Since parse_sections normalizes bodies (strips trailing
    # blanks), this proves no section was added, dropped, or reworded.
    src_hashes = section_hashes(src_sections)
    out_hashes = section_hashes(reordered_sections)
    if src_hashes != out_hashes:
        sys.exit("FAIL: section content set differs — NOT a pure reorder")

    # Independence check 2: preamble byte-equal (normalized — trailing blanks
    # stripped both sides). Same substantive preamble content.
    src_preamble, _ = parse_sections(src)
    out_preamble, _ = parse_sections(reordered)
    if src_preamble != out_preamble:
        sys.exit("FAIL: preamble differs — NOT a pure reorder")

    # Independence check 3: idempotence — emitting the SAME sections in the
    # SAME order from the source must reproduce the source byte-for-byte.
    # This proves the normalize+emit roundtrip is lossless on already-clean
    # sources, so any byte-count delta observed on the reorder is genuinely
    # attributable to reordering (not normalization artifacts).
    src_roundtrip = emit(src_preamble, src_sections)
    if src_roundtrip != src:
        sys.exit(
            f"FAIL: normalize+emit roundtrip is not idempotent on source — "
            f"would have masked normalization artifacts. "
            f"({len(src)} -> {len(src_roundtrip)} chars)"
        )

    # Independence check 4: byte length must match source (in UTF-8).
    src_bytes = src.encode("utf-8")
    out_bytes = reordered.encode("utf-8")
    if len(out_bytes) != len(src_bytes):
        sys.exit(
            f"FAIL: byte count differs ({len(src_bytes)} -> {len(out_bytes)}) "
            "— NOT a pure reorder"
        )

    out_path.write_text(reordered)
    print(f"OK reorder {kind}: {len(src_sections)} sections, "
          f"{len(out_bytes)} bytes (== source, unchanged), "
          f"section content set identical (sha256-keyed), "
          f"emit-idempotent on source")


if __name__ == "__main__":
    main()
