# Built-in player: plan and status

The user prefers watching in kikitori's own player over the floating overlay: subtitles on
the video itself, no system-audio permission, and (phase 2) subtitles exactly in sync.

## Phase 1: done (commit after 401b521), not yet tried on a real page

- `Sources/Kikitori/Player/PlayerController.swift`: one `WKWebView` (persistent data store,
  Safari user agent, autoplay allowed) loading the real site; message handlers `kkAudio`,
  `kkState`, `kkExplain`; pushes the latest lines into the page with `__kikitori.show`.
- `Sources/Kikitori/Player/PlayerScript.swift`: injected into the page world. Web Audio taps
  the `<video>` (ScriptProcessor → mono → 16 kHz → base64 Int16, ~100 ms packets with the
  video time), reports state every 500 ms, draws `#kikitori-subs` inside `#movie_player`.
- `Sources/KikitoriCore/Audio/PageAudioCapture.swift`: the packets as an `AudioCapture`.
- `PlayerView` (Watch window, ⇧⌘W): address bar, subtitle mode picker, Subtitles toggle that
  starts a session with source id `kikitori.player`. The floating overlay hides for that source.
- Subtitle modes (`Preferences.SubtitleMode`, default `japaneseMain`: Japanese large, English
  small below; overlay and player both use it). Overlay default is now 1 line.

Check on first real use: ScriptProcessor fires in WKWebView, `createMediaElementSource` works on
YouTube's MSE video, the AudioContext resumes after the user's play click, the layer survives
YouTube's SPA navigation, theatre mode and full screen; Google sign-in inside the web view.

## Phase 2: exact sync (next)

Subtitles can't appear before a sentence ends because the engine needs the whole sentence.
Fix: listen ahead of what the user watches.

1. A second, hidden `WKWebView` (offscreen window so the page isn't throttled) loads the same
   video at the lowest quality, script with `hear: false` (audio never reaches the speakers),
   kept `lead` ≈ 10 s ahead of the visible player (seek, then nudge `playbackRate` 1.0–1.05).
2. Stamp lines with video time: the hidden player's packets carry `t`, so a chunk's start sample
   maps to a video time. Split a chunk's lines across its span by character share (or use
   SpeechTranscriber word time ranges).
3. The visible player shows a line while `currentTime ∈ [start, end]` (drive from `kkState`,
   or better a `requestAnimationFrame` loop in the page given the timed lines).
4. Seek/pause: hidden player follows (seek to new time + lead); after a seek there is ~lead
   seconds of warm-up where lines come late (show them as soon as they arrive).
5. Live: YouTube live has DVR, so put the visible player `lead` behind the live edge
   (`movie_player.seekTo`) while the hidden one stays at the edge. Twitch live has no DVR:
   no lookahead, keep today's behaviour (~2.5 s behind).
6. The pipeline needs line times in video time instead of session time: carry the chunk's video
   time through `LivePipeline` events (Chunk.start is sample-based; add a mapping from the
   capture's sample count to video time).

Cost is unchanged (audio is processed once); extra bandwidth is a low-quality second stream.
