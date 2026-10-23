# Exact-sync subtitles in Watch: research and recommendation

Status: research with spikes, 2026-10-23. Nothing here is built into the app. The spike code is in
`Experiments/` (see its README), and trimmed logs are in `Experiments/results/`.

## In short

**Recommendation: use one player and read ahead from its own media buffer.** YouTube's player
downloads the audio well before it plays it, and hands it to the browser through Media Source
Extensions (`SourceBuffer.appendBuffer`). A script injected at document start sees those bytes,
decodes them with WebCodecs (with exact media timestamps), and sends 16 kHz audio to our pipeline
**15–120 s before the viewer hears it**. Today's chunker, Apple recognizer and Claude Haiku
translator then run unchanged, just early. Each line goes to the page with per-character times
and is revealed by `video.currentTime`.

- **VOD:** nothing else is needed. In every run the audio was at least 15 s ahead, usually 30–120 s.
- **Live:** the player is held about 12 s behind the live edge with YouTube's own DVR (`seekTo`).
  It stayed there with no catch-up, and the buffer then holds the next ~15 s of audio.

The hidden look-ahead player (the starting idea) also works in principle, but it is worse on every
axis. It needs a separate helper app, because two web views in one app share one WebKit GPU
process (spiked). It doubles the streaming. It plays the video and its ads a second time where
nobody sees them, and it maps time through two players' clocks instead of the media's own
timestamps.

Decisions for you are listed at the end (§10). The main one is whether reading the player's own
buffered bytes is acceptable to you under the "no direct download" rule. It makes no extra
requests and stores nothing.

## 1. Why subtitles lag today, in numbers

A line can only be finished after its chunk ends. The chunk ends at a 0.5 s pause, or at the
6 s cap. Then come recognition (~0.1 s per chunk) and translation (~2.5 s, longer at times).
Measured today: finished Japanese 3–7 s after speech, English ~2.5 s after that. To show final
text and English the moment a character is spoken, the audio must reach the pipeline at least

    lead ≥ chunk (≤ 6 s) + pause to close it (0.5 s) + recognition (~0.2 s) + translation (2.5 s typical, ~5 s slow)
         ≈ 9–12 s

before the viewer hears it. There are only two ways to get that: get the audio early, or show the
viewer the picture and sound late. Every approach below is one of these, or both.

## 2. The constraints, restated

| # | Constraint (user's, not negotiable) | What it rules out |
|---|---|---|
| C1 | In sync, real time: no visible delay between speech and its subtitle | showing lines when ready |
| C2 | Text from our transcriber (Apple SpeechTranscriber via our pipeline) | YouTube captions, auto-translations, third-party transcripts |
| C3 | No jitter: reveal from final results and their per-character times, never rewritten | volatile results, late words pushed in |
| C4 | No quality loss: same chunking, same Haiku translation, no shorter chunks or cheaper models | speeding up by degrading |
| C5 | No direct download from YouTube's servers (yt-dlp style) | AVPlayer on stream URLs, extra fetches |

## 3. Approaches

### A. Read ahead from the player's own media buffer (recommended)

One player, the visible one. A page script installed at document start wraps
`MediaSource.prototype.addSourceBuffer` and `SourceBuffer.prototype.appendBuffer`, then calls the
originals unchanged. So it sees every audio byte YouTube's player has fetched, at the moment the
player hands it to WebKit. That is long before it plays. The script:

- demuxes the container (WebM/Opus for VOD, fragmented MP4/AAC for live, both seen);
- decodes the audio with WebCodecs `AudioDecoder`, keeping each frame's media timestamp;
- posts mono PCM with its media time to the app.

The app runs today's pipeline on that audio, in media time. Ads come in their own MediaSource,
so they are easy to drop. Seeks show up as a new range of timestamps.

For live, the same buffer holds only ~2.5 s ahead at the live edge, so the player is placed D
seconds behind live with the DVR (`movie_player.seekTo(seekableEnd − D)`). Then the buffer holds
D + ~3 s ahead.

- Meets C1 for VOD always (lead ≥ 15 s measured). Meets it for live when the stream has DVR. A
  live stream without DVR gets today's behaviour.
- Meets C2, C3 and C4. It is the same pipeline: chunker, recognizer and translator are
  untouched, and the text is identical with per-character times switched on (spiked).
- C5: no extra request. It reads bytes the official player already downloaded for playback,
  keeps them in memory only, and never stores them. Ads still play. See §7 on terms of service.
- Time mapping is exact: the container's timestamps are the video's `currentTime` timeline
  (`timestampOffset` was 0 everywhere, and the hook records it anyway).

### B. Hidden look-ahead player (the starting idea)

A second copy of the video plays N seconds ahead in a helper app, with its sound tapped
(`muteBehavior = .muted`). The visible player shows each line when its `currentTime` reaches it.

- Needs a separate helper app (its own WebKit UI process). Two web views in one app share **one**
  WebKit GPU process even with separate data stores (spiked, §5.8), so their sound cannot be
  separated by a process tap.
- Sign-in: the helper app has its own website data store, so it is not signed in. Cookies would
  have to be copied into it. Members-only streams need that.
- Ads: the helper gets its own ads, at other times. An unskippable ad stops its lead; the visible
  player's ads pause the visible timeline. The lead needs constant re-seeking.
- Time mapping: audio tap time to helper `currentTime` (sampled every 500 ms) to visible
  `currentTime`. That is ±50–150 ms of jitter plus drift, against exact timestamps in A.
- Doubles the streaming. A 144p helper saves the video bandwidth, but the audio is fetched twice.
- Plays the video and its ads where nobody watches: view and ad-impression counts go up (§7).
- For live it needs the same DVR hold-behind as A anyway.

It meets C1 to C5 only as well as A does, at several times the complexity and with more risk.

### C. One player, picture and sound delayed (capture and re-present)

Tap the player's sound muted and play it back D seconds later through our own output. Capture
the web view's picture with ScreenCaptureKit, buffer D seconds of it, and show the delayed copy.

- 12 s of 1080p60 frames is about 6 GB raw, so it must be re-encoded with HEVC and decoded again.
  That costs picture quality and power.
- The viewer would click YouTube's controls, chat and menus on a recording that is 12 s old.
- Very high complexity for a worse picture. **Rejected.**

### D. Time-shift alone (DVR, no second source)

Hold the visible player behind live and keep tapping its sound. The tap hears exactly what the
viewer hears, so there is no lead at all. **Does not work on its own.** The time shift only helps
combined with something that reads ahead, which is A for live (or B).

### E. Other media APIs considered

| Idea | Why not |
|---|---|
| Web Audio `createMediaElementSource` on the video | Silent for cross-origin media in WebKit (found in phase 1); also not ahead |
| `HTMLMediaElement.captureStream()` | Real-time only, not ahead; not reliable in WebKit |
| AVPlayer or AVAssetReader on the stream URLs | Fetches media directly: C5 |
| Prescan a VOD faster (2× hidden playback) | Time-stretched audio recognizes worse: C4; also B's problems |
| YouTube captions or auto-translation | C2 |

### Hybrid (what A becomes in practice)

- **VOD:** A as is.
- **Live with DVR:** A, with the player held D ≈ 12 s behind live.
- **Live without DVR, Twitch live, other sites, encrypted media:** no lead is possible, so today's
  mode stays. That is the live line, then the finished line, from the process tap.

The Watch toolbar says which mode is on ("Synced" or "Not synced: …").

## 4. Constraint matrix

| | A: own buffer | B: hidden player | C: delayed re-present | D: time-shift alone |
|---|---|---|---|---|
| C1 sync, VOD | ✅ lead 15–120 s | ✅ if lead held through ads | ✅ | ❌ no lead |
| C1 sync, live | ✅ with DVR (D ≈ 12 s) | ✅ with DVR | ✅ | ❌ |
| C2 our transcriber | ✅ | ✅ | ✅ | ✅ |
| C3 final text, per-char reveal | ✅ exact media times | ⚠️ ±50–150 ms clock mapping | ✅ | ❌ |
| C4 no quality loss | ✅ identical pipeline | ✅ | ⚠️ picture re-encoded | ✅ |
| C5 no direct download | ✅ no extra requests (see §7) | ⚠️ a second full playback | ✅ | ✅ |
| Extra bandwidth | none | +1 stream (≥ audio, ~130 kb/s) | none | none |
| System Audio Recording permission | not needed in Watch | needed | needed | needed |
| Complexity | medium | high | very high | — |

## 5. Spike results

All runs on an M4 Pro, macOS 27.0.1, not signed in, in a muted window (page-level mute plus
`video.muted`; nothing played aloud). The test VOD is the Natsuiro Matsuri 雑談 archive
(`kLFsqvruEFs`, from 600 s). The live test is Weathernews' 24/7 Japanese live
(`youtube.com/@weathernews/live`). Logs are in `Experiments/results/`.

### 5.1 How far ahead the audio is (VOD)

`kk-spike-mse` prints, every 2 s, how far the audio SourceBuffer's buffered range reaches past the
playhead (video's own audio only, ads excluded):

| Run | Ahead at start | Min | Max | Notes |
|---|---|---|---|---|
| vod1 (60 s) | 18.7 s | 16.7 s | 82.2 s | |
| vod2 (50 s) | 18.2 s | 16.1 s | 72.3 s | `mse-vod2.txt` |
| seek (130 s) | 19.4 s | 15.3 s | 119.7 s | seek to 1500 s at 14 s, then a 10 s mid-roll ad; `mse-seek.txt` |

YouTube fetches in 10 s Opus clusters, delivered in many partial appends. It keeps topping up, up
to about 120 s ahead. The low points (15–17 s) come just before each new fetch. The audio is
`audio/webm; codecs="opus"` (48 kHz stereo), and the picture `av01` in MP4.

### 5.2 Decoding, and exact timestamps

- `decodeAudioData` on the appended WebM decodes completely: 150 s and 130 s of audio, at 16 kHz.
  On fragmented MP4 it stops after the first fragment (0.95 s), and it drops timestamps. So it is
  no good for production.
- **WebCodecs `AudioDecoder` on demuxed frames works for both formats.**
  - VOD Opus: 6000 frames from 590.001 s to 709.981 s, continuous apart from one 6.5 ms step at
    the start (Opus pre-skip).
  - Live AAC (`mp4a.40.2`, 44.1 kHz, 2 s fragments, init repeated in each fragment): 3906 frames,
    2807–2897 s.
  - The frame timestamps come from the WebM cluster timecode or the MP4 `tfdt`. They are on the
    same timeline as `video.currentTime`: playhead 600.0 s, first cluster at 590.001 s.
- The decoded audio is the stream itself. Recognizing it gave the same sentences the app's
  process tap produced for this video (player-test10 log, same passage), for example
  たちつてとあかさたななにぬねの… and あと頭の中で….

### 5.3 Ads

Three different ad events were seen: a pre-roll on the VOD, a mid-roll after a seek, and two live
mid-rolls. Every ad played in **its own MediaSource**, made while `#movie_player` had
`ad-showing`, on a timeline starting at 0. Afterwards the video resumed in a new MediaSource with
its own timestamps (`mse-seek.txt`, `mse-live0.txt`, `mse-live15.txt`).

So the rule is to drop audio from SourceBuffers made while an ad shows, or attached during one.
The media time keys keep the two apart in any case. On live, an ad replaces the content, and the
stream resumes at its live edge (YouTube's behaviour, not ours). The DVR hold-behind must then be
put back.

### 5.4 Seeking

The run seeked to 1500 s (unbuffered), which triggered a 10 s ad. When the video resumed, its new
SourceBuffer already held 1490–1520 s, **19.5 s ahead of the playhead**, and that grew to
119.7 s. A burst of 20 s of audio is recognized in well under a second (§5.7), so after a seek
the Japanese is ready almost at once. The first line's English needs one translation, ~2.5 s
(§10, decision 2).

### 5.5 YouTube's auto-dub

Not signed in, YouTube chose the English auto-dub, and the first decode was English. The spike
then applied the app's existing rule (switch to the track whose id ends in `.4`). YouTube rebuilt
the player with a new MediaSource for the original track. The hook must follow the newest content
SourceBuffer (or init segment), as the spike does.

### 5.6 Live: holding the player behind live

`movie_player.seekTo(getProgressState().seekableEnd − D, true)` (YouTube's DVR scrubber), run at
start. The media element's own `seekable` range is useless on YouTube live (it reported an
hour-long future window).

| D asked | Behind live, steady (min–max) | Audio ahead, steady (min–max) | Duration | Log |
|---|---|---|---|---|
| 15 s | 15.2–16.9 s | 17.2–18.6 s | 75 s until an ad | `mse-live15.txt` |
| 20 s | 18.0–22.3 s | 20.9–24.0 s | 66 s | `mse-live20.txt` |

There was no catch-up toward the live edge, the player stayed at normal speed, and the "behind"
figure only jitters with YouTube's 2 s segments. After the seek, the buffer refilled within one
2 s report (5.3 s, then 17 s ahead). Left at the live edge, the same stream keeps only 2.2–3.0 s
ahead (`mse-live0.txt`), so live does need the hold-behind. The live audio was recognized cleanly
(19 chunks, plain weather-report Japanese).

### 5.7 Per-character times from the recognizer

`kk-spike-timing` cuts a file exactly like `LivePipeline` (Silero VAD, 6 s cap). It recognizes
each chunk twice: once with today's `SpeechTranscriber.Preset.transcription`, and once with the
same preset plus `.audioTimeRange`.

**The text is identical, and so is the speed:** 28/28 chunks (VOD), 19/19 (live), 8/8 (synthetic).
Recognition takes 2.30 vs 2.29 s for 28 chunks. **Granularity: one character per run** (457 runs,
459 characters; the only multi-character run is a number such as " 50"). Times are on a 60 ms
grid. No run starts before the previous one.

Accuracy:

- **Synthetic speech with known word times** (`make_truth.py`: 70 words spoken by macOS `say`,
  trimmed and joined into sentences; `timing-truth.txt`):

  | | Median error | Median \|error\| | p90 \|error\| | Max |
  |---|---|---|---|---|
  | Word start (raw) | −62 ms | 82 ms | 231 ms | 296 ms |
  | Word start (refined, below) | −42 ms | 61 ms | 236 ms | 296 ms |
  | Word end | −6 ms | 42 ms | 99 ms | 147 ms |

- **Real stream audio** (no ground truth; sound onsets after pauses ≥ 150 ms, from 10 ms energy
  frames; `timing-vod2.txt`, `timing-live20.txt`):

  | | VOD median \|err\| | VOD p90 | Live median \|err\| | Live p90 |
  |---|---|---|---|---|
  | Run start vs onset after a pause (raw) | 100 ms | 270 ms | 130 ms | 430 ms |
  | Same, refined | **10 ms** | **190 ms** | **50 ms** | **210 ms** |
  | First character vs first sound of the chunk, refined | 40 ms | 760 ms¹ | 10 ms | 230 ms |

  ¹ The VOD's tail comes from chunks that open with laughter or music, which the energy measure
  counts as sound before the first word.

- **The one systematic flaw:** the character after a pause often gets the pause as well. For
  example 、[1.08–1.32] あ[1.32–2.10] い[2.10–2.22], where あ is really spoken at about 1.9 s.
  Revealed at its start, such a character appears up to ~0.7 s early. **Fix ("refined"):** for a
  run longer than 240 ms, start it at its first 30 ms of sound in the chunk's own audio (energy
  above the chunk's 15th percentile + 12 dB). That is cheap, deterministic, and runs before the
  line is shown, so the reveal stays final.
- **Verdict:** good enough for a character-by-character reveal. Typical error is under 100 ms,
  and 1 in 10 characters lands 0.2–0.25 s off. For the eye, a smooth 40 ms fade per character
  hides most of that. Listen for yourself: `Experiments/timing/karaoke.py` builds a page with the
  audio and the reveal (raw vs refined, adjustable offset). Pages built from the spike audio are
  in `Experiments/out/` (git-ignored).

### 5.8 One WebKit GPU process per app

`kk-spike-gpu`: two muted web views in one process, one on the default data store and one on a
separate non-persistent store, both playing. WebKit started **one** `com.apple.WebKit.GPU`
process, one Networking process and four WebContent processes for both (`gpu-process.txt`). Media
plays in the GPU process, so approach B needs a separate helper app with its own UI process.

### 5.9 Not spiked, and why

- **Muting the helper's tap while the main player stays audible (B).** This needs sound to be
  played and the System Audio Recording permission, so it should run with you present. It no
  longer decides anything: the semantics are per process object (`CATapDescription(processes:)` +
  `.muted` mutes only the tapped processes), and B loses on other grounds.
- **Sign-in sharing in a helper (B).** Same reason. Separate data stores by bundle id (§3B).
- **Signed-in and Premium playback.** Same player and MSE path. Premium may serve other audio
  itags (still Opus or AAC); to check during implementation.
- **Live streams with DVR turned off, Premieres, low-latency live.** To check. Without DVR, A falls
  back to today's mode.
- **Bluetooth output latency.** `currentTime` should already include AVFoundation's output
  compensation; a small user offset (±ms) covers the rest. To check with AirPods.
- **Twitch.** Its player also uses MSE, so A's hook should see its audio. Twitch live has no DVR,
  so it would stay in today's mode; Twitch VODs could sync.

## 6. Lead budget (does English make it in time?)

A chunk [s, e] (e − s ≤ 6 s) is ready when its bytes have arrived (buffered end ≥ e + 0.5 s for
the closing pause) and recognition and translation are done. Slack before the playhead reaches s:

- **VOD**, buffer ≥ 15 s ahead (worst moment measured):
  slack ≥ 15 − 6 − 0.5 − 0.2 − translation = **5.8 s at 2.5 s translation, 3.3 s at 5 s**.
- **Live**, buffer ≈ D + 3 s ahead (measured):

  | D | Slack, translation 2.5 s | Slack, translation 5 s |
  |---|---|---|
  | 8 s (the starting idea's figure) | 1.8 s | −0.7 s: late lines |
  | **12 s (recommended default)** | **5.8 s** | **3.3 s** |
  | 15 s | 8.8 s | 6.3 s |

  So D ≈ 12 s, raised automatically if lines ever arrive late (the app can measure slack per line).
- **Start of playback and after a seek:** the buffer holds the first 20 s at once, so Japanese is
  ready within about 0.5 s. The first line's English needs one translation (~2.5 s). See decision
  2 in §10.

## 7. Costs

| | A: own buffer | B: hidden player |
|---|---|---|
| Bandwidth | none extra | a second stream: audio (~130 kb/s) plus the lowest video quality |
| CPU | Opus/AAC decode (negligible), recognition of the same audio, just earlier | a second page, decoder and process tap |
| Claude cost | same per minute watched. Work up to a horizon (e.g. 30 s ahead), not the whole 120 s buffer, and cancel work the viewer seeks away from, so seeking doesn't pay for unwatched minutes | same, plus drift re-seeks |
| Complexity | medium: one page script (hook, two small demuxers, decoder), a media-time capture, pipeline in media time, page-side reveal | high: everything in A's pipeline and reveal parts, plus a helper app target, IPC, cookie sync, lead control through ads, clock mapping, a muted process tap |
| Live vs VOD | VOD free; live needs D ≈ 12 s behind live | same |
| Breakage risk | YouTube moving MSE into a Worker; encrypting the audio (then today's mode) | YouTube detecting or limiting a second player; ad desync |
| Terms of service | Reads bytes the official player already fetched for this playback, in memory, never stored, no extra requests, ads untouched. Like today's process tap, this uses the content outside the player's own UI, so it is not zero risk | A full second, hidden playback including ads nobody watches. That inflates views and ad impressions. YouTube's terms forbid causing "inaccurate measurements of genuine user engagement". The bigger concern of the two |

This is an engineering assessment, not legal advice.

## 8. Ranking

1. **A, the player's own buffer, with a DVR hold-behind for live.** Exact timestamps, no extra
   traffic, one player, no audio permission needed for Watch, the existing pipeline unchanged.
2. **B, the hidden look-ahead player.** Feasible but strictly worse: helper app, twice the
   streaming, hidden ad impressions, sign-in copying, drift, ±100 ms mapping.
3. **C, delayed re-presentation.** Rejected: picture quality, interaction, complexity.
4. **D, time-shift alone.** Does not give a lead.

## 9. Implementation plan for A

**Phase 1: page media tap** (new `Sources/Kikitori/Player/MediaTapScript.swift`)
- Inject at `.atDocumentStart` in the page world, before YouTube's scripts. The spike's `Hook.swift`
  is the starting point.
- Wrap `addSourceBuffer`/`appendBuffer` and always call the originals. Tag each SourceBuffer with
  its MediaSource, the video id, and whether it was made or attached during an ad. Record
  `timestampOffset`.
- Incremental demuxers (appends split frames and clusters arbitrarily):
  - WebM: EBML header, Tracks/CodecPrivate, Cluster Timecode, SimpleBlock/BlockGroup;
  - fMP4: mdhd timescale, esds AudioSpecificConfig, tfhd/trex defaults, tfdt, trun, mdat.
- `AudioDecoder` (opus, mp4a.40.2), downmix to mono, send Int16 at the decoder's rate with the
  first frame's media time (`kkMedia`, ~100 KB/s).
- Resample natively (stateful `AVAudioConverter`, no clicks at packet edges). Reconfigure on a new
  init segment (track switch).

**Phase 2: media-time capture** (new `Sources/KikitoriCore/Audio/MediaTimelineCapture.swift`)
- Keep contiguous ranges per video id. Feed the pipeline the range containing the playhead, from
  the playhead on, up to a horizon (30 s ahead).
- A seek outside the processed range starts a new range and drops queued work behind the
  playhead. Ads never enter.
- `PlayerScript`'s `kkState` gains a precise `t` (it has it) for the horizon. The reveal itself
  stays in the page.

**Phase 3: pipeline in media time** (`LivePipeline`, `AppleSpeechEngine`)
- `Chunk.start` + range base = media time.
- `AppleSpeechEngine` returns its characters with `audioTimeRange` (same preset plus the
  attribute; text identical, spiked).
- Refine long runs to their sound onset (§5.7), using the chunk's own samples.
- Align the translator's lines (its `ja`, which may be corrected) to recognizer characters
  (character diff), so each English line gets a start character.
- New event: a timed cue `{videoID, chars: [(text, start, end)], lines: [{fromChar, toChar, en}]}`.
- Today's events stay for the tap path.

**Phase 4: page reveal** (`PlayerScript`)
- `__kikitori.cues(add)`: cues are immutable once sent, so nothing can be rewritten.
- A `requestAnimationFrame` loop on `video.currentTime`: reveal each character at its time with a
  short fade, show the English line under it from its first character, clear after a pause (as
  today's 8 s rule).
- Re-render from cues on seek. DOM calls only (Trusted Types).
- The Translation panel and the Live tab add a line when the playhead reaches it, not when it was
  processed, so nothing shows ahead of the video.

**Phase 5: live**
- Detect live (`getVideoData().isLive` or `.ytp-live`) and place the player D behind with
  `seekTo(seekableEnd − D)`. Default D = 12 s, raised if slack runs low.
- Reapply after a live ad resumes at the edge. If the viewer jumps to live, show
  "Not synced — Sync (12 s behind)".
- No DVR (seekable window < D): today's mode.

**Phase 6: fallbacks and status**
- No MSE audio within a few seconds of playback (another site, encrypted media, Twitch live):
  `DeferredTapCapture` as today.
- Toolbar status "Synced" / "Preparing…" / "Not synced: <reason>".
- `--player-test` logs the lead and, per character, reveal time vs cue time.

**Tests**
- Demuxer fixtures made from TTS audio with ffmpeg (WebM/Opus, fragmented MP4/AAC, split at odd
  byte offsets).
- Onset refinement against `make_truth.py` data.
- Line-to-character alignment.
- Range, horizon and seek logic on a fake timeline.
- Cue immutability in the page harness.

**Done when:**
- On the test VOD, every character's reveal is within one frame of its cue time.
- After the first line following a start or seek, ≥ 99 % of lines have their English at their
  first character.
- Live with D = 12 s for 30 min: ≥ 99 % of lines are ready before they start.
- No cue text changes after it is first drawn.

## 10. Decisions for you

1. **Is reading the player's own buffered audio acceptable** under your "no direct download"
   rule? It makes no extra requests, the bytes come from the official player's own playback, and
   nothing is stored. If not, B is the only way to get a lead, with the costs in §7.
2. **Start and seek:** hold the video paused up to ~3 s until the first line's English is ready
   ("Preparing subtitles…"), or play at once and show Japanese first for that one line? The
   Japanese is ready within ~0.5 s either way.
3. **Live delay:** is D = 12 s behind live acceptable, with YouTube's live chat (beside the video)
   running 12 s ahead of the picture? Any delay-based approach has this.
4. **No lead available** (live without DVR, viewer jumps to live): fall back to today's live line,
   or show nothing on the video?

## Reproducing

```bash
swift run kk-spike-mse "https://www.youtube.com/watch?v=kLFsqvruEFs&t=600s" 60 /tmp/kk/vod
swift run kk-spike-mse "https://www.youtube.com/watch?v=kLFsqvruEFs&t=600s" 130 /tmp/kk/seek --seek 1500@14
swift run kk-spike-mse "https://www.youtube.com/@weathernews/live" 70 /tmp/kk/live --behind 12
swift run kk-spike-timing /tmp/kk/vod.wav --json /tmp/kk/vod.json
python3 Experiments/timing/make_truth.py /tmp/kk/truth && swift run kk-spike-timing /tmp/kk/truth/truth.wav --truth /tmp/kk/truth/truth.json
python3 Experiments/timing/karaoke.py /tmp/kk/vod.json /tmp/kk/vod.wav /tmp/kk/reveal.html
swift run kk-spike-gpu
```

The MSE spike opens a small muted window. Nothing plays aloud.
