"""Run any engine from engines.py over the synthetic manifest (results/raw/<label>.jsonl).

usage: uv run python run_engine.py <engine> <label> [--beam N]
"""

import json
import sys
from pathlib import Path

import engines

engine, label = sys.argv[1], sys.argv[2]
beam = int(sys.argv[sys.argv.index("--beam") + 1]) if "--beam" in sys.argv else 1
clips = [json.loads(l) for l in open("data/samples/manifest.jsonl")]
out = engines.transcribe(engine, [c["path"] for c in clips], None, beam)
Path("results/raw").mkdir(parents=True, exist_ok=True)
Path(f"results/raw/{label}.jsonl").write_text("".join(
    json.dumps({"id": c["id"], "hyp": h, "sec": round(s, 4)}, ensure_ascii=False) + "\n"
    for c, (h, s) in zip(clips, out)))
print(label, "done")
