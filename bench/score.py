"""Score every results/raw/<label>.jsonl against the manifest.

CER (character error rate) on kana readings: NFKC, punctuation/symbols/spaces removed,
then kanji converted to hiragana (pykakasi), so 素敵/すてき or 蕾/つぼみ are not errors.
Pooled per set (total edits / total reference characters), with each clip's edits capped
at its reference length: a repetition loop counts as a fully wrong clip, not 100x. RTF = processing time /
audio duration (lower is faster; 0.05 means 20x faster than real time). For the
silence set, "halluc" is the share of clips where the engine produced any text.
Writes results/summary.md and prints it.
"""

import json
import unicodedata
from pathlib import Path

import jiwer
import pykakasi

_kks = pykakasi.kakasi()

SETS = ["reazon", "cv", "turns2", "overlap2", "noisy", "silence"]


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    return "".join(ch for ch in s if unicodedata.category(ch)[0] not in "PZSC")


def kana(s: str) -> str:
    return "".join(x["hira"] for x in _kks.convert(norm(s)))


def main():
    clips = {c["id"]: c for c in map(json.loads, open("data/samples/manifest.jsonl"))}
    rows = []
    for f in sorted(Path("results/raw").glob("*.jsonl")):
        lines = [json.loads(l) for l in open(f)]
        summary = next((l for l in lines if l.get("summary")), {})
        hyps = {l["id"]: l for l in lines if "id" in l}
        row = {"engine": f.stem, "peak_gb": summary.get("peak_gb"), "load_s": summary.get("load_s")}
        sec = dur = 0.0
        for s in SETS:
            ids = [i for i, c in clips.items() if c["set"] == s and i in hyps]
            if not ids:
                continue
            if s == "silence":
                row[s] = sum(bool(norm(hyps[i]["hyp"])) for i in ids) / len(ids)
            else:
                edits = total = 0
                for i in ids:
                    ref, hyp = kana(clips[i]["ref"]), kana(hyps[i]["hyp"]) or "∅"
                    o = jiwer.process_characters(ref, hyp)
                    edits += min(o.substitutions + o.deletions + o.insertions, len(ref))
                    total += len(ref)
                row[s] = edits / total
            sec += sum(hyps[i]["sec"] for i in ids)
            dur += sum(clips[i]["dur"] for i in ids)
        row["rtf"] = sec / dur if dur else None
        rows.append(row)

    head = ["engine", *[s if s != "silence" else "halluc" for s in SETS], "RTF", "×RT", "peak GB"]
    md = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for r in rows:
        cells = [r["engine"]]
        cells += [f"{100 * r[s]:.1f}%" if s in r else "–" for s in SETS]
        cells += [f"{r['rtf']:.3f}", f"{1 / r['rtf']:.0f}×" if r["rtf"] else "–",
                  str(r["peak_gb"] or "–")]
        md.append("| " + " | ".join(cells) + " |")
    text = "\n".join(md)
    Path("results/summary.md").write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
