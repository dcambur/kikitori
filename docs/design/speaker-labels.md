# Speaker labels in collabs

Status: **built, behind a setting (off by default)**, 2026-10-24. Settings › Audio › Speech
detection › "Label speakers in collabs". Measured on a real collab and on a spliced collab
with known turns (§6). The scripts are in `Experiments/speakers/`.

## In short

Each transcript line now says who said it: a letter (**A**–**D**) in that speaker's colour, or a
name once one is given. In the transcript, the floating overlay and the built-in player's
subtitles (synced and unsynced).

- **Who speaks when** comes from FluidAudio's streaming **Sortformer** diarizer (Core ML, on the
  Neural Engine). It runs beside the chunker on the same audio and keeps four speaker slots
  for the whole session, so a voice keeps its letter from the first line to the last.
- **Which characters are whose** comes from Apple's per-character times
  (`transcribeTimed`, the same recognition with `.audioTimeRange`). Each character gets the
  speaker most active while it was said; a chunk is split into turns where the voice changes.
- **Names:** right-click a line › Speaker › "This Is Pekora" (a profile) or "Name for This
  Session…". With a profile, the newest ~15 s where only that voice spoke is saved as the
  profile's voice sample; the next session with that profile puts the voice in its slot first,
  so its lines carry the name from the start.
- **Cost:** the diarizer is busy ~5 % of real time, mostly on the Neural Engine; it adds
  ~0.15 s per chunk (median) to when Japanese lines appear (§5).

## 1. What was there

`TranscriptLine.speaker`, the speaker chip in `TranscriptRow`, the export's "Speaker labels"
switch and the spec's speaker colours (§2 `speakerA…D`, §5.2, §5.3 artboard 09) all existed;
nothing set a speaker. Two pipelines make lines: `LivePipeline` (tapped app audio, Silero VAD
chunks of ≤ 6 s) and `MediaPipeline` (the built-in player's read-ahead audio, cues revealed in
video time). The translator already split a chunk into lines at turn boundaries, told not to
label speakers.

## 2. Decision: one streaming tracker for the session, not diarization per chunk

| | Per-chunk diarization | Streaming tracker (chosen) |
|---|---|---|
| Model | pyannote segmentation + WeSpeaker embeddings (`DiarizerManager`) on each chunk, then clustering embeddings across chunks to keep IDs | Sortformer streaming (`SortformerDiarizer`): 80 ms frames, 4 slots, a speaker cache that carries identities forward |
| Context | 1–6 s per chunk: little to embed, short utterances are its documented weak spot | the whole session (cache of 188 frames of past speech per slot) |
| Stable IDs | needs our own clustering and its threshold; IDs can drift or split | built in: slots are numbered by first appearance and stay |
| Noise, BGM, game sound | FluidAudio's notes: "struggles with background noise" | its stated strength |
| Latency | after the chunk (no waiting on later audio) | a frame settles ~1 s after it is heard (0.48 s steps + 0.56 s look-ahead); in practice it is already settled by the time recognition ends (§5) |
| Limits | none on count | 4 speakers; a 5th is merged into a slot or missed |

Streaming wins: chunks are too short to identify a voice on their own, and stable letters across
the session are the whole point. Four slots covers the usual collab (2–4 people); big events
with 5+ voices will mix two of them (stated in the setting's spirit: "best effort"). LS-EEND
(also in FluidAudio, up to 10 speakers) was not chosen: by FluidAudio's own comparison it has
more false alarms and weaker identity stability and enrollment, and Sortformer worked on the
first real clip.

The tracker (`SpeakerTracker`) is fed the same audio as the chunker, in its own task so a
diarizer run never delays chunking. It keeps the settled frames (10 minutes), maps the caller's
clock to its own (audio can arrive in stretches: seeks in the player, pauses), and answers
`frames(from:to:)` once those frames have settled, waiting at most 2 s (then it uses the
diarizer's tentative frames). It is created at session start and kept until the session ends,
so pause/resume keeps the letters; it skips all-zero input (the tap is muted while the player
shows synced subtitles), and in the player it is reset when the video changes. The model
(~234 MB, downloaded once from Hugging Face like Silero) loads in the background
(`DeferredSpeakerTracker`): starting a session is not delayed, and lines are unlabelled until it
is ready (a few seconds; the first time, the download).

## 3. Decision: splitting a chunk's lines between speakers

All in `SpeakerLabeler` (pure functions, unit-tested) and `Spoken`:

1. **Characters → speakers.** For each recognized piece (Apple gives one per character, times
   on a 60 ms grid, onset-refined as for synced subtitles), average each slot's probability over
   the frames that overlap it **and contain speech** (some slot ≥ 0.5); the highest wins.
   Scoring speech frames only matters: the character after a pause absorbs the pause, and
   averaging the silence in would let noise pick the speaker. A piece with no speech frames
   (punctuation, a pause) takes the speaker before it, else after it. Overlapping speech goes
   to the more confident voice.
2. **Turns.** Runs of one speaker; any run shorter than 0.5 s (first character's start to last
   one's end) joins a neighbour: the one on both sides if they agree, else the longer. This
   absorbs a misread frame or a one-syllable blip without inventing a line.
3. **Untranslated (the default):** one line per turn. All lines of a chunk share its time.
4. **Translated:** the translator gets the chunk with **one turn per line** (a line break
   where the voice changes) and one added sentence in its prompt: a line break marks a voice
   change, start a new line there. Its lines are placed back on the characters with the existing
   `CueAligner` (edit-distance alignment of its corrected Japanese), and each line takes the
   speaker who said most of its characters (by time). So a line that does straddle a change is
   still labelled sensibly.
5. **Synced cues** (`MediaPipeline`) use the same steps; `Cue.Line.speaker` carries the label to
   the transcript (`revealed`) and to the page.

## 4. Names and voices

- Labels are letters by slot: Sortformer numbers slots in order of first speech, so **A** is
  usually whoever talks first. `TranscriptLine.speaker` stores the letter; the session keeps
  `speakerNames` (`"A" → "Pekora"`), so naming a voice relabels all its lines, past and future.
  Export writes names (or "Speaker A").
- **"This voice is Fubuki" once:** Speaker › This Is ‹profile› names the letter for the session
  and saves a voice sample to the profile: the newest ≤ 15 s of frames where that slot alone
  was confidently speaking (> 0.8, all others < 0.2), so another voice in the same chunk never
  pollutes it; at least 3 s is needed. It is stored on this Mac only
  (`voices/<profile id>.f32` next to `profiles.json`, not in exported profile files); the
  profile editor shows it and can forget it.
- **Next session:** the active profile's sample is enrolled before any audio
  (`SortformerDiarizer.enrollSpeaker`): it takes a slot and its name. Only the active profile
  (the channel you're watching) is enrolled, because enrolled voices occupy slots: enrolling
  guests who may not be there would leave fewer of the four slots for the people who are.
  Measured in §6.3.

## 5. Latency and cost

TODO

## 6. Evidence

TODO

## 7. Where the code is

| File | What |
|---|---|
| `Sources/KikitoriCore/Speakers/SpeakerTracker.swift` | `SpeakerTracking`, `SpeakerTracker` (Sortformer), `DeferredSpeakerTracker` |
| `Sources/KikitoriCore/Speakers/SpeakerLabeler.swift` | frames → characters → turns → line speaker |
| `Sources/KikitoriCore/Speakers/Spoken.swift` | a chunk's turns as lines, translator input, cue lines |
| `LivePipeline`, `MediaPipeline` | `speakers` property; feeding the tracker; timed recognition when on |
| `LiveTranslator` | one sentence about line breaks in the prompt |
| `AppModel` | trackers per session, lines per turn, names, voice samples |
| `TranscriptRow` (`SpeakerChip`, `SpeakerMenu`), `OverlayView`, `PlayerScript`/`PlayerController`, `ProfilesView`, `SettingsView` | UI |
| `kikitori-cli speakers` | headless runs: turns, wait per chunk, diarizer time; `--json` for scoring; `--enroll` |
| `Experiments/speakers/splice.py`, `score.py` | spliced collab with known turns; scoring |

## 8. Limits and follow-ups

TODO
