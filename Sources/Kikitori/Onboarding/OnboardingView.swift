import KikitoriCore
import SwiftUI

/// First-run setup, 640 × 520 (spec §5.1): Welcome → Audio → English (optional) → Try it → Done.
/// Japanese works with no account; English and explanations are an explicit, paid choice.
struct OnboardingView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismissWindow) var dismissWindow
    @AppStorage("onboardingStep") var step = 0

    var body: some View {
        VStack(spacing: 0) {
            if (1...3).contains(step) {
                HStack(spacing: 6) {
                    ForEach(1...3, id: \.self) { i in
                        Capsule().fill(i <= step ? Color.kkAccentFill : Color.secondary.opacity(0.25)).frame(width: 30, height: 4)
                    }
                }
                .padding(.top, 14)
                .accessibilityElement().accessibilityLabel("Step \(step) of 3")
            }
            Group {
                switch step {
                case 0: WelcomeStep(next: next)
                case 1: AudioStep(back: back, next: next)
                case 2: ClaudeStep(back: back, next: next)
                case 3: TryStep(back: back, next: next)
                default: DoneStep(finish: finish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 520)
    }

    func next() { step += 1 }
    func back() { step = max(step - 1, 0) }
    func finish() {
        model.prefs.onboardingDone = true
        step = 0
        dismissWindow(id: "onboarding")
        openMainWindow()
    }
}

/// Shared step layout: centred column, Back on the left, actions on the right.
struct StepLayout<Content: View, Actions: View>: View {
    var back: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            VStack(spacing: 14) { content }.frame(maxWidth: 470).multilineTextAlignment(.center)
            Spacer(minLength: 12)
            HStack {
                if let back { Button("Back", action: back).keyboardShortcut("[", modifiers: .command) }
                Spacer()
                actions
            }
            .padding(20)
        }
        .padding(.horizontal, 48)
    }
}

struct StepIcon: View {
    let symbol: String
    var tint: Color = .kkAccentFill
    var body: some View {
        Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(tint)
            .frame(width: 60, height: 60).background(tint.opacity(0.12), in: .rect(cornerRadius: 14))
    }
}

struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        StepLayout {
            Text("聞").font(.japanese(40, weight: .bold)).foregroundStyle(.white)
                .frame(width: 84, height: 84).background(Color.kkAccentFill, in: .rect(cornerRadius: 20))
            Text("Welcome to kikitori").font(.system(size: 26, weight: .bold))
            Text("Live subtitles for Japanese streams, with English and the context behind the jokes when you want them.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                feature("speaker.wave.2", "Hears the stream", "Listens to one app, like Safari or Chrome, or plays YouTube right in kikitori.")
                feature("waveform", "Transcribes on your Mac", "Japanese speech becomes text on-device, free. Audio never leaves your Mac.")
                feature("translate", "English with Claude, if you want it", "Optional: translations and explanations use your own Claude API credits.")
            }
            .multilineTextAlignment(.leading)
            .padding(.top, 8)
        } actions: {
            Button("Get Started", action: next).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.kkAccent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AudioStep: View {
    let back: () -> Void, next: () -> Void
    enum Access { case unknown, granted, denied }
    @State private var access = Access.unknown

    var body: some View {
        StepLayout(back: back) {
            switch access {
            case .unknown:
                StepIcon(symbol: "speaker.wave.2")
                Text("Let kikitori hear your apps").font(.system(size: 26, weight: .bold))
                Text("kikitori listens to the sound of one app you choose. macOS calls this permission **System Audio Recording**. kikitori records audio only, never your screen.")
                    .foregroundStyle(.secondary)
                Label("Audio is turned into text on this Mac and never saved: the last half hour stays in memory so you can replay a line, and goes when you stop.", systemImage: "lock")
                    .font(.callout).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .padding(12).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            case .granted:
                StepIcon(symbol: "checkmark", tint: .kkSuccess)
                Text("Audio access is on").font(.system(size: 26, weight: .bold))
                Text("You can turn it off any time in System Settings › Privacy & Security › Screen & System Audio Recording.")
                    .foregroundStyle(.secondary)
            case .denied:
                StepIcon(symbol: "exclamationmark.triangle", tint: .kkNote)
                Text("kikitori can’t hear your apps yet").font(.system(size: 26, weight: .bold))
                Text("Audio access is turned off. Turn it on in System Settings, then come back here.").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click **Open System Settings**.")
                    Text("2. Under **Screen & System Audio Recording**, turn on **kikitori**.")
                    Text("3. If macOS asks, choose **Quit & Reopen**. kikitori comes back to this step.")
                }
                .multilineTextAlignment(.leading)
            }
        } actions: {
            switch access {
            case .unknown:
                Button("Allow Audio Access") { request() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .granted:
                Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .denied:
                Button("Check Again") { request() }
                Button("Open System Settings") { openPrivacySettings() }.buttonStyle(.borderedProminent)
            }
        }
    }

    /// Opening a short test tap is the only way to ask for (or check) the permission.
    func request() {
        Task {
            let source = try? AudioSources.list().first
            guard let source else { access = .granted; return }  // nothing to tap yet: the session will ask
            let capture = ProcessTapCapture()
            do {
                try capture.start(processObjects: source.processObjects)
                try? await Task.sleep(for: .milliseconds(400))
                capture.stop()
                access = .granted
                try? await Task.sleep(for: .seconds(1.5))
                if access == .granted { next() }
            } catch {
                access = .denied
            }
        }
    }
}

/// English is a choice, not a requirement: Japanese only is free and needs no account; English
/// (and explanations) send text to Claude with the user's own API key and use its credits.
struct ClaudeStep: View {
    @Environment(AppModel.self) var model
    let back: () -> Void, next: () -> Void
    @State private var english = false
    @State private var key = ""
    @State private var result: KeyCheck.Result?
    @State private var checking = false
    @State private var showHelp = false

    var savedKey: String? { KeychainStore.apiKey() }
    /// English is ready: a key that works (or was already saved).
    var keyReady: Bool { (savedKey != nil && result == nil) || result?.shouldSave == true }

    var body: some View {
        StepLayout(back: back) {
            StepIcon(symbol: "translate")
            Text("Do you want English?").font(.system(size: 26, weight: .bold))
            Text("kikitori always shows the Japanese. It can also translate every line with Claude. You can change this any time.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                choice("Japanese only", "Free · nothing leaves your Mac", "character.ja", selected: !english) { english = false }
                choice("Japanese + English", "Uses your Claude API credits", "translate", selected: english) { english = true }
            }
            if english {
                if let saved = savedKey, result == nil {
                    Label("Key in Keychain: sk-ant-…\(saved.suffix(4))", systemImage: "checkmark.circle.fill").foregroundStyle(Color.kkSuccess)
                } else {
                    HStack {
                        SecureField("Claude API key (sk-ant-…)", text: $key).textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Button("Paste") { key = NSPasteboard.general.string(forType: .string) ?? "" }
                    }
                    Text("Stored in your Mac’s Keychain. Sent only to Anthropic.").font(.caption).foregroundStyle(.secondary)
                }
                if checking { HStack { ProgressView().controlSize(.small); Text("Checking key…") } }
                if let result {
                    Text(result.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(result == .valid ? Color.kkSuccess : result == .invalid ? Color.kkDanger : Color.kkNote)
                }
                DisclosureGroup("How do I get a key?", isExpanded: $showHelp) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open the Claude Console and sign in with your Claude account.")
                        Text("2. Claim the API credits included with your Max plan, or add credits.")
                        Text("3. Go to API Keys › Create Key, name it “kikitori”, and copy it.")
                        Link("Open Claude Console ↗", destination: URL(string: "https://console.anthropic.com")!)
                    }
                    .font(.callout).multilineTextAlignment(.leading)
                }
            }
        } actions: {
            if !english || keyReady {
                Button("Continue") { model.setTranslate(english); next() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Check Key") { check() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(key.count < 20 || checking)
            }
        }
        .onAppear { english = model.prefs.translate }
    }

    func choice(_ title: String, _ detail: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected ? Color.kkAccentSoft : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.kkAccentFill : .clear, lineWidth: 2))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func check() {
        checking = true
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let r = await KeyCheck.check(candidate)
            if r.shouldSave { try? KeychainStore.setAPIKey(candidate) }
            model.hasAPIKey = KeychainStore.apiKey() != nil   // what the Keychain holds, saved or not
            result = r
            checking = false
        }
    }
}

struct TryStep: View {
    @Environment(AppModel.self) var model
    let back: () -> Void, next: () -> Void
    @State private var showPicker = false

    @State private var preparing = false
    @State private var modelFailure: String?

    var lines: [TranscriptLine] { Array((model.session?.lines ?? []).suffix(2)) }
    /// Japanese on screen is success; English only when translation is on.
    var works: Bool { !lines.isEmpty }

    var body: some View {
        StepLayout(back: back) {
            Text("Try it").font(.system(size: 26, weight: .bold))
            Text("Play any Japanese video or stream. Its Japanese appears here a moment after it’s spoken\(model.prefs.translate ? ", with English a few seconds later" : "").")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if preparing { HStack { ProgressView().controlSize(.small); Text("Preparing Apple’s Japanese speech model…") }.font(.callout) }
            if let modelFailure { Text(modelFailure).font(.callout).foregroundStyle(Color.kkDanger) }
            HStack {
                Text("Listen to")
                Button(model.source?.name ?? "Choose an App…") { showPicker = true }
                    .popover(isPresented: $showPicker) { SourcePickerView() }
            }
            VStack(spacing: 6) {
                if lines.isEmpty {
                    Text(model.isLive ? "Waiting for Japanese speech…" : "Pick the app that plays the video.")
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    ForEach(lines) { line in
                        Text(line.ja).font(.japanese(13)).foregroundStyle(.white.opacity(0.8))
                        if let en = line.en { Text(en).font(.overlay(18)).foregroundStyle(.white) }
                        else if model.pendingLines.contains(line.id) { TranslatingDots(color: .white) }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Color.overlaySolid, in: .rect(cornerRadius: 16))
            if works {
                Label("It works", systemImage: "checkmark.circle.fill").foregroundStyle(Color.kkSuccess)
            }
        } actions: {
            Button("Skip", action: next)
            Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!works)
        }
        .task { await prepareSpeech() }
    }

    /// Apple's Japanese model is a system download: start it now, so the first session starts at once.
    func prepareSpeech() async {
        preparing = true
        do { try await AppleSpeechEngine().prepare() }
        catch { modelFailure = "macOS couldn’t install the Japanese speech model: \(error.localizedDescription)" }
        preparing = false
    }
}

struct DoneStep: View {
    @Environment(AppModel.self) var model
    let finish: () -> Void
    var body: some View {
        StepLayout {
            StepIcon(symbol: "checkmark", tint: .kkSuccess)
            Text("You’re all set").font(.system(size: 26, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Listening to").foregroundStyle(.secondary); Text(model.source?.name ?? "Choose when you start") }
                GridRow { Text("Speech model").foregroundStyle(.secondary); Text("Apple Speech, on this Mac") }
                GridRow {
                    Text("English").foregroundStyle(.secondary)
                    Text(model.prefs.translate ? "On · Claude Haiku 5.5, uses API credits" : "Off · turn on any time with Translate")
                }
                if model.prefs.translate {
                    GridRow { Text("Monthly budget").foregroundStyle(.secondary); Text("\(Money.format(model.prefs.monthlyCap)) credit · warn at 80 %") }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("⌃⌥S  Show or hide subtitles")
                Text("⌃⌥E  Explain the last line")
                Text("kikitori lives in the menu bar · Add a streamer profile for better names and slang.")
            }
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        } actions: {
            Button(model.isLive ? "Done" : "Open kikitori", action: finish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }
}
