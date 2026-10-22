# kikitori (聞き取り) — UI specification v1

Implementation handoff for the macOS 26 SwiftUI app. The visual source is the design canvas
(artboards 00–21); this file holds everything an engineer needs that a picture cannot.

- Canvas: https://claude.ai/artifact/HGErbVYpwC6tRFRCXKNLJf (private until shared)
- Local copies in this folder:
  - `kikitori-design.html`: every artboard in one offline page (open in any browser).
  - `project/`: the canvas source (`canvas.json`, one `*.dc.html` per artboard, shared `kk.css` with all tokens).
  - `renders/`: a PNG of each artboard at 1×.
- Sample content is fictional: VTuber **Hoshimi Kuu 星見くう**, fans **星屑 “Stardust”**, collab partner **Amane Rio 天音リオ**.

Artboard index: 00 Foundations · 01–04 Onboarding · 05–07 Overlay · 08–09 Live transcript ·
10 Source picker · 11–12 Profiles · 13–14 Usage and budget · 15–16 Session history ·
17–18 Settings · 19 Menu bar extra · 20 Errors · 21 Accessibility.

---

## 1. Design principles

1. **The stream comes first.** The overlay is quiet: no chrome at rest, one pill at most when something is wrong, never more than one button on the overlay.
2. **Be honest about delay and money.** Delay is always measurable (latency badge). Spend is always visible and labelled “estimated”.
3. **Japanese never stops.** Translation can pause (offline, cap, errors); transcription keeps going and moves into the main slot.
4. **Apple-made.** System controls, system materials, SF Pro and Hiragino Sans. Personality: the Fuji accent, the 聞 mark, the 注 note marker.
5. **One cause, one next step** in every error.

---

## 2. Design tokens

All values are in `project/kk.css` (`.kl` light, `.kd` dark). In code, create an asset catalog colour set per token with Any/Dark appearances, plus a High Contrast variant where noted.

### 2.1 Colours

| Token | Light | Dark | Use |
|---|---|---|---|
| `accent` | #5E43CF | #A894FF | Tint, links, selected sidebar icons, focus ring base. App `AccentColor`. |
| `accentFill` | #6A4FD8 | #6E56E0 | Filled buttons, toggles, progress fills. White text on it: 5.6 / 5.2 : 1. |
| `accentSoft` | accentFill 12 % | #A894FF 16 % | Selected card fill, chips. |
| `selection` | accentFill 14 % | #A894FF 20 % | Selected transcript row, sidebar selection. |
| `note` | #9A4B00 | #FFB547 | 注 marker text, warnings text. |
| `noteBackground` | #FF9F0A 18 % | #FFB547 16 % | 注 marker background, warning banners. |
| `success` | #1A7F37 | #4CD964 | Granted, valid, level meter. |
| `danger` | #C4001A | #FF6B61 | Errors, destructive text. Destructive filled button: #D70015. |
| `info` | #0060C7 | #5AB0FF | Neutral banners. |
| `speakerA…D` | #0B6E99 · #B24A00 · #2D7D1F · #B0287A | #6CCBFF · #FFAE73 · #9FE07A · #F59AD4 | Speaker tags; always with a letter or name. |
| `label` / `secondaryLabel` / `tertiaryLabel` | #1D1D1F / #626268 / #737377 | #F2F2F5 / #A6A6AD / #8E8E95 | Use system `.primary` / `.secondary` / `.tertiary`; values listed for checking only. |
| `windowBackground` | #FFFFFF | #1E1E21 | System. |
| `inspectorBackground` | #F6F6F8 | #252528 | Inspector column. |
| `groupedBackground` | #F3F3F6 | #1A1A1D | Settings forms (system grouped style). |
| `separator` | black 11 % | white 11 % | System separator. |

Overlay tokens (identical in both appearances, the overlay is always dark unless the user picks the Light style):

| Token | Value |
|---|---|
| `overlayBackground` | rgba(16,16,22,0.72) over a blur (default opacity 72 %, user range 30–100 %) |
| `overlayBackgroundSolid` | #121216 (Reduce Transparency or opacity 100 %) + 1.5 pt white 55 % edge with Increase Contrast |
| `overlayText` | #FFFFFF |
| `overlayJapanese` | white 80 % |
| `overlayOlderLine` | white 62 % (80 % with Increase Contrast) |
| `overlayNote` | #FFCB7A on rgba(255,190,90,0.24) |
| `overlaySpeakerA…D` | #7FD4FF · #FFB37A · #B9F27C · #F7A6DA |
| `overlayLight` style | background rgba(250,250,252,0.80), text #111114, Japanese black 66 %, note #8A4300 |
| `overlayOutline` style | no background; text shadow 0 0 3 #000, 0 0 2 #000, 0 1 2 #000 |

Computed WCAG contrast (light / dark): label 16.8 / 14.9; secondary 6.1 / 6.9; tertiary 4.8 / 5.1; note on its tint 5.4 / 6.7; accent text 6.6 / 6.6. Overlay on the solid fallback: white 18.7, Japanese 12.1, older line 7.6, note 7.2.

### 2.2 Typography

| Role | Font | Size / line | Notes |
|---|---|---|---|
| Overlay English S / M / L / XL | SF Pro Rounded Semibold (`.system(size:, weight: .semibold, design: .rounded)`) | 18/23 · 24/31 · 34/44 · 44/56 | Default M. ⌘+/⌘− in 2 pt steps, 12–60 pt. `textWrap: balance` equivalent: use `.multilineTextAlignment(.center)` and `lineLimit(2)` per line. |
| Overlay Japanese | Hiragino Sans W3 | 13 · 15 · 20 · 26 | Ruby (furigana) at 50 % size. |
| Large title (onboarding) | SF Pro Bold | 26 (24 on dense steps) | |
| Window title | SF Pro Bold | 15 | System toolbar title. |
| Transcript English | SF Pro Regular | 15/21 | User-scalable 13–24. |
| Transcript Japanese | Hiragino Sans | 13/20 | secondaryLabel. |
| Body | SF Pro | 13/18 | `.body` |
| Secondary / hint | SF Pro | 12 and 11 | `.callout`, `.caption` |
| Timestamps, money, counts | SF Pro, monospaced digits | 11–34 | `.monospacedDigit()` everywhere numbers change live. |
| Code-like (API key) | SF Mono | 12–13 | |

Japanese text views: set `.environment(\.locale, Locale(identifier: "ja"))` and `.accessibilityTextLanguage("ja")` (or the AttributedString language attribute) so CJK line breaking and VoiceOver voice are correct. Font fallback for Japanese: Hiragino Sans; never let SF Pro synthesise kana.

### 2.3 Spacing, radii, sizes

- Spacing scale: 4, 8, 12, 16, 20, 24, 32. Window content margin 18; Settings form margin 28; onboarding side margin 48–64.
- Radii: 5 note marker / speaker tag · 6–8 fields, menu items, small buttons · 10 transcript rows · 12 cards, sidebar, form groups · 16 sheets, popovers, onboarding preview · 18 overlay · 20–22 alerts, notifications · capsule for push buttons, chips, toolbar groups, the overlay control bar. Window corners are the system’s.
- Control heights: regular 28, small 22, large 36; text field 28 (34 in onboarding). macOS mouse targets; keep ≥ 24 pt clickable area for icon buttons.
- Sidebar 200–216 pt; Profiles/Sessions content column 230–270 pt; inspector 310 pt.

### 2.4 Materials

| Surface | Material |
|---|---|
| Overlay | Custom: blur (radius 24, saturation 1.5) + `overlayBackground`. In AppKit: `NSVisualEffectView(.hudWindow, .behindWindow, appearance .darkAqua)` under a 72 % fill layer; or SwiftUI `.background(.ultraThinMaterial)` forced dark + color fill. Do not use Liquid Glass `glassEffect` for the subtitle body: its tint varies with content and breaks the contrast guarantee. The hover control bar may use `glassEffect(.regular.interactive())`. |
| Sidebar, toolbar, menus, popovers, sheets, alerts | System (Liquid Glass on macOS 26); no custom backgrounds. |
| Main content, inspector, Settings forms | Opaque system backgrounds. |

### 2.5 Iconography

SF Symbols only (the canvas draws look-alikes). Mapping:

| Meaning | SF Symbol |
|---|---|
| Live (sidebar) | `dot.radiowaves.left.and.right` |
| Sessions | `clock` |
| Profiles | `person.crop.circle` |
| Usage | `chart.bar` |
| Listening | `ear` |
| Speech detected | `waveform` (variable colour with level; static with Reduce Motion) |
| Transcribing | `text.alignleft` |
| Translating | `translate` |
| Paused | `pause.fill` |
| Music only | `music.note` |
| Offline | `wifi.slash` |
| Cap reached | `gauge.with.needle` |
| Error | `exclamationmark.triangle.fill` |
| Explain | `text.bubble` (or `questionmark.bubble`) |
| Transcript | `list.bullet` |
| Click-through | `cursorarrow.slash` (off: `cursorarrow`) |
| Overlay toggle | `captions.bubble` |
| Source app | the app’s own icon (`NSWorkspace.icon(forFile:)`); input device `mic` |
| Thermal | `thermometer.high` |
| Disk | `externaldrive.badge.exclamationmark` |
| Key | `key` |
| Export | `square.and.arrow.up` · Delete `trash` · Search `magnifyingglass` · Inspector `sidebar.right` |

App icon: squircle in #6A4FD8, white 聞 (Hiragino Sans W6) above two rounded subtitle bars (top 44 %, bottom 28 % of width, bottom bar 70 % opacity). Build in Icon Composer with three layers (background, kanji, bars); the bars take the glass highlight. Under 32 px the bars drop out.

Menu bar glyph (template image 18 × 16 pt): rounded rectangle with two caption lines. States: idle = outline; live = filled; paused = outline with pause bars; needs attention = outline + orange dot (#FF9F0A light menu bar / #FFB547 dark), the only colour in the menu bar.

### 2.6 Motion

| Element | Default | Reduce Motion |
|---|---|---|
| New overlay line | slide up 8 pt + fade, 180 ms ease-out | crossfade 120 ms |
| Older line dims | 200 ms | instant |
| Overlay hover controls | fade in 120 ms; fade out 1.5 s after pointer leaves | show/hide instantly |
| Overlay idle collapse to pill | 250 ms spring | instant |
| Translating dots | bounce 900 ms loop | fill one by one, no movement |
| Speech glyph | variable colour with level | static |
| Skeleton (explain loading) | shimmer 1.2 s | static bars |
| Level meters | 20 Hz | 4 Hz |
| Jump to Live | smooth scroll | jump |

---

## 3. Scenes and windows

```swift
@main struct KikitoriApp: App {
  var body: some Scene {
    Window("Welcome to kikitori", id: "onboarding") { OnboardingView() }   // shown on first run only
      .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
      .defaultPosition(.center)
    Window("kikitori", id: "main") { MainView() }                          // single main window
      .defaultSize(width: 1100, height: 700)
      .commands { KikitoriCommands() }
    Settings { SettingsView() }                                             // ⌘,
    MenuBarExtra { MenuBarPanel() } label: { MenuBarGlyph(state:) }
      .menuBarExtraStyle(.window)
  }
}
// Overlay: AppKit, owned by an OverlayController (not a SwiftUI Scene).
```

| Surface | Implementation |
|---|---|
| Overlay | `NSPanel` subclass, styleMask `[.nonactivatingPanel, .borderless, .resizable]`, `isFloatingPanel = true`, `level = .floating` (raise to `.statusBar` if a full-screen player covers it), `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `isMovableByWindowBackground = true`, `backgroundColor = .clear`, `hasShadow = false` (shadow is drawn by the view). Content: `NSHostingView(OverlayView)`. Click-through: `ignoresMouseEvents = true`. Frame saved per display (`NSScreen` `localizedName` + frame) in UserDefaults. |
| Main window | `NavigationSplitView` (sidebar + content + detail). Sidebar: Live, Sessions, Profiles, Usage. Live uses two columns (sidebar + detail with `.inspector`); Sessions and Profiles use three columns. |
| Onboarding | Fixed 640 × 520 window, `.hiddenTitleBar`, minimise/zoom disabled. Reopen via Settings › General › Run Setup Again…. |
| Settings | `Settings { TabView { … .tabItem { Label(…) } } }`, each tab a `Form` with `.formStyle(.grouped)`; window width 680, height fits the tab. Tabs: General, Audio, Speech, Translation, Overlay, Hotkeys, Account. |
| Menu bar | `MenuBarExtra(.window)` panel width 320. Right-click on the item opens a short `NSMenu` (Start/Stop Listening, Show Subtitles ✓, Quit). |
| Source picker | `.popover` (380 pt wide) from the toolbar Source control, the session header, the menu bar row and ⌃⌥O. |
| Sheets | Export, New Profile, Import Profile, Change Cap: `.sheet` on the main window. |
| Alerts | `.alert` / `confirmationDialog` for deletes and blocking errors. |
| Notifications | `UNUserNotificationCenter`; only when kikitori is not frontmost. |
| Activation policy | `.accessory` by default (menu bar app); switch to `.regular` while the main window or onboarding is open if “Show in Dock” is on. |

Commands (`KikitoriCommands`): File › New Profile ⌘N, Import Profile…, Export Transcript… ⇧⌘E; Edit › Find ⌘F; View › Show Inspector ⌥⌘I, Make Text Bigger ⌘+, Smaller ⌘−, Live ⌘1, Sessions ⌘2, Profiles ⌘3, Usage ⌘4; Session › Start/Stop Listening, Pause ⌃⌥P, Explain Last Line ⌃⌥E, Choose Source… ⌃⌥O, Jump to Live ⌘↓.

---

## 4. Global state model (drives every status surface)

```
SessionState: idle | starting | listening(sub: PipelineState) | paused | ended
PipelineState (normal): listening | speech | transcribing | translating
Degraded (overrides the overlay pill, never stops transcription):
  musicOnly | offlineJapaneseOnly | capReachedJapaneseOnly | creditsExhausted | rateLimited(retryIn)
  | apiOutage | keyInvalid | fallingBehind
Blocking errors (listening stops): permissionRevoked | sourceQuit(waitingUntil) | modelUnavailable
Warnings (window + menu bar only): diskLow | longSession | thermal(latency)
```

Precedence for the single overlay pill: blocking error > keyInvalid > creditsExhausted > capReached > offline/outage > rateLimited > fallingBehind (4 s) > musicOnly > thermal latency badge. The menu bar attention dot shows for anything above musicOnly except fallingBehind. VoiceOver announces changes into and out of any non-normal state.

Latency = end of the speech segment → English line on screen; badge shows the median of the last 5 lines. Thresholds: ≤ 3.5 s neutral, 3.5–6 s amber, > 6 s red and pinned at rest until < 5 s for 30 s. Popover on click shows the split: capture / speech-to-text / Claude.

---

## 5. Screens

Each section: structure, states with triggers, copy. Copy is final unless marked [placeholder]. Curly quotes and the ellipsis character (…) are intentional.

### 5.1 Onboarding (artboards 01–04)

**Structure.** One `Window`, `OnboardingView` holds `@State step`. Layout per step: top bar (traffic lights; 4-segment step indicator centred, accessibility label “Step N of 4”), centred content column (max 470 pt), bottom bar (Back left; secondary + primary right). Return = primary, Esc = nothing, ⌘[ = Back. Steps: Welcome → Audio (1/4) → Claude (2/4) → Speech model (3/4) → Try it (4/4) → Done.

**Welcome**
- Title “Welcome to kikitori”. Body “Live English subtitles for Japanese streams, with the context behind the jokes.”
- Features: “Hears the stream” / “Listens to one app, like Safari or Chrome. No extra audio drivers.” · “Transcribes on your Mac” / “Japanese speech becomes text on-device. Audio never leaves your Mac.” · “Translates with Claude” / “Subtitles arrive 2–5 seconds behind. Click any line to learn the slang, meme or reference.”
- Button “Get Started”.

**Audio access** (capture via Core Audio process taps, `AudioHardwareCreateProcessTap`, Info.plist `NSAudioCaptureUsageDescription`: “kikitori listens to the app you choose so it can subtitle the stream. Audio stays on your Mac.”)
| State | Trigger | Content |
|---|---|---|
| Not yet asked | first visit | Title “Let kikitori hear your apps”. Body “kikitori listens to the sound of one app you choose. macOS calls this permission **Screen & System Audio Recording**. kikitori records audio only, never your screen.” Note “Audio is turned into text on this Mac and then discarded. Nothing is recorded to disk unless you export a transcript.” Buttons: Back · “Use a Microphone Instead” · **“Allow Audio Access”** (creates a test tap → system prompt). |
| Granted | test tap opens without error | Title “Audio access is on”. Body “You can turn it off any time in System Settings › Privacy & Security › Screen & System Audio Recording.” Auto-advance after 1.5 s; Continue. |
| Denied | prompt dismissed / tap fails with permission error | Title “kikitori can’t hear your apps yet”. Body “Audio access is turned off. Turn it on in System Settings, then come back here.” Steps “1. Click **Open System Settings**.” “2. Under **Screen & System Audio Recording**, turn on **kikitori**.” “3. If macOS asks, choose **Quit & Reopen**. kikitori comes back to this step.” Buttons: Back · “Use a Microphone Instead” · “Check Again” · **“Open System Settings”** (deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`). Poll every 2 s while visible. Persist “onboarding step” so a relaunch resumes here. |
| Microphone path | “Use a Microphone Instead” | Requests mic (`AVCaptureDevice.requestAccess(for: .audio)`); then the Try it step defaults to Input Devices. |

**Claude API key**
- Title “Connect Claude”. Body “kikitori translates with your own Claude API key. Your Max plan includes monthly API credits.”
- Field label “API key”, placeholder “sk-ant-…”, `SecureField` showing last 4 characters after save; Paste button. Hint “Stored in your Mac’s Keychain. Sent only to Anthropic.”
- Disclosure (expanded first time) “How do I get a key?”: “1. Open the Claude Console and sign in with your Claude account.” “2. Claim the API credits included with your Max plan.” “3. Go to API Keys › Create Key, name it “kikitori”, and copy it.” Link “Open Claude Console ↗” (https://console.anthropic.com).
| State | Trigger | Content |
|---|---|---|
| Empty | no key | Continue disabled. |
| Validating | 0.4 s after paste/typing stops; one minimal request to the live model; timeout 10 s | Spinner + “Checking key…”. Continue disabled. |
| Valid | 200 | Green field ring + check. Banner “**Key works.** Live subtitles: Claude Haiku 5.5 · Explanations: Claude Sonnet 5.5. Expect about $0.05–0.15 per stream hour.” Key saved to Keychain (`kSecClassGenericPassword`, service `app.kikitori.anthropic`, account `default`, accessible `AfterFirstUnlock`). Button “Change”. |
| Invalid | 401/403 | Red ring; `role=alert` text “**This key wasn’t accepted.** Check that you copied the whole key, or create a new one in the Claude Console.” + link. Not saved. |
| Busy | 429/529 | Same layout: “Claude is busy. Try again in a minute.” |
| No credit | billing / credit-balance error | “No API credits left. Claim or add credits in the Claude Console.” Key is saved (it is valid). |
| Network | offline, DNS, 5xx, timeout | Warning banner “**Can’t reach Anthropic.** Check your internet connection and try again. You can also continue now: kikitori shows Japanese only until it connects.” Buttons “Try Again”, **“Continue Without Checking”** (key saved unverified, checked on first use). |

**Speech model** [model names and sizes are placeholders until the bench settles them]
| Option | Detail | Speed / Accuracy (5 pips) |
|---|---|---|
| Apple Speech | “Built into macOS · no download” | 5 / 2 |
| Light — Whisper Small | 0.6 GB | 4 / 3 |
| **Balanced — Whisper Large v3 Turbo** (default, chip “Recommended”) | 1.6 GB | 3 / 4 |
| Best — Whisper Large v3 | “3.1 GB · adds about 1 s of delay on M1” | 2 / 5 |
- Title “Choose a speech model”. Body “Japanese speech is recognised on your Mac. Larger models handle fast talk and game noise better.” Footer “182 GB free on Macintosh HD · You can switch models later in Settings › Speech.” Primary “Download 1.6 GB” (label follows selection; Apple Speech → “Continue”).
- Radio cards: `Picker(.radioGroup)` styled as cards; arrow keys move, Space selects; selected = 2 pt accentFill ring + accentSoft fill. Pips have an accessibility value “Speed 3 of 5, accuracy 4 of 5”.
| State | Trigger | Content |
|---|---|---|
| Downloading | Download | Title “Downloading Balanced”; determinate bar; “760 MB of 1.6 GB” · “About 2 minutes left”; Pause, Cancel. Note “After downloading, the model is checked and prepared for the Neural Engine. This takes up to a minute the first time.” Background `URLSession`; progress also on the Dock tile and menu bar panel. Continue disabled until ready. |
| Paused | Pause | “Download paused”, grey bar, Resume (primary), Cancel. Resume data kept across relaunch. |
| Checking / preparing | 100 % | “Checking…” then “Preparing for this Mac…” with indeterminate bar (static bar + text with Reduce Motion). |
| Failed: network | connection lost | Title “Download stopped”. Body “The connection was lost at 1.1 GB of 1.6 GB. Nothing is lost: kikitori picks up where it stopped.” Red partial bar. “Resume Download” (primary), “Choose Another Model”. |
| Failed: damaged | checksum mismatch | Body “The download was damaged.” Button “Download Again” (starts over). |
| Low disk | free < size + 0.5 GB for the selected model | Banner “**Only 2.4 GB free on Macintosh HD.** Best needs 3.6 GB. Free up space, or choose a smaller model.” Non-fitting cards dimmed, hint “3.1 GB · needs 1.2 GB more”, `accessibilityLabel` includes the shortfall; selection moves to the largest that fits. Extra button “Open Storage Settings”. |

**Try it**
- Title “Try it”. Body “Play any Japanese video or stream. Subtitles appear here, about 2–5 seconds behind the voice.”
- Row “Listen to” + source popup (defaults to the app currently playing; else Safari) + 6-bar level meter.
- Preview: dark 150 pt box with the real `OverlayView` at S size.
| State | Trigger | Content |
|---|---|---|
| Waiting | no speech yet | Meter grey, “No sound yet”; preview pill “Listening”, line “Waiting for Japanese speech…”. Buttons Skip, Continue (disabled). |
| Working | first translated line | Chip “It works · 2.8 s behind” (measured); preview shows JP + EN; Continue enabled. |
| No sound | 20 s silence | Info banner “**No sound from Safari yet.** Is the video playing and not muted? If it plays in another app, pick that app.” Button “Choose Another App…”. |
| Sound, no speech | 20 s of non-speech audio | Banner “Hearing music or game sound, but no speech yet.” |

**Done**
- Title “You’re all set”. Summary rows: “Listening to · Safari”, “Speech model · Balanced, on this Mac”, “Translation · Claude Haiku 5.5 → English”, “Monthly budget · $100 credit · warn at 80 %”. If the test was skipped: “Listening to · Choose when you start”.
- Hints: “⌃⌥S Show or hide subtitles”, “⌃⌥E Explain the last line”, “kikitori lives in the menu bar [glyph] · Add a streamer profile for better names and slang.”
- Buttons “Open Settings”, **“Start Listening”** (closes onboarding, starts a session on the tested source, shows the overlay).

### 5.2 Floating subtitle overlay (artboards 05–07)

**Structure (`OverlayView`)**
```
ZStack(alignment: .top) {
  SubtitleStack            // 1–4 lines (default 2), centred; left-aligned when speaker labels show
  if hovering { HoverChrome }   // drag handle, status+latency (top-left, outside the panel), control capsule (top-right), resize grip
  if pinnedPill { StatusPill }  // inside the panel, above the lines
}
.background(OverlayBackground(style:, opacity:))   // radius 18, padding 12/22/14
```
- Line model: `{ id, japanese, japaneseFurigana?, english?, speaker?, hasNote, noteTerm, state: .partial|.final|.translating }`. Newest at the bottom; older lines `overlayOlderLine`. A line with Japanese but no English shows three dots in the English slot (one-line height reserved so the panel does not jump).
- Note marker: dotted underline (2 pt, `overlayNote`) under the flagged phrase + `注` chip after the line. Clicking the chip or the line opens the explanation popover; ⌃⌥E explains the newest line.
- Speaker label (when diarisation is on and confident): letter in `overlaySpeakerX` at 62 % font size before the line; name if the session mapped it (“Kuu”).
- Width: drag the grip; min 360 pt, max screen width − 80; height follows the line count and text size. Position presets: top/bottom × left/centre/right, default bottom centre 64 pt above the Dock; drag snaps within 24 pt, otherwise “Custom”.
- Hover chrome appears after 0 s on pointer enter, hides 1.5 s after exit. Control capsule (toolbar, `accessibilityLabel` “Subtitle controls”): Pause (⌃⌥P) · Explain last line (⌃⌥E) · Open transcript (⌃⌥T) · Click-through (⌃⌥C) · Overlay settings. Status pill (“Translating”) and latency pill (“≈ 3.1 s behind”) sit 36 pt above the panel’s top-left. Thin 1 pt white 22 % outline on the panel while hovered.
- Click-through on: `ignoresMouseEvents = true`; hover (after 0.6 s dwell, detected with a global mouse-moved monitor) shows only the pill “Click-through on · ⌃⌥C to turn off”.
- Right-click menu: Pause ⌃⌥P · Explain Last Line ⌃⌥E · Open Transcript ⌃⌥T · — · Show Japanese ⌃⌥J ✓ · Show Furigana · Lines ▸ (1–4) · Text Size ▸ (S, M, L, XL) · Position ▸ (6 presets) · Click-Through ⌃⌥C · — · Overlay Settings… · Hide Subtitles ⌃⌥S.
- Styles: Dark glass (default), Light glass, Outline. Reduce Transparency forces the solid style.
- Idle: after 8 s without new lines, lines fade and the panel shrinks to the “Listening” pill; if “Hide when no one is speaking” is on, it hides entirely and returns on the next line.

**States** (pill copy; at most one button)
| State | Trigger | Overlay shows |
|---|---|---|
| Listening | no speech 8 s | Pill “Listening” (or hidden) |
| Speech detected | VAD positive | Green `waveform` glyph in the panel’s top-left corner |
| Transcribing | segment open | Partial Japanese with trailing “…” (if Japanese shown) |
| Translating | chunk sent | Three dots in the English slot |
| Paused | user pause | Pinned pill “Paused · ⌃⌥P to resume”; last line dimmed |
| Music only | sound but no voice 5 s | Pill “Music only · no speech” |
| Offline: JP only | no network / outage | Pinned pill “Offline · Japanese only” (outage: “Claude isn’t responding · Japanese only”); Japanese moves to the main slot at English size − 20 % |
| Cap reached | estimated spend ≥ cap | Pinned pill “Monthly cap reached · Japanese only” (click → Usage) |
| Error | see §5.10 | Red glyph + “**Safari quit.** Listening stopped.” + one button |

**Explanation popover from the overlay** (`NSPopover`, `.transient`, always dark appearance, 440 pt): header `注` + term + reading + chip “Sonnet 5.5”; body (meaning, then “in this line” in secondary colour); buttons “Open in Transcript”, “Copy”; cost “$0.004” at the right. Loading: 3 skeleton lines + “Asking Claude Sonnet…”. Error: “Couldn’t get an explanation.” + “Try Again”. Esc closes.

### 5.3 Main window: Live transcript (artboards 08–09)

**Structure**
```
NavigationSplitView {
  Sidebar: List(selection:) { Live (badge: red dot + elapsed h:mm, or “Idle”) · Sessions (count) · Profiles · Usage }
           footer: “This cycle  $6.12 of $100” + meter + “Credits reset Nov 14”
} detail: LiveView
LiveView:
  toolbar: title = profile name, subtitle = stream title (Japanese allowed)
           items: status chip (“Translating · ≈ 2.9 s”) · [Pause | Overlay toggle] · search field · [Export | Inspector toggle]
  SessionHeader (HStack, wraps): Source [icon] Safari · Profile [popup] · Game · spacer · Duration 1:12:40 · Cost $0.14
  TranscriptList (ScrollViewReader + LazyVStack, .defaultScrollAnchor(.bottom))
  .inspector(isPresented:) { ExplanationInspector }  // 310 pt
```
- Row (`TranscriptRow`): grid 58 pt time column + text; Japanese (13 Hiragino, secondary) above English (15); note chip “注 てぇてぇ” after the English; speaker tag before the Japanese when known. Selected row = `selection` fill, radius 10. Pending row: time column shows red dot + “Live”, English slot shows dots.
- Clicking a row selects it and explains it (if the inspector is closed it opens). ↑/↓ move, ↩ explains, ⌘C copies English, ⌥⌘C Japanese.
- Auto-scroll: on while the user is at the bottom; scrolling up by more than one row pauses it and shows the floating capsule “Jump to Live · 6 new lines” (accentFill, centred, 16 pt from bottom). Click, End or ⌘↓ resumes.
- Source change mid-session inserts a divider row “Source changed to Discord”.
- Context menu: Explain ↩ · Explain Again · — · Copy English ⌘C · Copy Japanese ⌥⌘C · Copy Both with Time · — · Add Term to Glossary… · Report Bad Translation… (local flag only, included in exports).
- Stream info popover (click the subtitle/stream title): fields “Stream title”, “Game or topic”; hint “Sent to Claude as context. Type it or paste it from the stream page.”

**Explanation inspector states**
| State | Trigger | Content |
|---|---|---|
| Empty | nothing selected | `text.bubble` 40 pt, “Nothing selected”, “Click a line to see what it means. Lines marked 注 have something worth knowing.” |
| Loading | request started | Term (20 pt bold Japanese), 3 skeleton lines, “Asking Claude Sonnet…”, Cancel. Text streams in as it arrives. |
| Result | response | Card: term + reading; meaning; “IN THIS LINE” section; optional “CLOSE ENGLISH FAN SLANG”. Buttons Explain Again · Copy · Add to Glossary. Footer “Claude Sonnet 5.5 · $0.004 · used profile notes and 12 lines of context”. Explain Again keeps earlier answers: pager “‹ 2 of 2 ›” in the card header. |
| Error | timeout / network / 429 / cap | “**Couldn’t get an explanation.** Claude didn’t answer in time.” + Try Again. Variants: “You’re offline.” · “Claude is busy right now.” · “Monthly cap reached. Explanations are paused.” + Open Usage. |

One explanation request per line at a time; selecting another line cancels the pending one.

**Search (⌘F)**: toolbar search field; matches Japanese, English and notes; highlight `#FFD60A` 45 % (current match solid); “2 of 3”; ↩ / ⇧↩ step; scope segmented All / Notes. Empty: “No lines match ‘…’.” + Clear Search.

**Export sheet (⇧⌘E)**: title “Export Transcript”. Format segmented SRT / WebVTT / Markdown. Include: English ✓, Japanese (above English) ✓, Speaker labels, Notes and explanations (Markdown only; disabled otherwise). “Times from”: Session start / Stream clock (offset field). Lines: “All 1,284” / “Selected 3”. Monospaced preview of the first cue. Cancel · **Export…** → `NSSavePanel`, default name “Hoshimi Kuu – 2026-10-22 – Minecraft.srt”.

**Collab / speaker labels** (artboard 09): header strip “Speakers  A · Kuu  B · Rio … best effort”. Click a tag to rename for this session. Overlapping speech row: tag “?”, secondary text “Overlapping speech; best-guess text, not split by speaker.”

### 5.4 Source picker (artboard 10)

`SourcePickerView` in a popover, 380 pt. Segmented control Apps / Input Devices.
- Apps: sections “Playing sound” (sorted by level) and “Other apps” (silent, dimmed name). Row 44 pt: app icon 28 pt, name, status (“streams.example · playing” when a window title is known, else “playing” / “silent”), 6-bar level meter, checkmark for the current source. Footer “Only this app’s sound is heard. Other apps, notifications and your voice are ignored.”
- Running apps come from `NSWorkspace.runningApplications` (regular activation policy); levels from short-lived probe taps (1 s) refreshed while the popover is open.
- Input Devices: rows with `mic`, device name, detail (“2 channels · 48 kHz”, “built in”, “Bluetooth · lower quality while in use”). Info banner “A microphone also hears your room. App audio is cleaner when the stream plays on this Mac.” First pick triggers the microphone prompt.
| State | Trigger | Content |
|---|---|---|
| Normal | ≥ 1 app playing | as above |
| Nothing playing | no app played sound in 10 s | Icon `speaker.slash`, “No app is playing sound”, “Start the stream, then pick its app here. You can also choose an app now and kikitori waits for it.” + section “All apps”. |
| No permission | audio access missing | Warning icon, “kikitori can’t hear apps”, “Turn on kikitori in System Settings › Privacy & Security › Screen & System Audio Recording.” + “Open System Settings”. Input Devices tab stays usable. |

### 5.5 Streamer profiles (artboards 11–12)

**Structure**: three-column split. Content column: title “Profiles” + New (⌘N) button, filter field, list rows (avatar circle in the profile colour with one kanji, name, “24 terms · 12 sessions”, chip “Live” on the profile in use), last row “No profile · generic VTuber context”.
Detail: toolbar avatar + English name + Japanese name; “Use for This Session” (or disabled “In Use This Session”); Import/Export menu; More menu (Duplicate, Delete…).
- Fields (grid of 3): “Name (English)”, “Name (Japanese)”, “Colour” (5 swatches: wisteria #8D7BE0, blue #2F8FB8, orange #C2571A, pink #C23A7A, green #3C8D5A; buttons with names as labels).
- “Glossary” header + “24 terms” + “Add Term”. SwiftUI `Table` with columns **Term**, **Reading**, **Meaning**, **Translate as** (rename of the brief’s “notes” column: it is what the translator must output; free notes go in Meaning). Inline editing: double-click or ↩ turns the row into text fields; Tab moves across cells; ⌫ deletes the selected row(s) with undo. Sort by any column.
- “Notes for the translator”: multi-line `TextEditor`.
- Footer: “Sent to Claude with every chunk: names, glossary and notes, about 1,400 tokens. It is prompt-cached, so it adds little to the cost.” Show a warning above 2,000 tokens: “Long glossaries make every request bigger. Consider trimming rarely used terms.” [threshold to confirm]

**States**
| State | Trigger | Content |
|---|---|---|
| Empty | no profiles | “No streamer profiles” / “A profile teaches the translator a streamer’s names, fan name, catchphrases and running jokes.” Buttons Import…, **New Profile**. |
| New profile sheet | ⌘N | “New Profile”: Name (English), Name (Japanese), “Channel link (optional)” + hint “Used only to match this profile to a stream automatically. kikitori does not visit the link.” Cancel · Create (enabled when a name exists). |
| Import | File › Import Profile… or drop `.json` | Sheet “Import “hoshimi-kuu.json””: “Merging into **Hoshimi Kuu**: 18 new terms, 3 terms differ.” Conflict table Term / Yours / Imported / Keep (popup Yours · Imported · Both). Checkbox “Append imported notes to mine”. Cancel · “Import 21 Terms”. New name → creates a profile directly. |
| Bad import | parse error | Alert “This file isn’t a kikitori profile.” + reason in small text. |
| Export | Export Profile… / Export All Profiles… | `NSSavePanel`, JSON `{ "version": 1, "name", "nameJa", "colour", "channel", "glossary": [{ "term", "reading", "meaning", "translateAs" }], "notes" }`, UTF-8, pretty printed. |
| Session pick | session header Profile popup / menu bar | Menu “Profile for this session”: profiles with avatar, ✓ on current, trailing “Matched” when auto-matched (channel link or name found in the stream title); “No Profile”; — ; “Collab: Add Second Profile…” (up to 3; glossaries merge, first wins on conflicts); “Edit “Hoshimi Kuu”…”; “New Profile…”. |
| Delete | More › Delete… | Alert “Delete “Kurogane Mei”?” / “Its 6 glossary terms and notes are removed. Past sessions keep their transcripts.” Delete (destructive) · Cancel. |

### 5.6 Usage and budget (artboards 13–14)

**Structure** (detail, two columns):
- Toolbar: “Usage”, subtitle “Billing cycle Oct 15 – Nov 14 · day 8 of 31”; button “Open Claude Console ↗”.
- Hero card: “$6.12” (34 pt bold, monospaced digits) “of $100 monthly credit used”; bar with used (accentFill) + projected (hatched accent outline) + 2 pt marker at the warning threshold; legend “Used $6.12 · Projected $23.40 · Warning at $80 · Cap $100”; stats “Projected by Nov 14 $23.40”, “Per stream hour $0.11”, “Left this cycle $93.88”.
- “Daily spend” bar chart (Swift Charts `BarMark`, single series, accentFill, 4 pt rounded tops, 2 pt gaps; future days as hatched outline at the projected daily average; zero days as a 2 pt baseline tick). Hover: tooltip “Sun Oct 18 · $1.48 · 2 sessions, 6 h 10 min”. `accessibilityChartDescriptor` provided.
- Recent sessions `Table`: Date · Streamer · Length · Subtitles · Explain · Total (right-aligned money). Row click → opens that session.
- Right column: “By model” (Live subtitles $4.38 · “Claude Haiku 5.5 · 72 % · 3.1 M tokens”; Explanations $1.74 · “Claude Sonnet 5.5 · 28 % · 61 explanations”) and the budget form: “Monthly cap” (currency field, $1–$500, default $100) · “When reached” popup · “Warn at 80 %” toggle. Footer “Credits included with Max expire at the end of each billing cycle and don’t carry over. Spend here is estimated from token counts; the Claude Console shows the exact amount.”

**Computation**: per request, cost = input/cached/output tokens from the API `usage` field × a per-model price table shipped in app config (updateable without a release). Projection = spend so far + (average daily spend over the last 7 active days × remaining days). Cycle start day is set in Settings › Account (default: day of first launch).

**States**
| State | Trigger | Content |
|---|---|---|
| Normal | < 80 % of cap | as above |
| 80 % warning | crosses 80 % once per cycle (toggle on) | Banner on Usage and Live: “**80 % of your monthly cap is used.** At this pace you’ll reach $100 around Nov 11, and translation will pause then.” + “Change Cap…”. Notification “80 % of your monthly cap used” / “$80.40 of $100. At this pace you’ll reach it around Nov 11.” Menu bar dot. Projection hatch turns `note` colour. |
| Cap reached | ≥ cap | Banner (danger tint): “**Monthly cap reached.** Translation is paused until Nov 15. Japanese subtitles keep working.” Buttons “Raise Cap…”, “Translate This Session Anyway” (lifts the cap until the session ends). Notification “Monthly cap reached” / same body. Overlay pill. Resets at cycle start. |
| When reached options | popup | “Japanese only” (default) · “Keep subtitles, stop explanations” · “Stop listening” · “Only warn me”. Cap above $100 shows: “Above $100, extra spend uses other credit on the account, if any.” |
| Account out of credit | API credit error | handled in §5.10 (differs from the user cap). |

### 5.7 Session history (artboards 15–16)

**Structure**: three columns. Content: title “Sessions”, search field “Search all transcripts” (full-text across sessions), grouped list (Today, Yesterday, Earlier this month, then months). Row: avatar, stream title (Japanese, one line, ellipsis; full in tooltip), “Amane Rio · 2 h 05 min · $0.29”. Multi-select allowed.
Detail: read-only transcript (same `TranscriptRow`, explanations viewable in the inspector), toolbar Search · Export · Delete; header “Source Chrome · Profile Amane Rio · Lines 1,912 · Notes 23 · Cost $0.29”; footer “Saved on this Mac only. Kept for 1 year (Settings › General).”

Storage: SwiftData (or SQLite/GRDB) in `~/Library/Application Support/kikitori`; lines written every 30 s during a session; audio never stored.

| State | Trigger | Content |
|---|---|---|
| Empty | no saved sessions | “No past sessions” / “Finished streams appear here with their transcripts and explanations.” + “Start Listening”. |
| Saved | session ends (Stop, quit, source gone 10 min) | sessions under 1 min with no lines are discarded |
| Delete | ⌫ or toolbar | Alert “Delete 3 sessions?” / “Their transcripts and explanations are removed from this Mac. Spend history in Usage is kept.” Single: “Delete this session?” / ““【雑談】初見さん歓迎！” and its 23 explanations are removed from this Mac.” No trash. |
| Retention change | shortening would delete | Alert “Remove 12 older sessions?” / “Changing to 30 days deletes sessions from before Sep 22 now.” “Remove 12 Sessions” · Cancel. |

Retention options: Forever, 1 year (default), 90 days, 30 days, 7 days, Don’t keep. Applied at launch and daily.

### 5.8 Settings (artboards 17–18)

General
- Startup: “Launch at login” (`SMAppService.mainApp`) · “Show menu bar icon” + hint “When off, open kikitori from the Dock or Spotlight.” · “Show in Dock” + hint “Only while a kikitori window is open.”
- Sessions: “Start listening automatically” (Never / When the last source plays) · “End session after silence” (5, 10, 30 min, Never).
- History: “Keep sessions” · “Save explanations with transcripts”.
- Button “Run Setup Again…”.

Audio
- Source: “Listen to” (same picker as §5.4, inline popup) · “If the app quits” (Wait for it / End the session) + hint “kikitori waits 10 minutes for it to come back.”
- Speech detection: “Sensitivity” slider (Fewer false starts ↔ Catches whispers) with live chip “Speech now” and a level-history strip (green = speech) while the tab is open · “Music and game sound” segmented Off / Reduce / Strong + hint “Strong may drop singing and whispers.” · “Label speakers in collabs” + hint “Best effort. Uses more CPU.” (default off).

Speech
- Model list (radio rows): status chip Ready / Installed / Download button / progress + Pause; “···” menu: Show in Finder, Check for Damage, Delete (disabled for the model in use). Foot “Switching models takes effect at the next chunk.”
- “Chunks sent to Claude”: “Chunk length” slider 10–20 s (default 15; labels “10 s · faster, less context” / “20 s · more context”) · “Send early at sentence end” + hint “Doesn’t wait for the full chunk when a sentence clearly ends.” (default on).

Translation
- “Translate into” (English default; list of other languages later) · “Style” slider Literal ↔ Natural (5 steps, default 4) · “Honorifics (-chan, -san, -senpai)” Keep / Translate · “Mark lines that need context (注)”.
- Preview card (local sample, no API call): “リオちゃん、マネちゃんに怒られちゃうよ” → “Rio-chan, my manager’s going to scold me.” (Translate honorifics → “Rio, my manager’s…”).
- Original text: “Show Japanese above English” · “Show furigana”.
- Claude models: “Live subtitles” popup (default Claude Haiku 5.5) · “Explanations” popup (default Claude Sonnet 5.5). Model list from the Models API, filtered to the families allowed in config.

Overlay
- Live preview strip. Text: Font (SF Pro Rounded, SF Pro, Hiragino Maru Gothic) · Size S/M/L/XL · Lines stepper 1–4.
- Look: Style Dark glass / Light glass / Outline · Background opacity 30–100 % · Speaker colours.
- Behaviour: Position (6 presets + Custom) · Click-through · “Hide when no one is speaking” (default on) · “Always show delay” (default off) · “Announce new lines with VoiceOver” (default off; see §7).

Hotkeys (global; Carbon `RegisterEventHotKey`, no Accessibility permission needed)
| Action | Default |
|---|---|
| Show or hide subtitles | ⌃⌥S |
| Pause or resume | ⌃⌥P |
| Explain the last line | ⌃⌥E |
| Open transcript | ⌃⌥T |
| Click-through on or off | ⌃⌥C |
| Show Japanese on or off | ⌃⌥J |
| Choose source | ⌃⌥O |
| Start or stop listening | none |
Recorder control: click → “Type a shortcut…” (focus ring); Esc cancels; Delete clears; a shortcut needs ⌃, ⌥ or ⌘. If registration fails: amber ring + hint “⌃⌥T may also be used by another app.” Foot “Shortcuts work in every app, also over full-screen video.” Button “Restore Defaults”.

Account & Privacy
- Claude: “API key” `sk-ant-…Q7xA · in Keychain` + Change… / Remove… (confirm: “Remove the API key? Translation stops until you add a key again.”) · “Status” chip “Key works · checked today 20:01” (or the error) · “Billing cycle starts on” Day 1–28.
- “What is sent to Claude”: ✓ Japanese text of each chunk · ✓ The profile: names, glossary, notes · ✓ Stream title and game · ✓ For Explain: that line and nearby lines. ✕ Audio, ever · ✕ Your screen or other apps · ✕ Past sessions · ✕ Anything about you. Foot “Requests go straight from this Mac to Anthropic’s API; there is no kikitori server.” + “Anthropic Privacy Policy ↗”.
- Data on this Mac: “Transcripts, profiles, usage” + path and size; Show in Finder · Delete All… (alert “Delete all kikitori data?” / “Sessions, profiles and usage history are removed. Your API key and settings stay.”).

### 5.9 Menu bar extra (artboard 19)

Panel 320 pt (`MenuBarExtra(.window)`):
1. Header: app icon 32, title (“Listening to Safari” / “Not listening”), subtitle (“Translating · ≈ 2.9 s behind · 1:12:40” / “Last: Hoshimi Kuu, yesterday, 3 h 40 min”), Stop button (live).
2. Idle only: full-width primary “Start Listening”.
3. Live only: four round toggles — Subtitles, Japanese (あ), Click-through, Pause (`aria-pressed`).
4. Attention banner when any warning/error is active (e.g. “**Monthly cap reached.** Translation is paused until Nov 15.” + “Open Usage”, “Translate Anyway”).
5. Rows: “Source [icon] Safari ›” and “Profile [avatar] Hoshimi Kuu ›” (inline submenus).
6. Spend: “Today $0.14”, “This cycle $6.12 of $100” + meter.
7. Items: Open Transcript ⌃⌥T · Explain Last Line ⌃⌥E (live) · Settings… ⌘, · — · Quit kikitori ⌘Q. Idle: “Open kikitori” instead of the first two.

### 5.10 Errors and edge cases (artboard 20)

| Case | Trigger | Overlay pill (one button max) | Window banner / alert | Clears |
|---|---|---|---|---|
| Permission revoked | tap creation/read fails with permission error mid-session | “**Audio access was turned off.**” [Open System Settings] | “kikitori can no longer hear apps. Turn on kikitori in Screen & System Audio Recording, then press Resume.” | user |
| Source app quit | `didTerminateApplication` for the source | “**Safari quit.** Waiting for it · 9:52” [Choose Source…] | same; after 10 min the session ends and is saved; notification “Session saved: Hoshimi Kuu, 1 h 13 min” | auto on relaunch |
| No audio | source alive, digital silence 60 s | “**No sound from Safari.** Is the stream paused or muted?” [Choose Source…]; if another app plays: “Chrome is playing sound. Switch to Chrome?” [Switch] | — | auto |
| Credits exhausted | API billing / credit-balance error | “**No API credits left** · Japanese only” [Claude Console] | “Your Claude account has no API credits left. Claim this month’s Max credits or add credits in the Claude Console.” Retry on Resume or every 10 min | user |
| Rate limited | 429 | “**Claude is busy.** Retrying in 20 s · Japanese only meanwhile” | — ; honour `retry-after`, backoff 2→4→8→30 s; queue ≤ 2 min, then drop from overlay but translate for the transcript | auto |
| Offline / outage | `NWPathMonitor` unsatisfied, or 3 consecutive failures / 5xx / 529 | “**Offline** · Japanese only” / “Claude isn’t responding · Japanese only” | on recovery: “Back online. Translating the last 4 minutes in the transcript…” | auto (probe 15 s) |
| Key invalid | 401/403 mid-session | “**Your API key stopped working** · Japanese only” [Update Key…] | opens Settings › Account with the field focused | user |
| Model missing / damaged | folder missing, checksum fail, Core ML load error | — (cannot start) | Alert “The speech model can’t be loaded” / ““Balanced” is missing or damaged. Download it again (1.6 GB), or use Apple Speech for now.” [Use Apple Speech] [Download Again] | user |
| Disk low | < 1 GB free (stop saving < 200 MB) | — | “**Your Mac is almost out of space.** This session may not be saved.” [Storage Settings] | auto |
| Thermal | `thermalState ≥ .serious` and median delay > 6 s | “**≈ 7.9 s behind.** Your Mac is hot.” [Use Light Model] | latency popover explains; dismiss = for this session; offer “Back to Balanced” after 10 min cool | auto |
| Falling behind | > 30 s untranslated queue | “**Skipped ahead to live.** Missed lines are in the transcript.” [Open] for 4 s | — | auto |
| Very long session | > 6 h or 5,000 lines | — | info: “**Long session: 6 h 12 min.** Everything is saved and searchable. Start a new session if this is a different stream.” [New Session] (once) | info |

Translator context is always bounded (profile + stream info + last 12 lines), so long sessions do not grow request size.

### 5.11 Notifications

Category per event, only when not frontmost, never during full-screen video unless it is an error that stops listening. Strings: “80 % of your monthly cap used” · “Monthly cap reached” · “Session saved: {streamer}, {duration}” · “Model ready” (“Balanced is downloaded and ready.”) · “Listening stopped” (“Audio access was turned off.”).

---

## 6. Copy conventions

- Voice: plain, short, second person, no exclamation marks except in sample content. Sentence case for messages, Title Case for buttons and menu items (macOS HIG).
- Use “Claude” for the service, the model names as “Claude Haiku 5.5” / “Claude Sonnet 5.5”, “Claude Console” for console.anthropic.com.
- Money: “$0.14” (2 decimals; 3 decimals below $0.01: “$0.004”). Time behind: “≈ 2.9 s behind”. Durations: “1 h 13 min”, timestamps “1:11:30”.
- Japanese stays Japanese in the UI (titles, terms); never romanise automatically except the reading column and explanation headers.
- Localisation: all strings in a String Catalog; English first, Japanese UI later (the layout already accommodates longer Japanese labels in Settings).

---

## 7. Accessibility (artboard 21)

- **VoiceOver**
  - Overlay = one element (`.accessibilityElement(children: .combine)`, summary) labelled “Subtitles, {profile}. “{latest line}”. {state}, about {n} seconds behind.” Custom actions: Pause, Explain Last Line, Open Transcript, Click-Through.
  - New lines are not announced by default (they would talk over the stream). Option “Announce new lines with VoiceOver” posts `AccessibilityNotification.Announcement` with low priority.
  - Non-normal state changes are always announced (“Offline. Japanese only.”).
  - Transcript row label: “{h} hours {m} minutes {s}. {English}. Japanese: {Japanese}. Has a note: {term}.” with actions Explain, Copy English, Copy Japanese. Japanese segments tagged `ja`.
  - 注 is read as “has a note”, speaker tags as “Speaker A, Kuu”, status pills as their words, meters as values (“Input level: medium”, updated ≤ 1×/s; “6 percent of monthly credit used, 23 percent projected”).
  - Icon-only buttons: labels listed in artboard 21 (“Pause listening” / “Resume listening”, “Explain last line”, “Show subtitles” toggle, “About 2.9 seconds behind”).
- **Keyboard**: full keyboard access everywhere; focus order sidebar → toolbar → session header → transcript → inspector. Shortcuts: ⌘1–4 sections, ↑↓ lines, ↩ explain, ⌘C / ⌥⌘C copy, ⌘F search, ⌘↓/End jump to live, ⌘+/⌘− text size, ⌥⌘I inspector, ⇧⌘E export, ⌘N new profile. The overlay is never key; it is reached via hotkeys and the menu bar.
- **Reduce Motion**: see §2.6.
- **Reduce Transparency**: overlay switches to the solid style; system surfaces handle themselves.
- **Increase Contrast**: separators 1 pt at 30 %, 1 pt outline on note markers and chips, secondary text at `.primary` 80 %, overlay older line 80 %, overlay edge 1.5 pt.
- **Colour independence**: notes = glyph + term + underline; speakers = letter/name + colour; states = icon + words; results = icon + words + colour. Colour pairs that must differ also differ in lightness.
- **Text size**: overlay 12–60 pt; transcript 13–24 pt; layouts grow vertically; only list titles truncate (full text in tooltip and VoiceOver).
- Contrast numbers in §2.1; all text ≥ 4.5:1 including 11 pt captions.

---

## 8. Decisions taken in this design (confirm or change)

1. **Accent “Fuji” wisteria** #6A4FD8 / #6E56E0 (fill), #5E43CF / #A894FF (text). Vermilion was rejected because it collides with error red.
2. **Information architecture**: one main window with sidebar Live · Sessions · Profiles · Usage; “transcript window” = the Live section. Settings is the separate macOS Settings window.
3. **Pause = stop capturing** (nothing captured or sent). Budget/offline pauses are “Japanese only”, a different state.
4. **Overlay stays dark** by default even over bright video; Light glass and Outline are opt-in styles.
5. **Normal pipeline states are invisible at rest** (only in-line cues); a pill appears only for abnormal states.
6. **Speaker labels default off** (“best effort, uses more CPU”); no labels is the designed normal case.
7. **Glossary column “Translate as”** replaces the brief’s “notes” column; free notes go in Meaning and the profile notes field.
8. **Budget**: cap default $100 (the Max credit), range $1–$500, warn at 80 % of the cap, default action “Japanese only”, “Translate This Session Anyway” override.
9. **Missed lines** after offline/rate limits are translated later for the transcript only (this costs money; it is small, but confirm).
10. **Retention** default 1 year; explanations saved with transcripts.
11. **Hotkeys** all ⌃⌥ + letter; Start/Stop has no default.
12. Onboarding has 4 counted steps (Audio, Claude, Speech, Try it); the test step can be skipped.

## 9. Open questions

1. **Capture API**: the design assumes Core Audio process taps (audio-only TCC, “System Audio Recording”). If ScreenCaptureKit is used instead, the permission copy must say “Screen & System Audio Recording” without “audio only”, and window titles become available for the source row. Which one?
2. **Permission status check**: there is no public preflight for audio capture; the design checks by opening a test tap. Confirm this is acceptable (it can trigger the prompt).
3. **Billing cycle**: no public API exposes the Max billing cycle or remaining credit; the design uses a user-set cycle day and estimates spend from token usage × a shipped price table. OK?
4. **Model choices and sizes** for Light/Balanced/Best (and whether Apple Speech is offered) depend on the bench results.
5. **Exact model IDs** for Claude Haiku 5.5 / Sonnet 5.5 and their prices belong in app config; confirm the source of truth (Models API + config file).
6. Should the overlay be **one per display** or follow the source window (attach to the browser’s video window)? Design: one overlay, position saved per display.
7. **Glossary size warning** threshold (design: 2,000 tokens).
8. **Japanese UI localisation** in v1, or English only?
