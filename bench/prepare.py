"""Cut the benchmark clips: real test utterances plus stress mixes.

Writes data/samples/<set>/<id>.wav (16 kHz mono) and data/samples/manifest.jsonl,
one line per clip: {"id", "set", "path", "ref", "dur"}. Every engine reads the same
manifest, so results are comparable.

Sets:
  reazon    natural, fast TV speech (closest to streams)
  cv        Common Voice read speech, many microphones
  turns2    two different speakers back to back with a 0.15 s gap (collab turn-taking)
  overlap2  two speakers, the second starts halfway through the first
  noisy     reazon clips under pink noise at 5 dB SNR (game audio / BGM stand-in)
  silence   near-silence and pure noise, reference empty (hallucination check)
"""

import io
import json
import random
from pathlib import Path

import numpy as np
import pandas as pd
import soundfile as sf

SR = 16_000
OUT = Path("data/samples")
rng = random.Random(7)
nprng = np.random.default_rng(7)


def load(parquet: str, n: int, max_dur: float = 20.0):
    df = pd.read_parquet(parquet)
    rows = []
    for i in rng.sample(range(len(df)), len(df)):
        r = df.iloc[i]
        audio, sr = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        if sr != SR:
            idx = np.linspace(0, len(audio) - 1, int(len(audio) * SR / sr))
            audio = np.interp(idx, np.arange(len(audio)), audio).astype(np.float32)
        dur = len(audio) / SR
        if 1.0 <= dur <= max_dur and str(r["transcription"]).strip():
            rows.append((audio, str(r["transcription"]).strip()))
        if len(rows) == n:
            break
    return rows


def pink(n: int) -> np.ndarray:
    white = nprng.standard_normal(n)
    f = np.fft.rfft(white)
    f /= np.sqrt(np.maximum(np.arange(len(f)), 1))
    x = np.fft.irfft(f, n)
    return (x / np.abs(x).max()).astype(np.float32)


def at_snr(sig: np.ndarray, noise: np.ndarray, snr_db: float) -> np.ndarray:
    ps, pn = np.mean(sig**2), np.mean(noise**2)
    return sig + noise * np.sqrt(ps / (pn * 10 ** (snr_db / 10)))


def norm(x: np.ndarray) -> np.ndarray:
    return (x / max(np.abs(x).max(), 1e-6) * 0.9).astype(np.float32)


def main():
    reazon = load(sorted(Path("data/reazonspeech_test").rglob("*.parquet"))[0], 220)
    cv = load(sorted(Path("data/common_voice_8_0").rglob("*.parquet"))[0], 100)
    real, pool = reazon[:150], reazon[150:]
    clips = []
    clips += [("reazon", a, t) for a, t in real]
    clips += [("cv", a, t) for a, t in cv]
    for k in range(30):
        (a1, t1), (a2, t2) = pool[2 * k % len(pool)], pool[(2 * k + 1) % len(pool)]
        gap = np.zeros(int(0.15 * SR), np.float32)
        clips.append(("turns2", norm(np.concatenate([a1, gap, a2])), t1 + t2))
        start = len(a1) // 2
        mix = np.zeros(max(len(a1), start + len(a2)), np.float32)
        mix[: len(a1)] += a1
        mix[start : start + len(a2)] += a2
        clips.append(("overlap2", norm(mix), t1 + t2))
    for a, t in real[:40]:
        clips.append(("noisy", norm(at_snr(a, pink(len(a)), 5.0)), t))
    for k in range(10):
        n = int(rng.uniform(4, 12) * SR)
        quiet = nprng.standard_normal(n).astype(np.float32) * 0.002
        clips.append(("silence", quiet if k % 2 else norm(pink(n)) * 0.3, ""))

    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "manifest.jsonl", "w") as m:
        counts = {}
        for s, a, t in clips:
            counts[s] = counts.get(s, 0) + 1
            cid = f"{s}-{counts[s]:03d}"
            p = OUT / s / f"{cid}.wav"
            p.parent.mkdir(exist_ok=True)
            sf.write(p, a, SR, subtype="PCM_16")
            m.write(json.dumps({"id": cid, "set": s, "path": str(p.resolve()), "ref": t,
                                "dur": round(len(a) / SR, 3)}, ensure_ascii=False) + "\n")
    print(counts, "total audio %.1f min" % (sum(len(a) for _, a, _ in clips) / SR / 60))


if __name__ == "__main__":
    main()
