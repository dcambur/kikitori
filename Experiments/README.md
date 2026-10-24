# Experiments (spikes, not product code)

Throwaway tools behind `docs/design/realtime-sync.md`. Nothing in `Sources/` depends on them, and
they are not part of the app bundle. Each prints what it measured. The numbers in the design doc
come from these runs; trimmed logs are in `results/`.

| Target / script | What it checks |
|---|---|
| `kk-spike-mse` (`mse-lookahead/`) | Reads the audio YouTube's own player has downloaded and handed to Media Source Extensions (`SourceBuffer.appendBuffer`), in a muted window: formats, how far ahead of the playhead it is, ads, seeking, auto-dub switching, holding a live stream behind the live edge. Decodes it with `decodeAudioData` and with WebCodecs on demuxed frames (exact timestamps), and writes a WAV. |
| `kk-spike-timing` (`timing/`) | Runs the real chunker (Silero VAD, 6 s cap) and `SpeechTranscriber` with and without `.audioTimeRange` on a file: is the text identical, how fine are the times, how do they line up with the audio and with ground truth, and does refining long runs to their sound onset help. |
| `timing/make_truth.py` | A synthetic recording with known word times (macOS `say`, voice Kyoko). |
| `timing/karaoke.py` | A page that plays a file and reveals each character at its time, to judge the sync by ear. |
| `kk-spike-gpu` (`gpu-process/`) | Two web views in one process: one WebKit GPU process or two? |
| `kk-check-mediatap` (`mediatap-check/`) | The production `MediaTapScript` on bytes captured by `kk-spike-mse`, in random appends: coverage, gaps, switched on late, resync after `abort()` |
| `kk-check-reveal` (`reveal-check/`) | The production `PlayerScript` reveal with a fake clock: timing, `kkReveal`, late cues, seeks, ads |
| `kk-check-sync` (`sync-check/`) | Both production scripts plus `MediaPipeline` on a real YouTube page, muted and without translation: cue lead and reveal accuracy |

```bash
swift run kk-spike-mse "<youtube url>" <seconds> <out prefix> [--behind <s>] [--seek <to>@<at>]
swift run kk-spike-timing <audio> [--truth truth.json] [--json out.json] [--ass out.ass]
python3 Experiments/timing/make_truth.py <dir>
python3 Experiments/timing/karaoke.py <timing.json> <audio> <out.html>
swift run kk-spike-gpu [url]
swift run kk-check-mediatap <captured .webm/.mp4> [--late] [--abort]
swift run kk-check-reveal
swift run kk-check-sync "<youtube url>" <seconds> [--seek <to>@<at>]
```

The app itself: `open -n build/Kikitori.app --args --player-test "<url>" <seconds> <log> --muted`
(logs synced reveals and the transcript; translates, so it bills a little).

The web-view spikes open small windows with the page muted (WebKit's page mute plus
`video.muted`): nothing plays aloud. `out/` (git-ignored) holds pages built from stream audio;
don't commit those.
