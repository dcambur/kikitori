import KikitoriCore
import SwiftUI

/// First-run setup, 640 × 520 (spec §5.1): Welcome → Audio → Claude → Speech → Try it → Done.
struct OnboardingView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismissWindow) var dismissWindow
    @AppStorage("onboardingStep") var step = 0

    var body: some View {
        VStack(spacing: 0) {
            if (1...4).contains(step) {
                HStack(spacing: 6) {
                    ForEach(1...4, id: \.self) { i in
                        Capsule().fill(i <= step ? Color.kkAccentFill : Color.secondary.opacity(0.25)).frame(width: 30, height: 4)
                    }
                }
                .padding(.top, 14)
                .accessibilityElement().accessibilityLabel("Step \(step) of 4")
            }
            Group {
                switch step {
                case 0: WelcomeStep(next: next)
                case 1: AudioStep(back: back, next: next)
                case 2: ClaudeStep(back: back, next: next)
                case 3: SpeechStep(back: back, next: next)
                case 4: TryStep(back: back, next: next)
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
            Text("Live English subtitles for Japanese streams, with the context behind the jokes.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                feature("speaker.wave.2", "Hears the stream", "Listens to one app, like Safari or Chrome. No extra audio drivers.")
                feature("waveform", "Transcribes on your Mac", "Japanese speech becomes text on-device. Audio never leaves your Mac.")
                feature("translate", "Translates with Claude", "Subtitles arrive 2–5 seconds behind. Click any line to learn the slang, meme or reference.")
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
            VStack(alignment: .leading, spacing: 2) { Text(title).bold(); Text(text).font(.callout).foregroundStyle(.secondary) }
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
                Label("Audio is turned into text on this Mac and then discarded. Nothing is recorded to disk unless you export a transcript.", systemImage: "lock")
                    .font(.callout).padding(12).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
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

struct ClaudeStep: View {
    @Environment(AppModel.self) var model
    let back: () -> Void, next: () -> Void
    @State private var key = ""
    @State private var result: KeyCheck.Result?
    @State private var checking = false
    @State private var showHelp = true

    var body: some View {
        StepLayout(back: back) {
            StepIcon(symbol: "key")
            Text("Connect Claude").font(.system(size: 26, weight: .bold))
            Text("kikitori translates with your own Claude API key. Your Max plan includes monthly API credits.").foregroundStyle(.secondary)
            if let saved = KeychainStore.apiKey(), result == nil {
                Label("Key in Keychain: sk-ant-…\(saved.suffix(4))", systemImage: "checkmark.circle.fill").foregroundStyle(Color.kkSuccess)
            } else {
                HStack {
                    SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button("Paste") { key = NSPasteboard.general.string(forType: .string) ?? "" }
                }
                Text("Stored in your Mac’s Keychain. Sent only to Anthropic.").font(.caption).foregroundStyle(.secondary)
            }
            if checking { HStack { ProgressView().controlSize(.small); Text("Checking key…") } }
            if let result {
                Text(result.message).font(.callout)
                    .foregroundStyle(result == .valid ? Color.kkSuccess : result == .invalid ? Color.kkDanger : Color.kkNote)
            }
            DisclosureGroup("How do I get a key?", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Open the Claude Console and sign in with your Claude account.")
                    Text("2. Claim the API credits included with your Max plan.")
                    Text("3. Go to API Keys › Create Key, name it “kikitori”, and copy it.")
                    Link("Open Claude Console ↗", destination: URL(string: "https://console.anthropic.com")!)
                }
                .font(.callout).multilineTextAlignment(.leading)
            }
        } actions: {
            if KeychainStore.apiKey() != nil && result == nil {
                Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(result?.shouldSave == true ? "Continue" : "Check Key") {
                    if result?.shouldSave == true { next() } else { check() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(key.count < 20 || checking)
            }
        }
    }

    func check() {
        checking = true
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let r = await KeyCheck.check(candidate)
            if r.shouldSave { try? KeychainStore.setAPIKey(candidate); model.hasAPIKey = true }
            result = r
            checking = false
        }
    }
}

struct SpeechStep: View {
    let back: () -> Void, next: () -> Void
    @State private var preparing = false
    @State private var failure: String?

    var body: some View {
        StepLayout(back: back) {
            StepIcon(symbol: "waveform")
            Text("Speech recognition").font(.system(size: 26, weight: .bold))
            Text("Japanese speech is recognised on your Mac with Apple’s on-device model: no download from kikitori, and it runs on the Neural Engine.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "apple.logo").font(.title2)
                VStack(alignment: .leading) {
                    HStack { Text("Apple Speech").bold(); Text("Recommended").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(Color.kkAccentSoft, in: .capsule) }
                    Text("Built into macOS · tested best on real VTuber streams").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.kkAccentSoft, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.kkAccentFill, lineWidth: 2))
            if preparing { HStack { ProgressView().controlSize(.small); Text("Preparing the Japanese model…") } }
            if let failure { Text(failure).foregroundStyle(Color.kkDanger) }
        } actions: {
            Button("Continue") { prepare() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(preparing)
        }
    }

    func prepare() {
        preparing = true
        Task {
            do { try await AppleSpeechEngine().prepare(); next() }
            catch { failure = "macOS couldn’t install the Japanese speech model: \(error.localizedDescription)" }
            preparing = false
        }
    }
}

struct TryStep: View {
    @Environment(AppModel.self) var model
    let back: () -> Void, next: () -> Void
    @State private var showPicker = false

    var lines: [TranscriptLine] { Array((model.session?.lines ?? []).suffix(2)) }
    var works: Bool { lines.contains { $0.en != nil } }

    var body: some View {
        StepLayout(back: back) {
            Text("Try it").font(.system(size: 26, weight: .bold))
            Text("Play any Japanese video or stream. Subtitles appear here, about 2–5 seconds behind the voice.").foregroundStyle(.secondary)
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
                        if let en = line.en { Text(en).font(.overlay(18)).foregroundStyle(.white) } else { TranslatingDots(color: .white) }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Color.overlaySolid, in: .rect(cornerRadius: 16))
            if works, let latency = model.latency {
                Label(String(format: "It works · %.1f s behind", latency), systemImage: "checkmark.circle.fill").foregroundStyle(Color.kkSuccess)
            }
        } actions: {
            Button("Skip", action: next)
            Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!works)
        }
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
                GridRow { Text("Translation").foregroundStyle(.secondary); Text("Claude Haiku 5.5 → English") }
                GridRow { Text("Monthly budget").foregroundStyle(.secondary); Text("\(Money.format(model.prefs.monthlyCap)) credit · warn at 80 %") }
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
