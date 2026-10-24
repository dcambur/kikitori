#!/usr/bin/env python3
# EXPERIMENT (for docs/design/speaker-labels.md), not product code.
#
#   python3 Experiments/speakers/splice.py <out prefix> <name>=<solo.wav> <name>=<solo.wav> [...] [--seconds 360] [--seed 1] [--no-level]
#
# A "collab" with known speakers, made from solo streams: turns taken in order from each
# speaker's recording (16 kHz mono 16-bit WAV), one after another. Turn lengths mimic chat:
# a third are short (0.8–2 s, reactions), the rest 2–8 s. Half the changes have no pause (under
# 0.15 s, so they fall inside one chunk), half a pause of 0.3–1 s. Each cut is moved to the
# quietest 20 ms within 0.3 s, so words are rarely chopped. Each source is first scaled to the
# same RMS (-24 dBFS), as a collab's mix levels its voices (--no-level keeps them as they are:
# solo recordings differ by 10 dB or more). Writes <prefix>.wav and
# <prefix>.truth.json ([{speaker, start, end}] in seconds of the new file).
import json, random, struct, sys, wave, math

RATE = 16000

def read(path):
    with wave.open(path) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        return list(struct.unpack("<%dh" % w.getnframes(), w.readframes(w.getnframes())))

def quietest(s, at, reach):
    win = RATE // 50
    best, best_e = at, float("inf")
    for c in range(max(win, at - reach), min(len(s) - win, at + reach), RATE // 100):
        e = sum(x * x for x in s[c - win // 2:c + win // 2])
        if e < best_e: best, best_e = c, e
    return best

def main():
    args = sys.argv[1:]
    prefix = args[0]
    seconds = float(args[args.index("--seconds") + 1]) if "--seconds" in args else 360
    seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 1
    sources = dict(a.split("=", 1) for a in args[1:] if "=" in a)
    rnd = random.Random(seed)
    audio = {n: read(p) for n, p in sources.items()}
    if "--no-level" not in args:
        for n, s in audio.items():
            rms = math.sqrt(sum(x * x for x in s) / len(s)) / 32768
            gain = 10 ** (-24 / 20) / max(rms, 1e-6)
            audio[n] = [max(-32768, min(32767, int(x * gain))) for x in s]
    cursor = {n: 0 for n in audio}
    names = list(audio)
    out, truth, speaker = [], [], rnd.choice(names)
    while len(out) < seconds * RATE:
        length = rnd.uniform(0.8, 2) if rnd.random() < 1 / 3 else rnd.uniform(2, 8)
        s, c = audio[speaker], cursor[speaker]
        if c + int(length * RATE) + RATE >= len(s): break
        end = quietest(s, c + int(length * RATE), int(0.3 * RATE))
        start = len(out) / RATE
        out += s[c:end]
        truth.append({"speaker": speaker, "start": round(start, 3), "end": round(len(out) / RATE, 3)})
        cursor[speaker] = end
        gap = rnd.uniform(0, 0.15) if rnd.random() < 0.5 else rnd.uniform(0.3, 1.0)
        out += [0] * int(gap * RATE)
        speaker = rnd.choice([n for n in names if n != speaker])
    with wave.open(prefix + ".wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack("<%dh" % len(out), *out))
    json.dump(truth, open(prefix + ".truth.json", "w"), indent=0)
    print(f"{prefix}.wav: {len(out) / RATE:.0f} s, {len(truth)} turns, "
          + ", ".join(f"{n} {sum(t['end'] - t['start'] for t in truth if t['speaker'] == n):.0f} s" for n in names))

main()
