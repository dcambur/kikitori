# Speech-to-text benchmark

Which on-device Japanese speech model kikitori should use, measured on an M4 Pro (24 GB, macOS 27)
on 2026-10-22, while a browser was playing video (the real use case).

## Verdict (real VTuber streams)

**Default engine: Apple SpeechTranscriber.** In the full pipeline it ties Whisper turbo (38.8 % vs
39.0 % CER), needs no download, runs ~3× faster and stays on the Neural Engine. **Optional "Best"
engine: Whisper large-v3-turbo** (~2 points better on cleanly cut segments). Large-v3 is no better
than turbo (24.4 % vs 24.6 %), invents more and is slower. Pipeline: Silero VAD cuts, 6 s cap, no
vocal isolation, no Whisper prompt (names go to the translator's glossary instead).

### Real streams: 13 hololive clips with human captions (288 segments, ~54 min)

`vtcc.py`. Captions are edited by clip channels (fillers dropped, some rephrasing), so absolute CER
is inflated for every engine; compare rows. "Oracle" = each caption group cut out exactly (engine
accuracy); pipeline rows = the whole 5 min cut by the chunker, joined and scored against all
captions (also counts uncaptioned side chatter as insertions).

| engine (oracle segments) | CER | ×RT | | pipeline (Whisper = whisper.cpp beam 5) | Apple | Whisper |
|---|---|---|---|---|---|---|
| Whisper large-v3 (MLX) | 24.4 % | 6× | | fixed 15 s windows | 38.3 % | 42.7 % |
| Whisper turbo (MLX) | 24.6 % | 10× | | Silero VAD, max 15 s | 38.8 % | 39.0 % |
| Whisper turbo (whisper.cpp, beam 5) | 25.3 % | 15× | | Silero VAD, max 6 s | 39.4 % | 39.2 % |
| Apple SpeechTranscriber | 26.6 % | 23× | | VAD 15 s + Demucs vocals | 38.8 % | 39.4 % |
| WhisperKit turbo (Core ML)¹ | 27.0 % | 8× | | | | |
| anime-whisper | 29.8 % | 19× | | | | |
| kotoba-whisper v2 / Parakeet-ja / Nemotron-ja | 33.6–33.7 % | 19–124× | | | | |
| Cohere Transcribe (ja) | 35.7 % | 7× | | | | |
| ReazonSpeech-k2 | 40.0 % | 113× | | | | |

Options on Whisper turbo, oracle segments: previous-chunk prompt 24.9 % (no gain), glossary prompt
27.1 % (worse: Whisper copies prompt names into its output), Demucs vocals +0.6–0.9 points on
every engine (worse). ¹ only with `firstTokenLogProbThreshold: nil`; its default drops screams.

Transducer models trained on ReazonSpeech (k2, Parakeet, kotoba-style captions) drop fast
reactions and second speakers, which is most of what makes VTuber streams VTuber streams.

## Synthetic set (public test sets)

| engine | reazon | cv | turns2 | overlap2 | noisy | halluc | ×RT | peak GB |
|---|---|---|---|---|---|---|---|---|
| **Whisper large-v3-turbo** (MLX, GPU) | 9.7% | 3.7% | 12.4% | 29.3% | 19.5% | 100% | 13× | 2.5 |
| **Apple SpeechTranscriber** (ANE) | 16.0% | 3.3% | 11.9% | 29.7% | 25.5% | 30%¹ | 56× | system |
| kotoba-whisper v2.0 (MLX) | 7.6%² | 3.8% | 19.9% | 26.5% | 15.1% | 100% | 16× | 2.4 |
| Whisper large-v3 (MLX) | 12.2% | 3.5% | 10.1% | 26.7% | 24.8% | 100% | 8× | 4.0 |

CER on kana readings (lower is better); ×RT = times faster than real time. ¹ Apple only emitted
「あ」 on 3 of 10 silent clips; every Whisper model invented a full sentence on all of them
(turbo/large-v3: 「ご視聴ありがとうございました」, kotoba: 「ごめん」).

On this first, synthetic set turbo looked clearly ahead of Apple (pink noise is a poor stand-in
for stream audio); the real-stream set above reversed that into a tie. More engines on this set
(whisper.cpp, WhisperKit, Parakeet, Cohere, Nemotron, k2): `results/summary.md`.

² kotoba was trained on ReazonSpeech, and ReazonSpeech references cover only the main caption,
not side speech or reactions in the same clip. kotoba learned to leave those out: its output on
the two-speaker set is 13% shorter than the reference, and it drops lines like 「怖っ!うわっ!」.
That scores well here and is exactly wrong for streams. The same quirk penalises turbo and Apple
on `reazon`, so their real accuracy is better than the column says.

## What this means for the pipeline

- **Any number of speakers works without diarization** as long as people take turns (`turns2` ≈
  single-speaker accuracy). Simultaneous speech loses about a third of the quieter voice on every
  engine, so the engine choice cannot fix it; collab overlap is mostly short reactions.
- **A voice-activity gate is mandatory**: no Whisper guard stops the silence hallucinations.
  Add a known-phrase filter and repetition collapse behind it.
- Cut chunks at pauses (max ~15 s) and pass the streamer glossary as context (Whisper prompt,
  Apple contextual strings) for names.
- Pink noise at 5 dB SNR is a harsh stand-in for BGM; check on real stream audio.

## Sets

`prepare.py` builds 360 clips (39 min) from public test sets: `reazon` 150 natural TV utterances
(ReazonSpeech test), `cv` 100 read utterances (Common Voice 8), `turns2` 30 two-speaker
back-to-back, `overlap2` 30 two speakers overlapping by half, `noisy` 40 under pink noise at
5 dB, `silence` 10 near-silent or noise-only clips.

## Run

```bash
uv run python prepare.py
uv run python run_mlx.py mlx-community/whisper-large-v3-turbo whisper-turbo
swiftc -parse-as-library -O swift/apple_speech.swift -o swift/apple_speech
./swift/apple_speech data/samples/manifest.jsonl results/raw/apple-speech.jsonl
uv run python score.py
```
