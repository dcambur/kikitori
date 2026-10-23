#!/usr/bin/env python3
# EXPERIMENT (spike for docs/design/realtime-sync.md), not product code.
#
#   python3 Experiments/timing/karaoke.py <timing.json from kk-spike-timing --json> <audio> <out.html>
#
# A self-contained page that plays the audio and reveals each character at its recognized time,
# the way the player would on the video: for judging the sync by ear. Toggle between the raw
# audioTimeRange starts and the refined ones (first sound inside a long run). The audio is
# embedded as AAC; keep the page local (it contains the stream's audio).
import base64, json, subprocess, sys, tempfile, os

timing, audio, out = sys.argv[1:4]
chunks = json.load(open(timing))
with tempfile.TemporaryDirectory() as tmp:
    m4a = os.path.join(tmp, "a.m4a")
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "32000", audio, m4a], check=True)
    b64 = base64.b64encode(open(m4a, "rb").read()).decode()
lines = [{"start": c["start"], "runs": [{"t": r["text"], "s": r["start"], "o": r.get("onset", r["start"]), "e": r["end"]} for r in c["runs"]]}
         for c in chunks if c["runs"]]
html = """<!doctype html><html><head><meta charset="utf-8"><title>Reveal check</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root { --bg:#111318; --fg:#f4f4f6; --dim:#6b6f7a; --accent:#ffd34d; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px -apple-system, sans-serif; padding:16px; }
.stage { max-width:900px; margin:24px auto; min-height:220px; display:flex; flex-direction:column; justify-content:flex-end; gap:10px; }
.line { font:600 34px/1.35 "Hiragino Sans", sans-serif; text-align:center; }
.line .c { opacity:0; transition:opacity 40ms linear; } .line .c.on { opacity:1; }
.line.old { opacity:.45; font-size:26px; }
.bar { max-width:900px; margin:0 auto; display:flex; gap:12px; align-items:center; flex-wrap:wrap; }
audio { width:100%; max-width:900px; display:block; margin:12px auto; }
label { color:var(--dim); } code { color:var(--accent); }
</style></head><body>
<audio id="a" controls src="data:audio/mp4;base64,__B64__"></audio>
<div class="bar"><label><input type="radio" name="m" value="o" checked> refined starts</label>
<label><input type="radio" name="m" value="s"> raw audioTimeRange starts</label>
<label>offset <input id="off" type="number" value="0" step="20" style="width:70px"> ms</label>
<span id="t" style="margin-left:auto;color:var(--dim)"></span></div>
<div class="stage" id="stage"></div>
<script>
const LINES = __LINES__;
const a = document.getElementById('a'), stage = document.getElementById('stage');
const rows = LINES.map(l => { const d = document.createElement('div'); d.className = 'line';
  l.spans = l.runs.map(r => { const s = document.createElement('span'); s.className = 'c'; s.textContent = r.t; d.appendChild(s); return s; }); l.el = d; return d; });
function frame() {
  const mode = document.querySelector('input[name=m]:checked').value, off = (+document.getElementById('off').value || 0) / 1000;
  const t = a.currentTime - off; document.getElementById('t').textContent = t.toFixed(2) + ' s';
  // current line: the last one whose first character has started; it and the one before show
  let cur = -1; LINES.forEach((l, i) => { if (l.runs[0][mode] <= t) cur = i; });
  const show = new Set([cur, cur - 1]);
  if (cur >= 0 && t > LINES[cur].runs[LINES[cur].runs.length - 1].e + 3) show.clear();
  LINES.forEach((l, i) => {
    const on = show.has(i);
    if (on && !l.el.parentNode) stage.appendChild(l.el); if (!on && l.el.parentNode) l.el.remove();
    l.el.classList.toggle('old', i !== cur);
    l.runs.forEach((r, j) => l.spans[j].classList.toggle('on', r[mode] <= t));
  });
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
</script></body></html>"""
open(out, "w").write(html.replace("__B64__", b64).replace("__LINES__", json.dumps(lines, ensure_ascii=False)))
print(f"wrote {out} ({os.path.getsize(out) // 1024} KB, {len(lines)} lines)")
