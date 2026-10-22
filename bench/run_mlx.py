"""Transcribe every manifest clip with one MLX Whisper model.

usage: uv run python run_mlx.py <hf-repo> <label> [manifest.jsonl]
Writes results/raw/<label>.jsonl: {"id", "hyp", "sec"} per clip, plus a summary line
with model load time and peak GPU memory.
"""

import json
import os
import sys
import time
from pathlib import Path

import mlx.core as mx
import mlx_whisper
import numpy as np
import soundfile as sf

repo, label = sys.argv[1], sys.argv[2]
manifest = sys.argv[3] if len(sys.argv) > 3 else "data/samples/manifest.jsonl"
clips = [json.loads(l) for l in open(manifest)]
out = Path("results/raw") / f"{label}.jsonl"
out.parent.mkdir(parents=True, exist_ok=True)

opts = dict(path_or_hf_repo=repo, language="ja", task="transcribe",
            condition_on_previous_text=False, verbose=None,
            temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0), compression_ratio_threshold=2.4,
            logprob_threshold=-1.0, no_speech_threshold=0.6)

t0 = time.perf_counter()
mlx_whisper.transcribe(np.zeros(16_000, np.float32), **opts)  # load + warm up
load_s = time.perf_counter() - t0
mx.reset_peak_memory()

with open(out, "w") as f:
    for c in clips:
        audio, _ = sf.read(c["path"], dtype="float32")
        t = time.perf_counter()
        r = mlx_whisper.transcribe(audio, **opts)
        f.write(json.dumps({"id": c["id"], "hyp": r["text"].strip(),
                            "sec": round(time.perf_counter() - t, 4)}, ensure_ascii=False) + "\n")
    f.write(json.dumps({"summary": True, "load_s": round(load_s, 2),
                        "peak_gb": round(mx.get_peak_memory() / 1e9, 2),
                        "loadavg": os.getloadavg()}) + "\n")
print(label, "done", out)
