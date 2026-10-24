import KikitoriCore
import ServiceManagement
import SwiftUI

/// Settings window (spec §5.8): General, Audio, Speech, Translation, Overlay, Hotkeys, Account.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            AudioTab().tabItem { Label("Audio", systemImage: "waveform") }
            SpeechTab().tabItem { Label("Speech", systemImage: "text.alignleft") }
            TranslationTab().tabItem { Label("Translation", systemImage: "translate") }
            OverlayTab().tabItem { Label("Overlay", systemImage: "captions.bubble") }
            HotkeysTab().tabItem { Label("Hotkeys", systemImage: "command") }
            AccountTab().tabItem { Label("Account", systemImage: "key") }
        }
        .frame(width: 680)
        .scenePadding()
    }
}

struct GeneralTab: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var pendingRetention: Preferences.Retention?

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Toggle("Show in Dock", isOn: $prefs.showInDock)
                Text("Only while a kikitori window is open.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sessions") {
                Picker("End session after silence", selection: $prefs.endAfterSilenceMinutes) {
                    Text("5 min").tag(5); Text("10 min").tag(10); Text("30 min").tag(30); Text("Never").tag(0)
                }
            }
            Section("History") {
                Picker("Keep sessions", selection: Binding(get: { prefs.retention }, set: { new in
                    let removed = new.days.map { model.sessionStore.olderThan(Calendar.current.date(byAdding: .day, value: -$0, to: .now)!).count } ?? 0
                    if removed > 0 { pendingRetention = new } else { prefs.retention = new }
                })) {
                    ForEach(Preferences.Retention.allCases, id: \.self) { Text($0.rawValue) }
                }
                Toggle("Save explanations with transcripts", isOn: $prefs.saveExplanations)
            }
            Section {
                Button("Run Setup Again…") { prefs.onboardingDone = false; openWindow(id: "onboarding") }
            }
        }
        .formStyle(.grouped)
        .alert("Remove older sessions?", isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button("Remove Sessions", role: .destructive) {
                if let r = pendingRetention { prefs.retention = r; model.applyRetention() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing to \(pendingRetention?.rawValue ?? "") deletes older sessions now.")
        }
    }
}

struct AudioTab: View {
    @Environment(AppModel.self) var model
    @State private var showPicker = false
    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Source") {
                LabeledContent("Listen to") {
                    Button(model.source?.name ?? "Choose…") { showPicker = true }
                        .popover(isPresented: $showPicker) { SourcePickerView() }
                }
                Text("kikitori hears only the app you pick: other apps, notifications and your voice are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech detection") {
                LabeledContent("Detector", value: "Silero VAD on the Neural Engine")
                Text("Speech is cut at natural pauses; silence and music are never sent to the speech model.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Label speakers in collabs", isOn: $prefs.speakerLabels)
                Text("Best effort. Uses more CPU. Up to four voices, A to D; right-click a line to name one. Takes effect from the next session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SpeechTab: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Model") {
                Picker("Speech model", selection: $prefs.speechModel) {
                    Text("Apple Speech · built into macOS · Recommended").tag(Preferences.SpeechModel.apple)
                }
                .pickerStyle(.radioGroup)
                Text("In tests on real VTuber streams, Apple Speech matched Whisper Large v3 Turbo in the live pipeline while running about 3× faster with no download. Whisper Turbo arrives as an optional model in a later version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Chunks") {
                LabeledContent("Longest chunk") {
                    Picker("", selection: $prefs.maxChunk) {
                        Text("4 s · fastest").tag(4.0); Text("6 s · recommended").tag(6.0)
                        Text("10 s").tag(10.0); Text("15 s · most context").tag(15.0)
                    }
                    .labelsHidden().fixedSize()
                }
                Text("Speech is cut at sentence ends; this caps a chunk when someone talks without pausing. Shorter means subtitles sooner. Takes effect at the next session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TranslationTab: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                Toggle("Translate as you listen", isOn: Binding(get: { prefs.translate }, set: { model.setTranslate($0) }))
            } footer: {
                Text("Off: lines stay Japanese, transcribed on this Mac for free. On: each line is also sent to Claude Haiku for English, which uses API credits. Explanations are always on demand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Translation") {
                LabeledContent("Translate into", value: prefs.translation.targetLanguage)
                LabeledContent("Style") {
                    HStack {
                        Text("Literal").font(.caption)
                        Slider(value: Binding(get: { Double(prefs.translation.style) }, set: { prefs.translation.style = Int($0) }),
                               in: 1...5, step: 1).frame(width: 200)
                        Text("Natural").font(.caption)
                    }
                }
                Picker("Honorifics (-chan, -san, -senpai)", selection: $prefs.translation.keepHonorifics) {
                    Text("Keep").tag(true); Text("Translate").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Mark lines that need context (注)", isOn: $prefs.translation.markNotes)
                VStack(alignment: .leading, spacing: 4) {
                    Text("リオちゃん、マネちゃんに怒られちゃうよ").font(.japanese(13)).foregroundStyle(.secondary)
                    Text(prefs.translation.keepHonorifics ? "Rio-chan, my manager’s going to scold me." : "Rio, my manager’s going to scold me.")
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
            Section("Original text") {
                Picker("Transcript shows", selection: $prefs.transcriptMode) {
                    ForEach(Preferences.TranscriptMode.allCases, id: \.self) { Text($0.title) }
                }
            }
            Section("Claude models") {
                LabeledContent("Live subtitles", value: "Claude Haiku 5.5")
                LabeledContent("Explanations", value: "Claude Sonnet 5.5")
            }
        }
        .formStyle(.grouped)
    }
}

struct OverlayTab: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Text") {
                Picker("Size", selection: $prefs.textSize) {
                    ForEach(Preferences.TextSize.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Stepper("Lines: \(prefs.overlayLines)", value: $prefs.overlayLines, in: 1...4)
            }
            Section("Look") {
                Picker("Style", selection: $prefs.overlayStyle) {
                    ForEach(Preferences.OverlayStyle.allCases, id: \.self) { Text($0.rawValue) }
                }
                LabeledContent("Background opacity") {
                    Slider(value: $prefs.overlayOpacity, in: 0.3...1).frame(width: 220)
                }
            }
            Section("Behaviour") {
                Picker("Position", selection: $prefs.position) {
                    ForEach(Preferences.Position.allCases, id: \.self) { Text($0.rawValue) }
                }
                Toggle("Click-through", isOn: $prefs.clickThrough)
                Toggle("Hide when no one is speaking", isOn: $prefs.hideWhenSilent)
                Toggle("Always show delay", isOn: $prefs.alwaysShowDelay)
            }
        }
        .formStyle(.grouped)
    }
}

struct HotkeysTab: View {
    var body: some View {
        Form {
            Section {
                ForEach(Hotkeys.Action.allCases, id: \.self) { action in
                    LabeledContent(action.title) { Text(action.label).font(.body.monospaced()) }
                }
            } footer: {
                Text("Shortcuts work in every app, also over full-screen video.")
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountTab: View {
    @Environment(AppModel.self) var model
    @State private var key = ""
    @State private var status = ""
    @State private var confirmRemove = false
    @State private var confirmDeleteData = false

    var body: some View {
        Form {
            Section("Claude") {
                if let saved = KeychainStore.apiKey() {
                    LabeledContent("API key") {
                        HStack {
                            Text("sk-ant-…\(saved.suffix(4)) · in Keychain").font(.body.monospaced())
                            Button("Remove…") { confirmRemove = true }
                        }
                    }
                } else {
                    LabeledContent("API key") {
                        HStack {
                            SecureField("sk-ant-…", text: $key).frame(width: 260)
                            Button("Save") { save() }.disabled(!key.hasPrefix("sk-ant-"))
                        }
                    }
                }
                if !status.isEmpty { Text(status).font(.caption) }
                Picker("Billing cycle starts on", selection: Binding(get: { model.prefs.cycleStartDay }, set: { model.setCycleStartDay($0) })) {
                    ForEach(1...28, id: \.self) { Text("Day \($0)").tag($0) }
                }
            }
            Section("What is sent to Claude") {
                Label("Japanese text of each chunk", systemImage: "checkmark")
                Label("The profile: names, glossary, notes", systemImage: "checkmark")
                Label("Stream title and game", systemImage: "checkmark")
                Label("For Explain: that line and nearby lines", systemImage: "checkmark")
                Label("Audio, ever", systemImage: "xmark").foregroundStyle(.secondary)
                Label("Your screen or other apps", systemImage: "xmark").foregroundStyle(.secondary)
                Label("Past sessions or anything about you", systemImage: "xmark").foregroundStyle(.secondary)
                Text("Requests go straight from this Mac to Anthropic’s API; there is no kikitori server.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Data on this Mac") {
                LabeledContent("Transcripts, profiles, usage") { Text(model.dataFolder.path).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.dataFolder]) }
                    Button("Delete All…", role: .destructive) { confirmDeleteData = true }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Remove the API key?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { try? KeychainStore.removeAPIKey(); model.hasAPIKey = false; status = "" }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Translation stops until you add a key again.") }
        .alert("Delete all kikitori data?", isPresented: $confirmDeleteData) {
            Button("Delete All", role: .destructive) { model.deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Sessions, profiles and usage history are removed. Your API key and settings stay.") }
    }

    func save() {
        status = "Checking key…"
        let candidate = key
        Task {
            let result = await KeyCheck.check(candidate)
            status = result.message
            if result.shouldSave, (try? KeychainStore.setAPIKey(candidate)) != nil { model.hasAPIKey = true; key = "" }
        }
    }
}
