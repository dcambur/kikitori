"""Real-stream test set from VTuber clips with human Japanese captions (data/vtcc).

  uv run python vtcc.py build             parse captions; cut caption groups (oracle segments)
  uv run python vtcc.py seg <variant>     cut pipeline chunks: fixed15 | vad | vad6 (max 6 s), optional +demucs
  uv run python vtcc.py run <engine> <label> <manifest> [--beam N] [--prompt prev|gloss]
  uv run python vtcc.py score             score everything in results/vtcc/

Oracle: each caption group (cues merged across gaps < 1 s, max 20 s) is transcribed alone and
scored against its own text: pure engine accuracy on stream audio.
Pipeline: the clip's first ~5 min is cut by the variant's chunker, the outputs are joined in
order and scored against all captions of that span: what the app would actually show.
Captions are made by clip editors, so a little side chatter is uncaptioned; that adds the same
insertions for every engine and shifts all numbers equally.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

import jiwer
import numpy as np
import soundfile as sf

import engines
from score import kana

D = Path("data/vtcc")
SR = 16_000
SPAN = 300.0


def ts(s):
    h, m, rest = s.split(":")
    return int(h) * 3600 + int(m) * 60 + float(rest)


def clean(t):
    t = re.sub(r"<[^>]+>", "", t)
    t = re.sub(r"[（(\[【［][^）)\]】］]*[）)\]】］]", "", t)  # (笑) [拍手] 【SE】
    t = re.sub(r"^[^\s：:]{1,8}[：:]", "", t)               # speaker labels
    return t.replace("♪", "").strip()


def cues(vtt):
    out, lines = [], vtt.read_text().splitlines()
    for i, l in enumerate(lines):
        if "-->" in l:
            a, b = l.split("-->")
            text = []
            for t in lines[i + 1:]:
                if not t.strip():
                    break
                text.append(clean(t))
            text = "".join(text)
            if text and (not out or out[-1][2] != text):
                out.append((ts(a.strip()), ts(b.split()[0]), text))
    return sorted(out)


def build():
    clips = {}
    for vtt in sorted(D.glob("*.ja.vtt")):
        cid = vtt.name.split(".")[0]
        wav = D / f"{cid}.wav"
        if not wav.exists():
            continue
        audio, _ = sf.read(wav, dtype="float32")
        cs = [c for c in cues(vtt) if c[1] <= min(SPAN, len(audio) / SR) - 0.5]
        groups = []
        for s, e, t in cs:
            if groups and s - groups[-1][1] < 1.0 and e - groups[-1][0] <= 20:
                groups[-1] = (groups[-1][0], max(e, groups[-1][1]), groups[-1][2] + t)
            else:
                groups.append((s, e, t))
        end = cs[-1][1] + 0.3
        clips[cid] = {"end": end, "ref": "".join(t for _, _, t in cs), "groups": groups}
    (D / "clips.json").write_text(json.dumps(clips, ensure_ascii=False, indent=1))
    rows = []
    for cid, c in clips.items():
        rows += cut(cid, [(max(s - 0.2, 0), e + 0.2, t) for s, e, t in c["groups"]], "oracle")
    write_manifest("oracle", rows)
    print({k: f"{len(v['groups'])} groups, {v['end']:.0f}s" for k, v in clips.items()})


def cut(cid, spans, variant, source=None):
    audio, _ = sf.read(source or D / f"{cid}.wav", dtype="float32")
    out = []
    for k, (s, e, t) in enumerate(spans):
        p = D / "seg" / variant / f"{cid}-{k:03d}.wav"
        p.parent.mkdir(parents=True, exist_ok=True)
        sf.write(p, audio[int(s * SR):int(e * SR)], SR, subtype="PCM_16")
        out.append({"id": p.stem, "clip": cid, "path": str(p.resolve()), "ref": t,
                    "start": round(s, 2), "dur": round(e - s, 2)})
    return out


def write_manifest(variant, rows):
    p = D / "seg" / variant / "manifest.jsonl"
    p.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    print(variant, len(rows), "segments ->", p)


def vocals(cid):
    """Demucs htdemucs vocal stem, back at 16 kHz mono (cached)."""
    out = D / "demucs" / f"{cid}.wav"
    if not out.exists():
        tmp = D / "demucs" / "raw"
        subprocess.run([sys.executable, "-m", "demucs", "--two-stems=vocals", "-n", "htdemucs",
                        "-d", "mps", "-o", str(tmp), str(D / f"{cid}.wav")], check=True,
                       capture_output=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i",
                        str(tmp / "htdemucs" / cid / "vocals.wav"), "-ac", "1", "-ar", "16000",
                        str(out)], check=True)
    return out


def vad_spans(path, end, max_len=15.0):
    import torch
    from silero_vad import get_speech_timestamps, load_silero_vad
    model = load_silero_vad()
    audio, _ = sf.read(path, dtype="float32")
    audio = audio[:int(end * SR)]
    sp = get_speech_timestamps(torch.from_numpy(audio), model, sampling_rate=SR, threshold=0.5,
                               min_silence_duration_ms=250, speech_pad_ms=150,
                               max_speech_duration_s=max_len)
    spans = []
    for s in sp:
        a, b = s["start"] / SR, s["end"] / SR
        if spans and b - spans[-1][0] <= max_len and a - spans[-1][1] < 2.0:
            spans[-1] = (spans[-1][0], b, "")
        else:
            spans.append((a, b, ""))
    return spans


def seg(variant):
    clips = json.loads((D / "clips.json").read_text())
    rows = []
    for cid, c in clips.items():
        src = vocals(cid) if "demucs" in variant else D / f"{cid}.wav"
        if variant.startswith("fixed15"):
            spans = [(s, min(s + 15, c["end"]), "") for s in np.arange(0, c["end"], 15)]
        elif variant.startswith("vad6"):
            spans = vad_spans(src, c["end"], max_len=6.0)
        elif variant.startswith("vad"):
            spans = vad_spans(src, c["end"])
        elif variant.startswith("oracle"):
            spans = [(max(s - 0.2, 0), e + 0.2, t) for s, e, t in c["groups"]]
        rows += cut(cid, spans, variant, src)
    write_manifest(variant, rows)


GLOSSARY = ("ホロライブ、大空スバル、百鬼あやめ、癒月ちょこ、さくらみこ、白上フブキ、大神ミオ、夏色まつり、"
            "水宮枢、鷹嶺ルイ、儒烏風亭らでん、虎金妃笑虎、角巻わため、一条莉々華、ラプラス・ダークネス、"
            "猫又おかゆ、獅白ぼたん、姫森ルーナ、AZKi、綺々羅々ヴィヴィ、ReGLOSS、切り抜き、コラボ、配信、"
            "スパチャ、草、てぇてぇ、おつ。")


def run(engine, label, manifest, beam=1, prompt=None):
    rows = [json.loads(l) for l in open(manifest)]
    paths = [r["path"] for r in rows]
    if prompt == "prev":  # each segment sees the previous segment's own output (sequential)
        out, prev = [], {}
        for r in rows:
            o = engines.transcribe(engine, [r["path"]], [prev.get(r["clip"])], beam)[0]
            out.append(o)
            prev[r["clip"]] = o[0][-100:] or None
    elif prompt == "gloss":
        out = engines.transcribe(engine, paths, [GLOSSARY] * len(paths), beam)
    else:
        out = engines.transcribe(engine, paths, None, beam)
    res = Path("results/vtcc") / f"{label}.jsonl"
    res.parent.mkdir(parents=True, exist_ok=True)
    res.write_text("".join(json.dumps({"id": r["id"], "clip": r["clip"], "variant": Path(manifest).parent.name,
                                       "hyp": h, "sec": round(s, 4), "dur": r["dur"]}, ensure_ascii=False) + "\n"
                           for r, (h, s) in zip(rows, out)))
    print(label, "->", res)


def cer(ref, hyp):
    ref, hyp = kana(ref), kana(hyp) or "∅"
    o = jiwer.process_characters(ref, hyp)
    return o.substitutions + o.deletions + o.insertions, len(ref), o.insertions


def score():
    clips = json.loads((D / "clips.json").read_text())
    oracle = {r["id"]: r["ref"] for r in map(json.loads, open(D / "seg/oracle/manifest.jsonl"))}
    lines = ["| run | segments | CER | of which insertions | ×RT |", "|---|---|---|---|---|"]
    for f in sorted(Path("results/vtcc").glob("*.jsonl")):
        rs = [json.loads(l) for l in open(f)]
        variant = rs[0]["variant"]
        edits = total = ins = 0
        if variant.startswith("oracle"):
            for r in rs:
                e, n, i = cer(oracle[r["id"]], r["hyp"])
                edits, total, ins = edits + min(e, n), total + n, ins + i
        else:
            for cid, c in clips.items():
                hyp = "".join(r["hyp"] for r in rs if r["clip"] == cid)
                e, n, i = cer(c["ref"], hyp)
                edits, total, ins = edits + e, total + n, ins + i
        rt = sum(r["dur"] for r in rs) / max(sum(r["sec"] for r in rs), 1e-9)
        lines.append(f"| {f.stem} | {variant} | {100 * edits / total:.1f}% | {100 * ins / total:.1f}% | {rt:.0f}× |")
    text = "\n".join(lines)
    Path("results/vtcc_summary.md").write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "build":
        build()
    elif cmd == "seg":
        seg(sys.argv[2])
    elif cmd == "run":
        a = sys.argv[2:]
        beam = int(a[a.index("--beam") + 1]) if "--beam" in a else 1
        prompt = a[a.index("--prompt") + 1] if "--prompt" in a else None
        run(a[0], a[1], a[2], beam, prompt)
    elif cmd == "score":
        score()
