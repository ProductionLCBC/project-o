#!/usr/bin/env python3
"""Project O — the bench machine root (Spec 4 §15, Area 7).

  python3 -I scripts/bench-machine.py make <dest> [--format 1920x1080p60] [--device decklink:154e100e]
      Copies tests/fixtures/spike/machine/ to <dest> (which must not exist) with
      output 1, stack 1's, on the DeckLink card in --format in place of the
      wall's display, limited range and free-running, and audio output 1 made
      the card's embedded audio, so the clapper's click goes out with the
      picture and the room stays silent. Spec 4 §15 as corrected on
      2026-11-22: the bench's card is a 6G DeckLink SDI 4K with its SDI output
      cabled to its own input, so stack 1 goes to the card at 1920x1080p60.
      An interlaced format names its field rate: 1920x1080i60 is 30 frames a
      second, as outputs.json holds it (Spec 1 §3).

  python3 -I scripts/bench-machine.py sdi <machine root>
      Prints the first SDI output's device and format, as `oengine capture`
      takes them: "decklink:154e100e 1920x1080p60".

Only the standard library; JSON written with sorted keys, two-space indent, LF.
"""

import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPIKE_MACHINE = os.path.join(ROOT, "tests", "fixtures", "spike", "machine")
FRACTIONAL = {"59.94": (60000, 1001), "5994": (60000, 1001), "29.97": (30000, 1001), "2997": (30000, 1001),
              "23.98": (24000, 1001), "2398": (24000, 1001)}


def gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def reduced(num, den):
    g = gcd(num, den) or 1
    return num // g, den // g


def parse_format(text):
    """1920x1080p60 or 1920x1080i59.94 -> {width, height, rate: {num, den}, interlaced}; the rate is the frame rate."""
    match = re.fullmatch(r"(\d+)x(\d+)([pi])([0-9./]+)", text.lower())
    if not match:
        raise SystemExit(f"bench-machine: a format is like 1920x1080p60 or 1920x1080i59.94, not {text}")
    width, height, scan, rate = int(match.group(1)), int(match.group(2)), match.group(3), match.group(4)
    if "/" in rate:
        num, den = (int(x) for x in rate.split("/"))
    elif rate in FRACTIONAL:
        num, den = FRACTIONAL[rate]
    else:
        num, den = int(rate), 1
    interlaced = scan == "i"
    if interlaced:
        den *= 2
    num, den = reduced(num, den)
    return {"height": height, "interlaced": interlaced, "rate": {"den": den, "num": num}, "width": width}


def format_name(fmt):
    num, den = fmt["rate"]["num"], fmt["rate"]["den"]
    if fmt["interlaced"]:
        num, den = reduced(num * 2, den)
    number = str(num) if den == 1 else f"{num / den:.2f}"
    return f"{fmt['width']}x{fmt['height']}{'i' if fmt['interlaced'] else 'p'}{number}"


def write_json(path, value):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def make(dest, fmt_text, device):
    if os.path.exists(dest):
        raise SystemExit(f"bench-machine: {dest} is there already; give a new folder")
    fmt = parse_format(fmt_text)
    shutil.copytree(SPIKE_MACHINE, dest)
    outputs_path = os.path.join(dest, "outputs.json")
    with open(outputs_path, encoding="utf-8") as handle:
        outputs = json.load(handle)
    first = next(o for o in outputs["outputs"] if o["number"] == 1)
    first.update({"kind": "sdi", "device": device, "format": fmt, "colorRange": "limited", "genlock": "freeRun",
                  "label": "Main SDI"})
    write_json(outputs_path, outputs)
    audio_path = os.path.join(dest, "audio-outputs.json")
    with open(audio_path, encoding="utf-8") as handle:
        audio = json.load(handle)
    one = next(a for a in audio["audioOutputs"] if a["number"] == 1)
    one.update({"kind": "sdiEmbedded", "device": 1, "fallbackDevice": None, "label": "SDI embedded"})
    write_json(audio_path, audio)
    print(f"bench-machine: {dest}: output 1 on {device} at {format_name(fmt)}, audio output 1 embedded in it")


def sdi(machine_root):
    with open(os.path.join(machine_root, "outputs.json"), encoding="utf-8") as handle:
        outputs = json.load(handle)
    for output in sorted(outputs["outputs"], key=lambda o: o["number"]):
        if output["kind"] == "sdi":
            print(output["device"], format_name(output["format"]))
            return
    raise SystemExit(f"bench-machine: {machine_root} has no SDI output")


def main(argv):
    if len(argv) >= 2 and argv[0] == "make":
        options = dict(zip(argv[2::2], argv[3::2]))
        make(argv[1], options.get("--format", "1920x1080p60"), options.get("--device", "decklink:154e100e"))
    elif len(argv) == 2 and argv[0] == "sdi":
        sdi(argv[1])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
