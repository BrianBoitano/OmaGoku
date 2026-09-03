#!/usr/bin/env python3
"""Generate the three sound effects this plugin owns outright.

Everything else in sounds/ comes from freesound under Creative Commons and is credited in
CREDITS.md. Three of those clips were CC BY-NC, which cannot live inside an MIT-licensed
plugin: MIT grants commercial use and NonCommercial withholds it. Rather than trade one
attribution problem for another, these three are synthesised here -- pure stdlib, no
dependencies, reproducible, and ours to license.

They are deliberately simple square and sine shapes. The art is 16x16 pixels; the audio
should sound like it belongs to it.

    python3 tools/gen-sounds.py
"""
import math, pathlib, random, struct, wave

OUT = pathlib.Path(__file__).resolve().parent.parent / "sounds"
RATE = 44100


def write(name, samples, peak=0.5):
    """Normalise to `peak`, apply a short fade at both ends, write 16-bit mono."""
    top = max(abs(s) for s in samples) or 1.0
    scale = peak / top
    edge = int(RATE * 0.004)                      # 4 ms, enough to kill the click
    n = len(samples)
    frames = bytearray()
    for i, s in enumerate(samples):
        gain = 1.0
        if i < edge:
            gain = i / edge
        elif i > n - edge:
            gain = max(0.0, (n - i) / edge)
        v = int(max(-1.0, min(1.0, s * scale * gain)) * 32767)
        frames += struct.pack("<h", v)
    path = OUT / name
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))
    print(f"  {name}  {len(frames) // 2} frames, {path.stat().st_size // 1024} KiB")


def square(phase):
    return 1.0 if (phase % (2 * math.pi)) < math.pi else -1.0


def stun(duration=0.75):
    """Dizzy: a square tone sliding down while a vibrato wobbles it off its feet."""
    out, phase = [], 0.0
    n = int(RATE * duration)
    for i in range(n):
        t = i / RATE
        k = i / n
        base = 620 - 300 * k                       # falling over
        wobble = 55 * math.sin(2 * math.pi * 7.5 * t)
        phase += 2 * math.pi * (base + wobble) / RATE
        env = math.exp(-2.2 * k)
        out.append(square(phase) * env * 0.6)
    return out


def fall(duration=0.28):
    """Thud: a noise transient over a pitch drop that lands and stops."""
    out, phase = [], 0.0
    n = int(RATE * duration)
    rng = random.Random(20260902)                  # seeded: the file must be reproducible
    for i in range(n):
        k = i / n
        freq = 110 - 62 * k
        phase += 2 * math.pi * freq / RATE
        body = math.sin(phase) * math.exp(-7.0 * k)
        crack = rng.uniform(-1.0, 1.0) * math.exp(-55.0 * k) * 0.55
        out.append(body + crack)
    return out


def farewell_gremlin(duration=0.55):
    """The gremlin's goodbye: two cheeky blips and a bend on the way out."""
    out, phase = [], 0.0
    n = int(RATE * duration)
    for i in range(n):
        k = i / n
        if k < 0.28:
            freq = 520
            env = 1.0
        elif k < 0.42:
            freq = 660
            env = 0.0                              # a beat of silence between the blips
        elif k < 0.70:
            freq = 700
            env = 1.0
        else:
            freq = 700 - 420 * ((k - 0.70) / 0.30)  # sliding off, pleased with itself
            env = 1.0 - (k - 0.70) / 0.30
        phase += 2 * math.pi * freq / RATE
        out.append(square(phase) * env * 0.5)
    return out


def main():
    print(f"generating into {OUT}")
    write("stun.wav", stun())
    write("fall.wav", fall())
    write("farewell_gremlin.wav", farewell_gremlin())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
