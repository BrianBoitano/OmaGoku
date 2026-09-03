#!/usr/bin/env python3
"""Extract character line ids from plugin/lines.js.

lines.js is the roster the running plugin actually uses, so it is the source of
truth. A second Python copy of the roster would drift -- this module keeps them
in sync by reading the ORDER array from lines.js at build time.
"""
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
LINES_JS = HERE.parent / "lines.js"


def line_ids():
    """Extract the roster from plugin/lines.js: var ORDER = [...]."""
    if not LINES_JS.exists():
        raise SystemExit(f"{LINES_JS}: not found")

    content = LINES_JS.read_text()

    # Strict regex: var ORDER = ["id", "id", ...] as a single line or multi-line.
    # Capture the array contents.
    match = re.search(r'var\s+ORDER\s*=\s*\[(.*?)\]', content, re.DOTALL)
    if not match:
        raise SystemExit(
            f"{LINES_JS}: cannot find 'var ORDER = [...]' literal. "
            "The roster must be defined as a JavaScript array for the build to see it."
        )

    array_content = match.group(1)

    # Extract quoted strings (single or double quotes).
    ids = re.findall(r'["\']([a-z]+)["\']', array_content)

    if not ids:
        raise SystemExit(
            f"{LINES_JS}: ORDER array is empty or unparseable. "
            "The roster must list at least one character line."
        )

    return tuple(ids)


def line_blocks():
    """Each roster entry's source text, keyed by line id.

    Every tool that needed a field out of lines.js grew its own regex anchored on whatever
    happened to be the FIRST key in the entry, so adding `rungColors` above `moveColor`
    silently broke two of them at once -- they reported every line as missing a colour it
    plainly had. Parsing the block once, here, is the same reasoning that put the roster in
    this module rather than in each caller.
    """
    content = LINES_JS.read_text()
    # Bounded to the LINES literal. SPEECH is keyed by the same five ids at the same indent,
    # so an unbounded scan finds each line TWICE and the speech block -- which carries no
    # colours -- wins.
    begin = content.index("var LINES = {")
    end = content.index("var ORDER", begin)
    content = content[begin:end]
    out = {}
    starts = [(m.group(1), m.end()) for m in re.finditer(r'^    (\w+): \{$', content, re.M)]
    for i, (name, begin) in enumerate(starts):
        end = starts[i + 1][1] if i + 1 < len(starts) else len(content)
        block = content[begin:end]
        stop = re.search(r'^    \},?$', block, re.M)
        out[name] = block[:stop.start()] if stop else block
    return out


def move_colors():
    """line id -> the #RRGGBB its signature moves are tinted at."""
    out = {}
    for name, block in line_blocks().items():
        m = re.search(r'moveColor:\s*"(#[0-9A-Fa-f]{6})"', block)
        if m:
            out[name] = m.group(1)
    return out


def rung_colors():
    """line id -> {glyph: 'RRGGBB'} for Y/C/G, uppercased, as lines.js hands the RUNTIME."""
    out = {}
    for name, block in line_blocks().items():
        m = re.search(r'rungColors:\s*\{([^}]*)\}', block)
        if not m:
            continue
        out[name] = {g: h.upper()
                     for g, h in re.findall(r'(\w)\s*:\s*"#([0-9A-Fa-f]{6})"', m.group(1))}
    return out


if __name__ == "__main__":
    ids = line_ids()
    print(f"roster: {', '.join(ids)}")

    # Self-check: must have exactly 5 lines, all lowercase.
    if len(ids) != 5:
        raise SystemExit(f"roster has {len(ids)} lines, expected 5")
    for line_id in ids:
        if not line_id.isalpha() or line_id != line_id.lower():
            raise SystemExit(
                f"roster id {line_id!r} is invalid (must be lowercase a-z only)"
            )
