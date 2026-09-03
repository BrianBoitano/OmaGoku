#!/usr/bin/env python3
"""Draw the Dragon Ball decor grids into tools/sprites/.

The pet sprites are hand-authored at 16x16, where a human placing single pixels beats
anything generated. Decor is different: it is bigger, it is made of circles, arcs and
rings, and a hand-typed 32x32 or 96x48 ASCII grid is mostly transcription errors. So the
decor grids are DRAWN here and the .txt output is committed alongside the hand-authored
pet grids -- gen-sprites.py still treats them identically.

Run:  python3 plugin/tools/gen-decor.py && python3 plugin/tools/gen-sprites.py
"""
import math, pathlib

OUT = pathlib.Path(__file__).resolve().parent / "sprites"


class Grid:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [["." for _ in range(w)] for _ in range(h)]

    def set(self, x, y, ch):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[int(y)][int(x)] = ch

    def disc(self, cx, cy, r, ch, rx=None):
        rx = rx if rx is not None else r
        for y in range(self.h):
            for x in range(self.w):
                if ((x - cx) / rx) ** 2 + ((y - cy) / r) ** 2 <= 1.0:
                    self.set(x, y, ch)

    def ring(self, cx, cy, r, ch, thick=1.0, rx=None):
        rx = rx if rx is not None else r
        for y in range(self.h):
            for x in range(self.w):
                d = math.hypot((x - cx) / rx, (y - cy) / r)
                if 1.0 - thick / r <= d <= 1.0:
                    self.set(x, y, ch)

    def rect(self, x0, y0, x1, y1, ch):
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                self.set(x, y, ch)

    def write(self, name):
        (OUT / f"{name}.txt").write_text("\n".join("".join(r) for r in self.px) + "\n")
        return name, self.w, self.h


made = []

# --- the full moon. Why the Great Ape happens, so it hangs over the pod. ----------------
g = Grid(32, 32)
g.disc(15.5, 15.5, 13, "M")
for cx, cy, r in ((11, 11, 3), (20, 14, 2.4), (14, 21, 2.0), (22, 22, 1.6)):
    g.disc(cx, cy, r, "D")
made.append(g.write("decor_moon"))

# --- the seven dragon balls, hung as a crib mobile ---------------------------------------
g = Grid(32, 32)
g.rect(2, 0, 29, 0, "T")                       # the bar it hangs from
STARS = ((0, 0),) * 7
for i in range(7):
    cx = 3 + i * 4.3
    drop = 5 + (3 if i % 2 else 0)
    g.rect(int(cx), 1, int(cx), drop - 2, "T")  # the string
    g.disc(cx, drop, 2.2, "O")
    g.set(cx, drop, "R")                        # its star
made.append(g.write("decor_dragonballs"))

# --- one four-star ball, the one the child keeps ------------------------------------------
g = Grid(16, 16)
g.disc(7.5, 8.5, 6, "O")
for x, y in ((5, 6), (10, 6), (5, 11), (10, 11)):
    g.set(x, y, "R")
made.append(g.write("decor_dragonball"))

# --- the Dragon Radar ---------------------------------------------------------------------
g = Grid(16, 16)
g.disc(7.5, 8, 6, "W")
g.disc(7.5, 8, 4.5, "K")
g.ring(7.5, 8, 4.5, "E", thick=1.2)             # the sweep rings
g.rect(7, 4, 8, 8, "E")
g.rect(2, 1, 13, 2, "W")                        # the lid hinge
made.append(g.write("decor_radar"))

# --- the weighted training boots ----------------------------------------------------------
g = Grid(16, 16)
for x0 in (1, 9):
    g.rect(x0, 4, x0 + 4, 12, "W")
    g.rect(x0, 12, x0 + 5, 14, "W")
    g.rect(x0, 6, x0 + 4, 7, "B")               # the strap
made.append(g.write("decor_boots"))

# --- the Tree of Might, in three states of care -------------------------------------------
for name, canopy, trunk, extra in (
        ("decor_tree_ace", "E", "T", 10),       # thriving
        ("decor_tree_ok", "E", "T", 7),         # getting by
        ("decor_tree_gremlin", "N", "D", 4)):   # bare and brown
    g = Grid(32, 32)
    g.rect(14, 16, 17, 31, trunk)
    g.disc(15.5, 12, extra, canopy, rx=extra + 3)
    g.disc(9, 17, extra * 0.55, canopy)
    g.disc(22, 17, extra * 0.55, canopy)
    made.append(g.write(name))

# --- the three rooms, as backdrops --------------------------------------------------------
# Kame House: the domed pink cottage on its island.
g = Grid(96, 48)
g.rect(0, 43, 95, 47, "T")                      # sand
g.disc(48, 30, 13, "R", rx=20)                  # the dome
g.rect(28, 30, 68, 43, "R")                     # the walls
g.rect(44, 34, 51, 43, "W")                     # the door
for x in (34, 60):
    g.rect(x, 33, x + 5, 38, "L")               # windows (L, not C: see palette)
g.rect(20, 36, 22, 43, "T"); g.disc(21, 33, 5, "E", rx=8)     # a palm
g.rect(74, 36, 76, 43, "T"); g.disc(75, 33, 5, "E", rx=8)
made.append(g.write("decor_kame"))

# Korin's Tower: the impossibly thin one, seen from below.
g = Grid(96, 48)
g.rect(0, 45, 95, 47, "T")
g.rect(45, 8, 50, 47, "W")                      # the shaft
g.disc(47.5, 8, 6, "W", rx=17)                  # the platform
g.disc(47.5, 4, 4, "T", rx=9)                   # the hut
for y in (18, 28, 38):
    g.rect(43, y, 52, y + 1, "T")               # the bands
made.append(g.write("decor_korin"))

# King Kai's planet: a very small world with one road and one tree.
g = Grid(96, 48)
g.disc(48, 40, 22, "E", rx=30)
g.ring(48, 40, 22, "T", thick=3, rx=30)         # the road around it
g.rect(46, 18, 49, 26, "T")
g.disc(47.5, 14, 6, "E", rx=9)                  # the tree
g.rect(62, 30, 70, 34, "W")                     # the little house
g.rect(64, 26, 68, 30, "R")
made.append(g.write("decor_kingkai"))

# --- Vegeta's line -----------------------------------------------------------------------
g = Grid(96, 48)                                  # gravity chamber: a domed sphere, lit
g.disc(48, 30, 20, "W", rx=26)
g.disc(48, 30, 16, "K", rx=21)
g.ring(48, 30, 16, "R", thick=2, rx=21)
g.rect(0, 44, 95, 47, "T")
made.append(g.write("decor_gravity"))

g = Grid(96, 48)                                  # Capsule Corp: the dome and the tower
g.rect(0, 44, 95, 47, "T")
g.disc(40, 34, 14, "W", rx=20)
g.rect(64, 16, 74, 44, "W")
g.rect(66, 20, 72, 24, "L")
made.append(g.write("decor_capsule"))

g = Grid(96, 48)                                  # West City: a skyline
g.rect(0, 44, 95, 47, "T")
for x0, top in ((6, 22), (20, 14), (34, 28), (48, 10), (62, 24), (76, 18)):
    g.rect(x0, top, x0 + 10, 44, "W")
    for y in range(top + 3, 43, 5):
        g.rect(x0 + 2, y, x0 + 8, y + 1, "L")
made.append(g.write("decor_westcity"))

# --- Piccolo's line ----------------------------------------------------------------------
g = Grid(96, 48)                                  # Kami's Lookout: the disc on its spire
g.disc(48, 20, 7, "W", rx=30)
g.disc(48, 14, 5, "T", rx=8)
g.rect(45, 26, 50, 47, "W")
made.append(g.write("decor_lookout"))

g = Grid(96, 48)                                  # Time Chamber: a doorway in white void
g.rect(0, 0, 95, 47, "W")
g.rect(38, 18, 57, 47, "T")
g.disc(47.5, 18, 9, "T", rx=10)
g.rect(43, 26, 52, 47, "K")
made.append(g.write("decor_timechamber"))

g = Grid(96, 48)                                  # a waterfall
g.rect(0, 42, 95, 47, "L")
g.rect(30, 0, 46, 42, "L")
g.rect(34, 0, 42, 42, "L")
g.rect(10, 0, 28, 47, "T")
g.rect(48, 0, 70, 47, "T")
made.append(g.write("decor_waterfall"))

# --- Krillin's line ----------------------------------------------------------------------
g = Grid(96, 48)                                  # Satan City: a statue on a plaza
g.rect(0, 40, 95, 47, "W")
g.rect(44, 14, 51, 40, "T")
g.disc(47.5, 10, 5, "S", rx=6)
g.rect(30, 36, 65, 40, "T")
made.append(g.write("decor_satancity"))

# --- Frieza's line -----------------------------------------------------------------------
g = Grid(96, 48)                                  # Frieza's ship: the saucer
g.disc(48, 30, 10, "W", rx=34)
g.disc(48, 22, 8, "L", rx=12)
g.ring(48, 30, 10, "R", thick=2, rx=34)
made.append(g.write("decor_ship"))

g = Grid(96, 48)                                  # Namek: green sky, blue grass, spires
g.rect(0, 0, 95, 47, "E")
g.rect(0, 38, 95, 47, "L")
for x0 in (14, 40, 68):
    g.rect(x0, 16, x0 + 6, 38, "T")
    g.disc(x0 + 3, 14, 5, "E", rx=7)
made.append(g.write("decor_namek"))

g = Grid(96, 48)                                  # Hell: spikes and a red sky
g.rect(0, 0, 95, 47, "R")
g.rect(0, 40, 95, 47, "D")
for x0 in range(4, 92, 12):
    for y in range(0, 8):
        g.rect(x0 + y, 40 - y * 4, x0 + 8 - y, 40 - y * 4, "K")
made.append(g.write("decor_hell"))

# --- Shenron, the flagship. A large overlay, not a room: mostly transparent. -------------
#
# A full serpentine body does not read at 96x48 with one green -- tried and rejected. The
# iconic shot is the HEAD looming anyway, so this is head and neck rising out of the bottom
# edge, which gives the silhouette enough pixels to be a dragon rather than a blob.
g = Grid(96, 48)

# The neck, rising from the bottom-left corner and thickening toward the head.
NECK = []
for i in range(30):
    t = i / 29.0
    nx = 12 + 30 * t
    ny = 47 - 22 * t
    NECK.append((nx, ny, 3.0 + 3.0 * t))
for nx, ny, r in NECK:
    g.disc(nx, ny, r + 1, "K")
for nx, ny, r in NECK:
    g.disc(nx, ny, r, "E")

# The head: long and low, snout to the right, jaw slightly open.
g.disc(52, 22, 9, "K", rx=13)
g.disc(52, 22, 8, "E", rx=12)
g.rect(62, 17, 85, 27, "K")                 # the muzzle, outlined
g.rect(63, 18, 84, 26, "E")                 # kept green inside, or it reads as a black slab
g.rect(66, 22, 85, 22, "K")                 # the mouth: ONE row, not a slab
for tx in range(68, 84, 4):                 # teeth above and below the line
    g.set(tx, 21, "W")
    g.set(tx + 2, 23, "W")

# Horns, swept back over the neck. Two, so it reads as a head from any distance.
for base, drop in ((48, 0), (43, 3)):
    for k in range(11):
        g.set(base - k, 13 + drop - k // 3, "W")
        g.set(base - k, 14 + drop - k // 3, "K")

# The eye. One red pixel block is what makes it Shenron rather than a lizard.
g.rect(60, 19, 62, 20, "R")
g.set(61, 19, "W")

# Whiskers trailing back off the snout.
for k in range(16):
    g.set(84 - k, 16 - k // 3, "W")
    g.set(84 - k, 29 + k // 4, "W")

made.append(g.write("decor_shenron"))

# --- the signature moves (Phase 1) -------------------------------------------------------
#
# Fifteen shapes, drawn ONCE each in the neutral "X" glyph and TINTED at render time from
# lines.js moveColor. gen-sprites.py applies a line palette only to PET grids, so a decor
# asset cannot be recoloured by the palette system the way a pet sprite can.
#
# The consequence is deliberate and worth knowing: the renderer uses colorization 1, which
# flattens every non-transparent pixel to one colour, so these are SILHOUETTES. Shape has to
# carry the whole read -- no highlights, no core-and-halo. Fifteen flat shapes in five
# colours is the trade that kept this at fifteen grids instead of seventy-five.

def beam(w, h, head="round"):
    g = Grid(w, h)
    cy = (h - 1) / 2.0
    g.rect(0, cy - h / 4, w - 6, cy + h / 4, "X")      # the shaft
    if head == "round":
        g.disc(w - 6, cy, h / 2.0, "X")
    elif head == "jagged":
        for k in range(6):
            g.rect(w - 6 + k, cy - (h / 2.0) + k * 0.6, w - 6 + k, cy + (h / 2.0) - k * 0.6, "X")
    elif head == "point":
        for k in range(5):
            g.set(w - 5 + k, cy, "X")
    return g

made.append(beam(32, 8, "round").write("decor_move_kamehameha"))
made.append(beam(32, 8, "jagged").write("decor_move_galick_gun"))
made.append(beam(32, 16, "round").write("decor_move_final_flash"))
made.append(beam(32, 4, "point").write("decor_move_death_beam"))

# Special Beam Cannon: two strands winding round the shaft, which is the whole point of it.
g = Grid(32, 8)
g.rect(0, 3, 27, 4, "X")
for x in range(32):
    t = x / 4.0
    g.set(x, 3.5 + 2.6 * math.sin(t), "X")
    g.set(x, 3.5 - 2.6 * math.sin(t), "X")
made.append(g.write("decor_move_special_beam"))

def orb(size, ring_too=False, tail=False):
    g = Grid(size, size)
    c = (size - 1) / 2.0
    g.disc(c, c, size * 0.36, "X")
    if ring_too:
        g.ring(c, c, size * 0.47, "X", thick=1.4)
    if tail:
        g.rect(0, c - 0.5, c - size * 0.3, c + 0.5, "X")
    return g

made.append(orb(24, ring_too=True).write("decor_move_spirit_bomb"))
made.append(orb(20).write("decor_move_big_bang"))
made.append(orb(20, ring_too=True).write("decor_move_light_grenade"))
made.append(orb(20, tail=True).write("decor_move_death_ball"))
made.append(orb(32, ring_too=True).write("decor_move_supernova"))

# Hellzone Grenade and Scattering Bullet are ONE piece each, drawn small; the roam surface
# repeats them (5 and 8) along an arc rather than baking a formation into a sprite.
made.append(orb(8).write("decor_move_hellzone"))
made.append(orb(6).write("decor_move_scattering"))

# The Destructo Disc: a ring and nothing else, so the hole reads at any size.
g = Grid(20, 20)
g.ring(9.5, 9.5, 9, "X", thick=2.2)
made.append(g.write("decor_move_destructo_disc"))

# Solar Flare: a starburst, stationary, and the one move reduced motion substitutes away.
g = Grid(32, 32)
g.disc(15.5, 15.5, 5, "X")
for k in range(16):
    a = k * math.pi / 8
    for r in range(5, 16):
        g.set(15.5 + r * math.cos(a), 15.5 + r * math.sin(a), "X")
made.append(g.write("decor_move_solar_flare"))

# Kaioken: an aura that sits ON the pet and swells, so it is a ragged ring, not a disc --
# a filled one would hide the fighter inside it.
g = Grid(32, 32)
g.ring(15.5, 15.5, 15, "X", thick=3.0)
for k in range(24):
    a = k * math.pi / 12
    for r in range(12, 16 + (3 if k % 2 else 0)):
        g.set(15.5 + r * math.cos(a), 15.5 + r * math.sin(a), "X")
made.append(g.write("decor_move_kaioken"))

# --- the level trophies ------------------------------------------------------------------
#
# 16x16, and drawn in the real palette rather than tinted: they are furniture, not effects.
# The obvious candidates -- korin, kame, lookout, timechamber -- are 96x48 room BACKDROPS,
# and at the room delegate's px scaling four of those together would be scenery.

g = Grid(16, 16)                                   # Korin Tower: a spire with a cap
g.rect(7, 2, 8, 14, "T")
g.disc(7.5, 3, 3.5, "W", rx=4.5)
g.rect(5, 14, 10, 15, "T")
made.append(g.write("decor_trophy_korin"))

g = Grid(16, 16)                                   # Kame House: the little red-roofed hut
g.rect(3, 7, 12, 14, "W")
for k in range(6):
    g.rect(3 + k, 6 - k // 2, 12 - k, 6 - k // 2, "R")
g.rect(7, 10, 9, 14, "T")
g.rect(4, 9, 5, 10, "L")
made.append(g.write("decor_trophy_kame"))

g = Grid(16, 16)                                   # The Lookout: a disc on a slim column
g.disc(7.5, 5, 3, "W", rx=7)
g.rect(7, 8, 8, 15, "T")
g.disc(7.5, 3, 1.6, "W")
made.append(g.write("decor_trophy_lookout"))

g = Grid(16, 16)                                   # The Time Chamber: an hourglass
g.rect(3, 1, 12, 2, "T")
g.rect(3, 13, 12, 14, "T")
for k in range(5):
    g.rect(4 + k, 3 + k, 11 - k, 3 + k, "M")
for k in range(5):
    g.rect(8 - k, 8 + k, 7 + k, 8 + k, "M")
made.append(g.write("decor_trophy_chamber"))

lines = "".join(f"{n}\t{w}\t{h}\tdecor\n" for n, w, h in sorted(made))
print(f"drew {len(made)} decor grids")
print("MANIFEST lines:")
print(lines, end="")
