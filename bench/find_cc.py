"""Find VTuber videos on YouTube with human-made (not automatic) Japanese subtitles."""
import json, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

queries = sys.argv[1:]
ids = {}
for q in queries:
    out = subprocess.run(["yt-dlp", "--flat-playlist", "--print", "%(id)s|%(duration)s|%(title)s",
                          f"ytsearch25:{q}"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        i, d, t = line.split("|", 2)
        if d != "NA" and 120 <= float(d) <= 1800:
            ids[i] = (float(d), t)

def subs(i):
    r = subprocess.run(["yt-dlp", "-J", "--skip-download", f"https://www.youtube.com/watch?v={i}"],
                       capture_output=True, text=True)
    try:
        info = json.loads(r.stdout)
    except Exception:
        return i, []
    return i, [k for k in (info.get("subtitles") or {}) if k.startswith("ja")]

with ThreadPoolExecutor(6) as ex:
    for i, langs in ex.map(subs, ids):
        if langs:
            print(f"{i}|{ids[i][0]:.0f}|{langs}|{ids[i][1][:90]}", flush=True)
