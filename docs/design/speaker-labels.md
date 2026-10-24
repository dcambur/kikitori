# Speaker labels in collabs

Status: **built, behind a setting (off by default)**, 2026-10-24. Settings › Audio › Speech
detection › "Label speakers in collabs". Measured on a real collab and on spliced collabs with
known turns (§6). The scripts are in `Experiments/speakers/`. Remembered voices are kept as
voiceprints, never audio (§4, decided after the code review).

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
- **Names:** right-click a line › Speaker › "This Is Pekora" (any profile) or "Name for This
  Session…": every line of that voice, past and future, shows the name. "Remember This Voice"
  keeps a **voiceprint** (a WeSpeaker speaker embedding, never audio); later sessions put the name
  on the voice that matches it, once it is clearly that person (§4).
- **Accuracy:** on two-voice splices of real stream audio, 97–98 % of lines get the right speaker
  and 66–80 % of speaker changes are found within 1 s (90–96 % of the shown ones are real). Some
  voice pairs are too alike for the model: Pekora and Marine are merged (§6).
- **Cost:** no measurable delay to lines (the diarizer's tentative answer is as good as its
  settled one, §5); about 5 % of one CPU core plus Neural Engine time, more than the Apple
  recognizer itself, hence off by default.

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
5. **Synced cues** (`MediaPipeline`) use the same steps. A cue goes out as soon as its chunk is
   recognized, already split into one Japanese line per speaker turn; when its translation comes
   (`.translation`), the translator's lines replace them, each with its majority speaker.
   `Cue.Line.speaker` carries the label to the transcript (`revealed`, `cueTranslated`) and to
   the page.

## 4. Names and voices

- Labels are letters by slot: Sortformer numbers slots in order of first speech, so **A** is
  usually whoever talks first. `TranscriptLine.speaker` stores the letter; the session keeps
  `speakerNames` (`"A" → "Pekora"`), so naming a voice relabels all its lines, past and future,
  in the transcript, the overlay and the player. Export writes names (or "Speaker A").
- **Naming in a session** is reliable: it relies only on the slot staying the same, which it did
  in every run (with the same input the labels are identical run to run).
- **Remembering a voice across sessions** (Speaker › Remember This Voice › As ‹profile›) keeps a
  **voiceprint, never audio**: FluidAudio's WeSpeaker model (`DiarizerManager.extractSpeakerEmbedding`,
  ~22 MB, Neural Engine) turns the newest ≤ 15 s where that voice alone was confidently speaking
  (> 0.8, all others < 0.2, held in memory by the tracker) into 256 numbers (10 s pieces,
  averaged). Saved as `voices/<profile id>.json` with the model's id (name + a hash of its files):
  a print from another model is never compared. Stored on this Mac only, not in exported
  profiles; the profile editor shows "Voice saved" and can forget it.
- **Later sessions** don't feed it to the diarizer. Every 10 s, each voice not named yet that has
  ≥ 5 s of its own audio is printed and compared (cosine) with every profile's remembered print;
  it gets a name when it is ≥ 0.65 similar to it and ≥ 0.1 more than to any other remembered
  name, each name going to one voice at most. Its earlier lines get the name too (names belong
  to the letter). A name the user gave is never replaced.
- Why not enroll the voice into Sortformer (the first version): enrollment needs the audio itself
  (`enrollSpeaker(withAudio:)`; its streaming state can be read but not restored), and it
  changed the diarization: with a sample from another setting, Pekora's voice drifted to the
  other slot halfway through the real collab (§6.3). Matching prints names voices but never moves
  a line from one voice to another.
- Old files: before voiceprints, the voice was saved as audio (`voices/<profile>.f32`). At launch,
  each is turned into a voiceprint once and deleted; if the model can't load (offline), the audio
  is deleted anyway and the voice can be remembered again.
- It stays **experimental**: a voice is named only when it is clearly that person, so with
  another mic it may stay unnamed (§6.3), and voices too alike to tell apart (Pekora and Marine)
  can't be named apart either.

## 5. Latency and cost

**Latency.** Lines can only be labelled once the diarizer has run on their audio. Sortformer
settles a frame ~1 s after hearing it (0.48 s steps + 0.56 s look-ahead), and its tentative
answer for the newest 0.56 s is there sooner. Measured at real-time speed (`kikitori-cli speakers
--realtime`, wait = time a recognized chunk spent waiting for speaker frames):

| What the chunk waits for | Collab, 470 s, 90 chunks | Splice, 362 s, 76 chunks: accuracy |
|---|---|---|
| settled frames up to the chunk's end (first version) | median 0.52 s, p90 0.93 s | |
| settled frames up to the last character | median 0.08 s, p90 0.93 s | 96.8 % characters, 72 % changes |
| frames the diarizer has run on, settled or tentative (**shipped**, ≤ 0.5 s) | **median 0.00 s, p90 0.31 s, max 0.44 s**; 99.8 % of characters labelled as with settled frames | |
| nothing (whatever is there) | | 96.8 % characters, 72 % changes: identical |

The p90 of the settled versions is the chunks cut at the 6 s cap mid-sentence: their last second
hadn't settled. Tentative frames labelled every character the same as settled ones, so the
shipped version waits only until the diarizer has run on the chunk's last character (usually
already done when recognition finishes, ~0.1 s per chunk). In the player's synced mode the
audio is 15–120 s ahead anyway: no visible effect.

**Cost** (M4 Pro, debug build; the CLI runs the same chunker, recognizer and tracker as the app):

| | per 362 s of audio, real time | share |
|---|---|---|
| kikitori process without speaker labels (chunker, Silero VAD) | 3.4 s CPU | ~1 % of a core |
| … with speaker labels | 22.0 s CPU (alone on the collab: 28.4 s per 470 s) | 6 % of a core: +5 % |
| Sortformer wall time in `process` (CPU + Neural Engine) | 28.7 s | 8 % of real time |
| Apple's recognizer for the chunks (its XPC service, sampled over 120 s) | | ~2 % of a core |

So the diarizer costs more CPU than the speech recognizer it sits next to (the live-line
recognizer adds about as much again), and it keeps the Neural Engine busy 5–8 % of the time.
Memory: the model is ~234 MB on disk (downloaded once to
`~/Library/Application Support/FluidAudio/Models/sortformer`), and the tracker keeps 10 minutes
of frames and 30 s of audio. With the built-in player two trackers exist (tap and read-ahead);
the tap's tracker skips its input while the tap is muted for synced subtitles, so only one is busy at a time.
Off by default, as the spec already said ("Best effort. Uses more CPU.").

## 6. Evidence

### 6.1 A real collab

Pekora × Miko, "初めてお泊りコラボ" (Pekora's channel, `VtZfehdSHb4`), video time 25:00–32:50:
470 s captured with the repo's own muted MSE spike (`KK_SPIKE_LARGEST=1 kk-spike-mse`), run
through `kikitori-cli speakers`. It is a hard case: both in one room (an offline collab),
talking over each other while eating.

- Two voices found, letters stable for the whole clip; 59 of 90 chunks were split into two or
  more turns; 174 lines (A 100, B 74). Runs without enrollment agree on 99.8–100 % of characters.
- There is no human-labelled truth for it. Content check instead: lines with Pekora's own
  markers ("みこ先輩", sentence-final ぺこ, "ぺこら" for herself) are mostly on A (e.g.
  "ごめんちょっとみこ先輩", "やらねえぺこだからさ", "ぺこラはうんみこ先輩の家に"), a few on B
  ("…人もいるぺこじゃん"): A is Pekora, with some errors around fast exchanges.
- Typical output (untranslated lines, one per turn):

      [  19.2] B  あれでも今日頼むだよ
               A  やだよ。今日期待するんじゃねーよ。
      [  56.8] B  あいよ食ってうまいよ。それも。ご
               A  めんちょっとみこ先輩
               B  のあのスープパースちょっと食べるわ
               A  すまん。

  Turn boundaries can be off by a character or two ("ご|めん"): Apple's character times are on a
  60 ms grid and the frames are 80 ms.

### 6.2 Spliced collabs with known turns

For numbers, `splice.py` builds a turn-taking "collab" from solo chat streams (captured the same
way, 4–7 minutes each from 15:00): turns of 0.8–8 s alternating, half the changes with no pause,
voices levelled to the same loudness. `score.py` checks every recognized character against the
turn it was spoken in (labels matched to people by the best mapping).

| Voices (≈ 6 min each) | Characters right | Lines right | Changes found ±1 s (precision) | ±0.5 s |
|---|---|---|---|---|
| Pekora + Miko | 96.8 % | 97 % | 72 % (93 %) | 64 % (83 %) |
| Pekora + Miko, not levelled | 97.6 % | 98 % | 80 % (94 %) | 73 % (85 %) |
| Miko + Marine | 96.8 % | 99 % | 66 % (90 %) | 66 % (90 %) |
| Miko + Marine, not levelled | 96.9 % | 99 % | 74 % (94 %) | 72 % (91 %) |
| **Pekora + Marine** | **66.5 %** | 68 % | 31 % (78 %) | 28 % (70 %) |
| **Pekora + Miko + Marine** | **55.4 %** | 64 % | 40 % (96 %) | 37 % (88 %) |

- The overall figure favours the voice with more speech: Miko's clip had less (≈ 200 characters
  against 600–700), and her characters were right 89–92 % of the time, the other voice's 98–99 %
  (per-person figures in `Experiments/results/speakers.txt`).
- When the voices are told apart, nearly every line gets the right speaker; missed changes are
  mostly turns that follow with no pause (median gap 0.06 s, against 0.22 s for found ones),
  short turns (≤ 1.5 s) and the first ~10 s while the voices are learned.
- **Pekora and Marine are merged into one slot**, levelled or not, with or without Miko. Not a
  splice artefact or a model choice: Sortformer's other variants (balanced: same latency, "best
  on AMI"; high-context: 30 s look-ahead) fail the same way, and FluidAudio's offline
  embedding pipeline (pyannote + WeSpeaker + VBx, `kk-spike-diar`) also hears one speaker there,
  and does worse on the easy pair (79 % characters). Similar voices are this approach's limit.
- Variants on the easy pairs: balanced ≈ fast (97.7 %, 98.0 %), high-context no better
  (95.3 %, 94.9 %). Shipped: fast (FluidAudio's default).

### 6.3 Remembering a voice

**Voiceprints (shipped).** Similarity of WeSpeaker prints of 15 s stretches (`kikitori-cli
voiceprints`):

| | similarity |
|---|---|
| same person, same stream (3 stretches each of Pekora, Miko, Marine) | 0.57–0.87, mostly 0.73–0.87 |
| Pekora: solo stream vs the offline collab (another mic and room) | 0.59–0.69 |
| Miko vs Pekora or Marine | 0.07–0.27 |
| **Pekora vs Marine** | 0.28–0.62 |

Hence the threshold 0.65 with a 0.1 margin. End to end (`kikitori-cli speakers --remember`,
prints made from other stretches of the solo streams):

| Run | Named |
|---|---|
| Pekora + Miko, both remembered | A = Pekora after 6 s, B = Miko after 29 s: right |
| Miko + Marine, both remembered | A = Marine after 11 s, B = Miko after 21 s: right |
| Pekora + Miko, only **Marine** (absent) remembered | nobody: right |
| Pekora + Marine (merged into one letter by the diarizer), both remembered | the merged letter named Marine |
| Real collab, Pekora and Miko remembered from their solo streams | nobody (other mic: below 0.65); name by hand |

Diarization is the same with or without remembered voices (96.4–96.8 % of characters right).

**Enrollment (the first version, replaced).**

| Run | Named | Characters right |
|---|---|---|
| Pekora + Miko: none / Pekora / Miko enrolled | right voice both times | 96.8 / 96.4 / 97.1 % |
| Miko + Marine: none / Miko / Marine enrolled | right voice both times | 96.8 / 97.1 / 98.0 % |
| Pekora + Miko with **Marine** (absent) enrolled | Pekora's lines named "Marine" | 90.5 % |
| Real collab, Pekora enrolled from her solo stream | A = Pekora, right | 22 % of characters change: from mid-clip her voice moves to B |

## 7. Where the code is

| File | What |
|---|---|
| `Sources/KikitoriCore/Speakers/SpeakerTracker.swift` | `SpeakerTracking`, `SpeakerTracker` (Sortformer), `DeferredSpeakerTracker` |
| `Sources/KikitoriCore/Speakers/SpeakerLabeler.swift` | frames → characters → turns → line speaker |
| `Sources/KikitoriCore/Speakers/Spoken.swift` | a chunk's turns as lines, translator input, cue lines |
| `Sources/KikitoriCore/Speakers/Voiceprint.swift` | `Voiceprint`, `VoiceprintMaker` (WeSpeaker), `VoiceMatcher`, `SpeakerNamer`, `VoiceStore` (+ migration of old audio files) |
| `LivePipeline`, `MediaPipeline` | `speakers` property; feeding the tracker; timed recognition when on |
| `LiveTranslator` | one sentence about line breaks in the prompt |
| `AppModel` | trackers per session, lines per turn, names, remembered voices |
| `TranscriptRow` (`SpeakerChip`, `SpeakerMenu`), `OverlayView`, `PlayerScript`/`PlayerController`, `ProfilesView`, `SettingsView` | UI |
| `kikitori-cli speakers`, `voiceprints` | headless runs: turns, wait per chunk, diarizer time; `--json` for scoring; `--remember` (voiceprints), `--enroll` (the old enrollment); env knobs for the model, the wait and a run without the tracker; pairwise voiceprint similarity |
| `Experiments/speakers/splice.py`, `score.py`, `kk-spike-diar` | spliced collab with known turns; scoring; the offline embedding pipeline for comparison |

## 8. Limits and follow-ups

- **Similar voices merge** (Pekora/Marine above). Nothing in FluidAudio fixed it. A follow-up
  could try a dedicated speaker-embedding check on the solo audio of each slot, or another model.
- **4 voices at most** (Sortformer's slots); a 5th is merged or missed.
- **Fast exchanges**: changes with no pause and turns under ~1.5 s are often missed (a turn
  shorter than 0.5 s is folded in on purpose), and boundaries can be a character or two off.
- **Letters are per pipeline**: with the built-in player, the tap and the read-ahead pipelines
  have their own trackers, so a voice's letter can differ between synced and unsynced stretches
  of the same session (rare: a video is either synced or not). Names given apply to the letter.
- **Overlapping speech** goes to the more confident voice; the spec's "?" row for overlap is
  not built.
- **Cross-session voices** are experimental (§4, §6.3): conservative, so often unnamed with
  another mic.
- Not tested in the app with audio playing (the CLI runs the same pipeline code on files; the
  app's wiring, menus and views were built and compiled, not exercised by hand).

## 9. Decisions

- **Remembered voices keep a voiceprint only, never audio** (decided 2026-10-24, from the code
  review): §4.
