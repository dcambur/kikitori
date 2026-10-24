# UX review, October 2026: what changed and why

Each change below fixes a problem shown by the code or a render, judged against Apple's Human Interface
Guidelines and Nielsen's usability heuristics. Findings that were only arguable were left alone
(listed at the end). Method: every screen was rendered with `Kikitori --snapshots`, and an
independent reviewer audited the renders and the views in a fresh context. Each finding was then
checked against the code before anything changed.

## Changed

| # | Problem (evidence) | Principle | Change |
|---|---|---|---|
| 1 | Onboarding promised "Live English subtitles" and listed Claude translation as set up, but translation is off by default. The key step had no way past it without a key. | Nielsen 1–2; HIG Onboarding (defer optional setup) | The Claude step is now **"Do you want English?"**, with two choices: Japanese only (free) or Japanese + English (asks for the key and turns translation on). The Welcome and Done screens state the real setting. |
| 2 | Onboarding text was cut off ("Nothing is recor…") and no longer true, since replay keeps audio in memory. The Speech step had one option. | HIG Onboarding; Nielsen 8 | Text wraps and says what is true. The one-option step is gone; Apple's model now installs in the background on the Try step. |
| 3 | The menu bar's "Japanese" button and ⌃⌥J changed the *transcript*. The floating subtitles' setting could only be reached from their right-click menu, which Click-through blocks. | Nielsen 3–4; spec §5.8 | ⌃⌥J and the menu bar button now control the subtitles (`subtitleMode`). Settings › Overlay has a **Show** picker. The transcript keeps its own picker in its toolbar. |
| 4 | With translation off, every transcript line was small grey text, and VoiceOver said "Translating" for every line. | HIG Typography and Accessibility | A line with no English coming shows its Japanese at full size and contrast. The label reads the Japanese. |
| 5 | A click on a line silently started a paid Claude Sonnet explanation in Live and Watch, but not in Sessions. Clicking to select text also paid. | Nielsen 4–5; HIG Lists (click selects, double-click or Return opens) | A click selects. **Double-click, Return or the inspector's Explain button** explains, and the button shows the usual cost from the user's own history. |
| 6 | The transcript had no keyboard use: no arrow keys, no Return, no ⌘C. | HIG Accessibility › Keyboard | ↑/↓ move the selection, Return explains, ⌘C copies the line (`TranscriptKeys`, in Live and Watch). |
| 7 | Watch's "Translation" toolbar button opened a panel and didn't translate. The translate switch and Show picker were inside that panel, unlike Live. | Nielsen 4; HIG Toolbars | Watch's toolbar now matches Live's: Translate, Show and the standard Inspector button (⌥⌘I). The panel holds the transcript and explanations. |
| 8 | "Watch in kikitori" used ⇧⌘W, the standard Close shortcut. | HIG Keyboard (don't redefine standard shortcuts) | ⌃⌥W, like the app's other shortcuts. |
| 9 | ⌃⌥O ("Choose source") only opened Live. Hotkeys another app already holds failed silently and were still listed as working. | Nielsen 1, 9 | ⌃⌥O opens the source picker. Settings › Hotkeys marks a key "used by another app" and explains what to do. |
| 10 | ⌘1–5 were invisible buttons, in no menu. | HIG Menus | They are listed in the View menu. |
| 11 | Profiles showed "Voice: None" with speaker labels off; how to save a voice was only in a tooltip. | Nielsen 6, 10 | The Voice row shows only when speaker labels are on, with its instructions as visible text. |

## Left alone (arguable, not proven)

- **Duplication in the Live header** (title, stream and duration also shown elsewhere): real, but the fix is a matter of taste.
- **Budget settings split between Usage and Settings.**
- **Regrouping the menu bar's round buttons.**
- **Merging the Live and Watch inspectors into one component.**
- **Profiles at the 860 pt minimum width:** the offscreen render looked clipped, but that renderer doesn't size the split view as a real window does, so this is unproven.
