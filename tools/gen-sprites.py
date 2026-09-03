#!/usr/bin/env python3
"""Turn the text grids in tools/sprites/ into PNGs in assets/sprites/.

Replaces upstream's gen-sprites.sh. Two changes, both load-bearing:

  1. COLOUR. Upstream forced every pixel to #FFFFFF because the renderer threw
     colour away anyway (MultiEffect colorization: 1). Omagoku renders the pet
     with colorization: 0, so a grid glyph now selects a palette entry.
     'X' still means white, so upstream's own grids keep generating unchanged
     and art can be replaced one sprite at a time.

  2. NO IMAGEMAGICK. Pure stdlib (zlib + struct). One less thing to install on a
     machine that has to be able to rebuild this.

The grid is validated: rectangular, and every glyph known. A typo fails the build
instead of punching a transparent hole in a sprite nobody notices for a week.

Every output is reconciled against assets/MANIFEST.tsv. Missing sprites MUST fail
loudly, because PetSprite's fallback chain is specifically designed to hide them.
"""
import colorsys, math, pathlib, re, struct, sys, zlib
from roster import line_ids, rung_colors

HERE = pathlib.Path(__file__).resolve().parent
GRIDS = HERE / "sprites"
OUT = HERE.parent / "assets" / "sprites"
MANIFEST = HERE.parent / "assets" / "MANIFEST.tsv"

PALETTE = {
    ".": None,                  # transparent
    "X": (0xFF, 0xFF, 0xFF),    # upstream's 1-bit white; keeps old grids working
    "K": (0x1A, 0x1A, 0x22),    # hair, near-black
    "S": (0xF2, 0xC4, 0x8A),    # skin
    "O": (0xF0, 0x7C, 0x1E),    # orange gi
    "B": (0x1F, 0x4F, 0xA8),    # blue undershirt, belt, wristbands
    "W": (0xF5, 0xF5, 0xF0),    # boots, gi trim
    "R": (0xC8, 0x32, 0x2A),    # red
    "N": (0x6B, 0x3F, 0x1D),    # tail, brown fur
    "Y": (0xFF, 0xD2, 0x4A),    # super saiyan hair
    "C": (0x66, 0xE0, 0xFF),    # super saiyan blue hair
    "G": (0xC8, 0xC8, 0xD4),    # ultra instinct hair, silver
    "P": (0x8B, 0x5A, 0x2B),    # oozaru fur, mid brown
    "D": (0x4A, 0x2C, 0x14),    # oozaru fur, shadow
    "M": (0xE8, 0xDD, 0xD0),    # bone / moon / halo
    "E": (0x4E, 0xA8, 0x4E),    # foliage, King Kai's planet
    "T": (0x8A, 0x6A, 0x3A),    # wood, tower stone, sand
    "L": (0x9E, 0xE8, 0xF2),    # lit glass: pod window, house windows.
                                # Deliberately NOT C -- Y/C/G are reserved for
                                # transformation hair so a colour check can
                                # tell a lit pod from a Super Saiyan Blue.
}

PALETTES = HERE / "palettes.tsv"
GOLDEN = HERE / "genetics-golden.tsv"

# --- genetics ---------------------------------------------------------------
#
# The drift is PRE-GENERATED VARIANT SETS, not a runtime palette swap: the plugin has never
# opened palettes.tsv, MultiEffect flattens a whole sprite rather than remapping a glyph,
# and a ShaderEffect LUT would need a precompiled .qsb, contradicting this file's founding
# "NO IMAGEMAGICK, pure stdlib".
#
# WHITELIST: O and N only. Never Y/C/G -- the only visual statement of the rung, and now the
# source of the aura -- never K/S, which are a different body part per line, and NEVER '.',
# a redefinable glyph where one bad delta paints every transparent pixel opaque and turns
# the pet into a solid block.
DRIFT_GLYPHS = ("O", "N")
FORBIDDEN_DRIFT = (".", "X", "K", "S", "B", "W", "R", "Y", "C", "G", "P", "D", "M", "E",
                   "T", "L")

SAT = [0.55, 0.78, 1.00, 1.10, 1.22]
VAL = [0.78, 0.89, 1.00, 1.06, 1.12]
NEUTRAL_BUCKET = 2
BUCKETS = (0, 1, 2, 3, 4)
# Bucket 2 is the identity, so it reuses the CANONICAL filename and today's art stays
# byte-identical by being the same file rather than by a comparison that happened to pass.
VARIANT_BUCKETS = tuple(b for b in BUCKETS if b != NEUTRAL_BUCKET)
VARIANT_RE = re.compile(r"_g[0-9]+$")


def read_golden():
    """{source_hex: {bucket: result_hex}} from the blessed table."""
    if not GOLDEN.exists():
        raise SystemExit("genetics-golden.tsv is missing; run with --bless to write it")
    out = {}
    for n, line in enumerate(GOLDEN.read_text().splitlines(), 1):
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            raise SystemExit(f"genetics-golden.tsv:{n}: want source, bucket, result")
        out.setdefault(parts[0].upper(), {})[int(parts[1])] = parts[2].upper()
    return out


def drift_rgb(rgb, bucket):
    """The pinned transformation: hue untouched, saturation and value scaled, round-half-up,
    clamped. Bucket 2 is the identity and the build asserts it per source colour."""
    r, g, b = rgb
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    rr, gg, bb = colorsys.hsv_to_rgb(h, min(1.0, s * SAT[bucket]), min(1.0, v * VAL[bucket]))
    return tuple(max(0, min(255, math.floor(c * 255 + 0.5))) for c in (rr, gg, bb))


def hexof(rgb):
    return "%02X%02X%02X" % rgb


def drifted_palette(pal, bucket, golden, problems):
    """A copy of `pal` with only the whitelisted glyphs moved. Asserts the whitelist rather
    than trusting the caller, and asserts every result against the blessed table."""
    out = dict(pal)
    for glyph in DRIFT_GLYPHS:
        src = pal.get(glyph)
        if src is None:
            continue
        src_hex = hexof(src)
        want = golden.get(src_hex, {}).get(bucket)
        if want is None:
            problems.append(
                f"GENETICS: {src_hex} (glyph {glyph}) has no blessed row for bucket "
                f"{bucket} -- bless it and read the diff")
            continue
        got = drift_rgb(src, bucket)
        if hexof(got) != want:
            problems.append(
                f"GENETICS: {src_hex} bucket {bucket} computes #{hexof(got)} but the "
                f"blessed table says #{want}")
            continue
        out[glyph] = got
    # The whitelist is an assertion, not a convention: every other glyph must be untouched.
    for glyph in FORBIDDEN_DRIFT:
        if out.get(glyph) != pal.get(glyph):
            problems.append(f"GENETICS: bucket {bucket} moved {glyph}, which is not "
                            f"whitelisted -- O and N only")
    return out


def bless_golden(lines):
    """Rewrite the blessed table from the palettes in play. Explicit, never automatic."""
    seen = {}
    for name in sorted(lines):
        pal = dict(PALETTE)
        pal.update(lines[name])
        for glyph in DRIFT_GLYPHS:
            if pal.get(glyph) is not None:
                seen.setdefault(hexof(pal[glyph]), glyph)
    rows = ["# The genetics colour table. BLESSED, not derived at build time.",
            "# Regenerated only with `gen-sprites.py --bless`, whose diff a person reads.",
            "# A REGRESSION LOCK on the formula's output, not a proof that it is right --",
            "# the art gate is where that question is answerable.",
            "#",
            "# source\tbucket\tresult\tglyph"]
    for src in sorted(seen):
        rgb = tuple(int(src[i:i + 2], 16) for i in (0, 2, 4))
        for b in BUCKETS:
            rows.append(f"{src}\t{b}\t{hexof(drift_rgb(rgb, b))}\t"
                        f"{seen[src] if b == 0 else ''}")
    GOLDEN.write_text("\n".join(rows) + "\n")
    print(f"blessed {len(seen)} source colour(s) x {len(BUCKETS)} buckets -> {GOLDEN.name}")

# Reserved for transformation hair. A line that does not redefine all three inherits Goku's
# Super Saiyan gold, which silently renders every line's rung sprite identically.
RUNG_GLYPHS = ("Y", "C", "G")


def read_palettes():
    """{line: {glyph: (r, g, b)}} from palettes.tsv. Only redefined glyphs appear."""
    if not PALETTES.exists():
        raise SystemExit("palettes.tsv is missing; every pet sprite is per line now")
    out = {}
    for n, line in enumerate(PALETTES.read_text().splitlines(), 1):
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            raise SystemExit(f"palettes.tsv:{n}: want line, glyph, hex")
        name, glyph, hexval = parts[0], parts[1], parts[2]
        if glyph not in PALETTE:
            raise SystemExit(f"palettes.tsv:{n}: unknown glyph {glyph!r}")
        if len(hexval) != 6:
            raise SystemExit(f"palettes.tsv:{n}: want a 6-digit hex, got {hexval!r}")
        try:
            rgb = tuple(int(hexval[i:i + 2], 16) for i in (0, 2, 4))
        except ValueError:
            raise SystemExit(f"palettes.tsv:{n}: {hexval!r} is not hex")
        out.setdefault(name, {})[glyph] = rgb

    problems = []
    for name, glyphs in sorted(out.items()):
        missing = [g for g in RUNG_GLYPHS if g not in glyphs]
        if missing:
            problems.append(f"line {name} does not define {', '.join(missing)}")
    for name in line_ids():
        if name not in out:
            problems.append(f"line {name} is not defined")
    if problems:
        for p in problems:
            print("PALETTE: " + p, file=sys.stderr)
        raise SystemExit("every line must define its own Y, C and G rung colours")
    return out


def is_pet_grid(stem):
    """Pets are per line; decor and emotes are shared and keep their bare names."""
    return not stem.startswith("decor_") and not stem.startswith("emote_")


def encode(grid, palette):
    h, w = len(grid), len(grid[0])
    raw = bytearray()
    for row in grid:
        raw.append(0)
        for ch in row:
            c = palette[ch]
            raw += bytes(c + (255,)) if c else b"\0\0\0\0"

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b"")), w, h


def load(path):
    rows = [r.rstrip("\n") for r in path.read_text().splitlines()]
    rows = [r for r in rows if r.strip()]
    if not rows:
        raise SystemExit(f"{path.name}: empty grid")
    widths = {len(r) for r in rows}
    if len(widths) != 1:
        raise SystemExit(f"{path.name}: ragged grid, row widths {sorted(widths)}")
    unknown = {c for r in rows for c in r} - set(PALETTE)
    if unknown:
        raise SystemExit(f"{path.name}: unknown glyphs {sorted(unknown)}")
    return rows


def png_size(path):
    """Width/height straight out of the IHDR, so a committed PNG with no grid is still
    checked against the manifest rather than taken on trust."""
    d = path.read_bytes()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path.name}: not a PNG")
    return struct.unpack(">II", d[16:24])


def palette_of(grid):
    """The glyph set a grid actually uses, sorted. This is the manifest's `palette` column:
    it is what catches a sprite being silently repainted -- an adult_ace redrawn in Super
    Saiyan gold keeps its name and its dimensions, and only this column changes."""
    return "".join(sorted({c for row in grid for c in row}))


def read_manifest():
    if not MANIFEST.exists():
        return None
    want = {}
    for n, line in enumerate(MANIFEST.read_text().splitlines(), 1):
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 5:
            raise SystemExit(f"MANIFEST.tsv:{n}: expected 5 tab-separated columns "
                             f"(name, width, height, palette, feature), got {len(parts)}")
        name, w, h, palette, feature = parts
        want[name] = (int(w), int(h), palette, feature)
    return want


def check_rung_colors(lines):
    """`lines` is read_palettes()'s per-line glyph overrides."""
    declared = rung_colors()
    problems = []
    if not declared:
        return ["could not parse any rungColors out of lines.js -- the aura has no source"]
    for name in sorted(lines):
        if name not in declared:
            problems.append(f"lines.js declares no rungColors for {name}")
            continue
        for glyph in RUNG_GLYPHS:
            baked = lines[name].get(glyph, PALETTE[glyph])
            baked_hex = "%02X%02X%02X" % baked
            shown = declared[name].get(glyph)
            if shown is None:
                problems.append(f"lines.js {name} declares no {glyph}")
            elif shown != baked_hex:
                problems.append(
                    f"AURA/HAIR MISMATCH: {name} {glyph} is baked #{baked_hex} but lines.js "
                    f"shows #{shown} -- the glow would contradict the head")
    for name in sorted(declared):
        if name not in lines:
            problems.append(f"lines.js declares rungColors for unknown line {name}")
    return problems


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    lines = read_palettes()
    if "--bless" in sys.argv:
        bless_golden(lines)
        return 0
    golden = read_golden()
    built = {}
    problems_early = []
    expected = set()

    # The bucket token is a TRAILING filename segment, so any consumer can split it off
    # before parsing. That only works if no grid can already end in one.
    for txt in sorted(GRIDS.glob("*.txt")):
        if VARIANT_RE.search(txt.stem):
            problems_early.append(
                f"GRAMMAR: grid {txt.stem} ends in a variant token, which makes the "
                f"filename grammar ambiguous")

    # Saturation must ORDER across the buckets, or "drift" is a word for noise.
    for i in range(len(SAT) - 1):
        if not SAT[i] < SAT[i + 1] or not VAL[i] < VAL[i + 1]:
            problems_early.append("GENETICS: SAT/VAL are not monotonic across the buckets")

    for txt in sorted(GRIDS.glob("*.txt")):
        grid = load(txt)
        if not is_pet_grid(txt.stem):
            png, w, h = encode(grid, PALETTE)
            (OUT / f"{txt.stem}.png").write_bytes(png)
            built[txt.stem] = (w, h, palette_of(grid))
            continue

        for name in sorted(lines):
            # A per-line override grid REPLACES the recoloured base for that one sprite.
            # This is the head-swap mechanism: copy the grid, change rows 0-3.
            override = GRIDS / name / f"{txt.stem}.txt"
            g = load(override) if override.exists() else grid
            pal = dict(PALETTE)
            pal.update(lines[name])
            png, w, h = encode(g, pal)
            stem = f"{name}_{txt.stem}"
            (OUT / f"{stem}.png").write_bytes(png)
            built[stem] = (w, h, palette_of(g))
            expected.add(stem)

            # The four drifted buckets. Bucket 2 is not emitted: it is the identity and it
            # reuses this very file. A cell whose grid contains no whitelisted glyph still
            # gets its four variants -- byte-identical to the canonical -- so that
            # `variant exists iff canonical exists` holds and the runtime never takes a
            # fallback for a bucket that legitimately has no art.
            glyphs = palette_of(g)
            drifts = any(ch in glyphs for ch in DRIFT_GLYPHS)
            for b in VARIANT_BUCKETS:
                vpal = drifted_palette(pal, b, golden, problems_early)
                vpng, vw, vh = encode(g, vpal)
                vstem = f"{stem}_g{b}"
                (OUT / f"{vstem}.png").write_bytes(vpng)
                built[vstem] = (vw, vh, palette_of(g))
                expected.add(vstem)
                if not drifts and vpng != png:
                    problems_early.append(
                        f"GENETICS: {vstem} has no O or N yet differs from its canonical")

    colour_problems = check_rung_colors(lines) + problems_early

    # Derived from the grids and the roster, NOT from the output directory or the manifest:
    # regenerating the manifest from what happens to be on disk agrees with its own
    # omissions, so an entire missing bucket would pass unnoticed.
    for stem in sorted(expected):
        if stem not in built:
            colour_problems.append(f"GENETICS: {stem} was expected but never built")

    want = read_manifest()
    if want is None:
        print(f"built {len(built)} sprite(s); no MANIFEST.tsv yet")
        return 0

    problems = list(colour_problems)
    for name, (w, h, palette, feature) in sorted(want.items()):
        path = OUT / f"{name}.png"
        if name in built:
            gw, gh, gp = built[name]
            if (gw, gh) != (w, h):
                problems.append(
                    f"WRONG SIZE: {name} is {gw}x{gh}, manifest says {w}x{h}")
            if gp != palette:
                problems.append(
                    f"REPAINTED: {name} uses glyphs '{gp}', manifest says '{palette}'")
        elif path.exists():
            # Committed art with no grid (upstream's emotes). Taking it on trust is how a
            # replaced or truncated asset slips through, so the PNG itself is measured.
            pw, ph = png_size(path)
            if (pw, ph) != (w, h):
                problems.append(
                    f"WRONG SIZE: {name}.png is {pw}x{ph}, manifest says {w}x{h}")
            if palette != "png":
                problems.append(
                    f"{name} has no grid, so its palette column must be 'png', not "
                    f"'{palette}'")
        else:
            problems.append(f"MISSING: {name} ({feature}) has neither a grid nor a PNG")

    # Every PNG on disk must be declared -- not just the ones we generated this run.
    # Skipping committed art here is what let six emote assets sit outside the manifest.
    for path in sorted(OUT.glob("*.png")):
        if path.stem not in want:
            problems.append(f"UNDECLARED: {path.name} is not in MANIFEST.tsv")

    for p in problems:
        print(p, file=sys.stderr)
    print(f"built {len(built)} sprite(s); manifest declares {len(want)}; "
          f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
