# kikitori 聞き取り

Live English subtitles for Japanese VTuber streams on your Mac, with the context behind the jokes.

kikitori listens to the one app playing the stream (Safari, Chrome, Firefox, the YouTube app…),
recognises the Japanese speech on-device, and translates it with Claude into subtitles that float
over the video. Click a line marked 注 to learn the slang, meme or reference behind it.

- **Hears only the stream:** per-app capture with a Core Audio process tap. No virtual audio
  driver; other apps, notifications and your voice are ignored. A microphone works too.
- **Transcribes on your Mac:** Apple's on-device Japanese speech model, cut at natural pauses by
  Silero VAD on the Neural Engine. Audio never leaves the Mac.
- **Translates with Claude:** Claude Haiku 5.5 writes the live lines (≈ $0.04–0.15 per stream
  hour), Claude Sonnet 5.5 explains a line on demand. Streamer profiles teach it names, fan names
  and running jokes.
- **Honest about delay and money:** subtitles land about 2.5–4 s after a sentence ends; spend is
  tracked against your monthly budget, with a cap that falls back to Japanese only.

## Requirements

- macOS 26 or later, Apple Silicon
- A Claude API key. Claude Max plans include monthly API credits: claim them in the
  [Claude Console](https://console.anthropic.com) and create a key there.

## Build and run

```bash
swift test                      # core tests
scripts/bundle.sh               # builds build/Kikitori.app (release, ad-hoc signed)
open build/Kikitori.app
```

On first launch, setup asks for the System Audio Recording permission and your API key (stored
in the macOS Keychain). Headless tools:

```bash
swift run kikitori-cli sources                          # apps that are playing sound
swift run kikitori-cli run some-stream.wav --realtime   # the whole pipeline on a file
swift run Kikitori --snapshots /tmp/kk                  # render every screen to PNGs (sample data)
```

## How it works

```
app audio ──process tap──▶ 16 kHz mono ──Silero VAD──▶ speech chunks (≤ 6 s, cut at pauses)
   ──Apple SpeechTranscriber──▶ Japanese ──filter──▶ Claude Haiku 5.5 ──▶ overlay + transcript
                                                                 └─ Claude Sonnet 5.5 on “Explain”
```

| Path | What |
|---|---|
| `Sources/KikitoriCore` | Capture, VAD chunker, speech engine, Claude client and translator, usage ledger, storage, export. Tested in `Tests/`. |
| `Sources/Kikitori` | The SwiftUI app: main window, floating overlay (`NSPanel`), menu bar, settings, onboarding. |
| `Sources/kikitori-cli` | Headless checks of the pipeline. |
| `Experiments` | Spikes and checks behind `docs/design/realtime-sync.md` (synced subtitles); not part of the app. |
| `docs/design` | The approved design: every screen and state, plus the implementation spec (`spec.md`). |
| `bench` | The speech-model benchmark behind the engine choice. |

### Why Apple's speech model

`bench/` compares Whisper large-v3, large-v3-turbo (MLX, whisper.cpp, WhisperKit), kotoba-whisper,
anime-whisper, ReazonSpeech-k2, Parakeet, Nemotron, Cohere Transcribe and Apple SpeechTranscriber,
on public Japanese test sets and on 13 hololive clips with human captions. On real stream audio
Apple's model ties Whisper turbo in the full pipeline (38.8 % vs 39.0 % character error, scored
against edited captions) while running about 3× faster with no download; large-v3 adds nothing
over turbo, and the transducer models drop fast reactions. Details: [bench/README.md](bench/README.md).

### Synced subtitles in the built-in player

On YouTube videos in Watch, subtitles appear character by character as each is spoken. The site's
player downloads its audio ahead of playback; kikitori decodes that already-buffered audio (no
extra requests, nothing stored) and runs the same recognizer and translator 15–120 s early. Live
streams still use the subtitles above. Design and measurements: `docs/design/realtime-sync.md`.

## Privacy

Sent to Anthropic: the Japanese text of each chunk, the streamer profile, the stream title, and
for Explain the line with its neighbours. Never sent: audio, your screen, past sessions. There is
no kikitori server. Transcripts, profiles and usage stay in `~/Library/Application Support/kikitori`.
Audio is never saved: so you can hear a line again, the last half hour or so of speech stays in
memory during a session and is dropped when it stops. In Watch, the page also keeps the last few
minutes of the video's own buffered audio (what the site's player already downloaded) in memory,
so synced subtitles can start from it; it goes with the page. A voice remembered for speaker
labels is kept as a voiceprint (256 numbers that describe the voice), not as audio. The stream title (for the built-in
player, the video's title and channel) is sent as context.

## Status

Version 0.1: every screen of the design exists, and the app has been tested live: it captured a
stream playing in Firefox, with subtitles about 2.5–3 s behind the speaker (≈ $0.0036 per minute of
talk). Not yet done: a stable signing identity (ad-hoc builds re-ask for the audio permission
after each rebuild), Whisper turbo as an optional engine, speaker labels for collabs.

## License

MIT. See [LICENSE](LICENSE).
