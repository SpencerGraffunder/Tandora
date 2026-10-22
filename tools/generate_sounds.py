#!/usr/bin/env python3
"""Procedurally synthesize Tandora's retro sound effects (issue #15).

All cues are original addition/subtraction-square and triangle chiptune
sounds generated from scratch — no sampled or transcribed copyrighted
melodies. Run from the repo root:

    python3 tools/generate_sounds.py assets/sounds

It writes 44.1 kHz 16-bit mono WAVs next to the script's output directory
and, when ffmpeg with libvorbis is available, converts them to .ogg
(Godot's preferred SFX format). Commit the .ogg files (plus Godot's
generated .import files); the WAV intermediates go to a temp dir.
"""

import math
import os
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 44100


def _osc(kind):
    if kind == "square":
        return lambda phase: 1.0 if math.sin(phase) >= 0.0 else -1.0
    if kind == "triangle":
        return lambda phase: 2.0 * abs(2.0 * (phase / (2.0 * math.pi) - math.floor(0.5 + phase / (2.0 * math.pi)))) - 1.0
    if kind == "sine":
        return lambda phase: math.sin(phase)
    raise ValueError(kind)


def note(freq, dur, kind="square", vol=0.5, decay=6.0, slide_to=None):
    """One tone with exponential decay envelope and optional pitch slide.

    freq <= 0 emits silence (used to offset harmony layers).
    """
    n = int(RATE * dur)
    if freq <= 0.0 or n == 0:
        return [0.0] * n
    osc = _osc(kind)
    fade_in = int(RATE * 0.004)  # de-click ramp
    out = []
    phase = 0.0
    for i in range(n):
        t = i / n
        f = freq if slide_to is None else freq + (slide_to - freq) * t
        phase += 2.0 * math.pi * f / RATE
        env = (2.0 ** (-decay * t)) if decay else 1.0
        if i < fade_in:
            env *= i / fade_in
        out.append(osc(phase) * env * vol)
    return out


def seq(notes, base_vol=1.0):
    """Concatenate (freq, dur) tuples or (freq, dur, kwargs) tuples."""
    out = []
    for spec in notes:
        freq, dur = spec[0], spec[1]
        kwargs = spec[2] if len(spec) > 2 else {}
        out.extend(note(freq, dur, **kwargs))
    return [s * base_vol for s in out]


def mix(*layers):
    n = max(len(l) for l in layers)
    out = []
    for i in range(n):
        out.append(sum(l[i] if i < len(l) else 0.0 for l in layers))
    return out


def normalize(buf, peak):
    m = max(abs(s) for s in buf) or 1.0
    return [s * peak / m for s in buf]


def write_wav(path, buf):
    buf = normalize(buf, 0.9)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in buf))


# ---------------------------------------------------------------- cues ----

SQ = dict(kind="square")
TRI = dict(kind="triangle")

SOUNDS = {
    # horizontal step: short low chirp
    "move": lambda: note(300, 0.055, vol=0.5, decay=8.0, slide_to=170, **SQ),
    # rotation: brighter rising chirp
    "rotate": lambda: note(620, 0.05, vol=0.38, decay=5.0, slide_to=920, **SQ),
    # piece lock: dull thud + tiny noise tick
    "lock": lambda: mix(
        note(180, 0.09, vol=0.55, decay=12.0, slide_to=120, **SQ),
        note(90, 0.05, vol=0.25, decay=18.0, **SQ),
    ),
    # 1-3 line clear: rising triad arpeggio (pitch-shifted per line count)
    "clear": lambda: seq([
        (523.25, 0.09, dict(vol=0.42, decay=5.0, **SQ)),
        (659.25, 0.09, dict(vol=0.42, decay=5.0, **SQ)),
        (783.99, 0.13, dict(vol=0.45, decay=4.0, **SQ)),
    ]),
    # 4-line clear: original triumphant fanfare (NOT the Korobeiniki melody)
    "tetris": lambda: mix(
        seq([
            (784.0, 0.09, dict(vol=0.45, decay=4.0, **SQ)),
            (1046.5, 0.09, dict(vol=0.45, decay=4.0, **SQ)),
            (1318.5, 0.09, dict(vol=0.45, decay=4.0, **SQ)),
            (1568.0, 0.24, dict(vol=0.5, decay=3.0, **SQ)),
        ]),
        seq([
            (0.0, 0.27),
            (0.0, 0.0),
            (659.25, 0.33, dict(vol=0.22, decay=3.0, **TRI)),
        ]),
    ),
    # level up: soft rising run
    "levelup": lambda: seq([
        (392.0, 0.07, dict(vol=0.5, decay=4.0, **TRI)),
        (523.25, 0.07, dict(vol=0.5, decay=4.0, **TRI)),
        (659.25, 0.07, dict(vol=0.5, decay=4.0, **TRI)),
        (784.0, 0.16, dict(vol=0.55, decay=3.0, **TRI)),
    ]),
    # game over: original descending lament
    "gameover": lambda: seq([
        (440.0, 0.16, dict(vol=0.5, decay=5.0, **TRI)),
        (392.0, 0.16, dict(vol=0.5, decay=5.0, **TRI)),
        (349.23, 0.16, dict(vol=0.5, decay=5.0, **TRI)),
        (293.66, 0.16, dict(vol=0.5, decay=5.0, **TRI)),
        (261.63, 0.6, dict(vol=0.55, decay=2.5, **TRI)),
    ]),
    # pause: falling blip
    "pause": lambda: seq([
        (660.0, 0.055, dict(vol=0.4, decay=5.0, **SQ)),
        (440.0, 0.075, dict(vol=0.4, decay=5.0, **SQ)),
    ]),
    # resume: rising blip
    "resume": lambda: seq([
        (440.0, 0.055, dict(vol=0.4, decay=5.0, **SQ)),
        (660.0, 0.075, dict(vol=0.4, decay=5.0, **SQ)),
    ]),
}


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    have_ffmpeg = False
    try:
        enc = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"],
                             capture_output=True, text=True)
        have_ffmpeg = "libvorbis" in enc.stdout
    except FileNotFoundError:
        pass

    tmp = tempfile.mkdtemp(prefix="tandora_sfx_")
    for name, synth in sorted(SOUNDS.items()):
        buf = synth()
        wav_path = os.path.join(tmp, name + ".wav")
        write_wav(wav_path, buf)
        dur = len(buf) / RATE
        if have_ffmpeg:
            ogg_path = os.path.join(out_dir, name + ".ogg")
            r = subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-i", wav_path, "-c:a", "libvorbis", "-q:a", "4", ogg_path],
                capture_output=True, text=True)
            if r.returncode != 0:
                print("ffmpeg failed for %s: %s" % (name, r.stderr))
                sys.exit(1)
            print("%-9s %5.2fs -> %s (%d B)" % (name, dur, ogg_path, os.path.getsize(ogg_path)))
        else:
            wav_out = os.path.join(out_dir, name + ".wav")
            write_wav(wav_out, buf)
            print("%-9s %5.2fs -> %s (no libvorbis; WAV kept)" % (name, dur, wav_out))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets/sounds")
