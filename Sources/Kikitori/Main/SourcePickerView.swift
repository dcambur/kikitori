import KikitoriCore
import SwiftUI

/// Pick the app to listen to (spec §5.4). Shown in a popover; picking starts or switches the session.
struct SourcePickerView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var sources: [AudioSource] = []
    @State private var failed = false
    @State private var tab = 0
    @State private var devices: [InputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) { Text("Apps").tag(0); Text("Input Devices").tag(1) }
                .pickerStyle(.segmented).labelsHidden()
            if tab == 1 {
                Label("A microphone also hears your room. App audio is cleaner when the stream plays on this Mac.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(devices) { device in
                    Button { pick(AudioSource(id: "mic:\(device.id)", name: device.name, pid: 0, processObjects: [], isPlaying: true)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mic").frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.source?.id == "mic:\(device.id)" { Image(systemName: "checkmark").foregroundStyle(Color.kkAccent) }
                        }
                        .frame(height: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } else if failed {
                Label("kikitori can’t list apps", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.kkDanger)
                Text("Turn on kikitori in System Settings › Privacy & Security › Screen & System Audio Recording.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open System Settings") { openPrivacySettings() }
            } else if sources.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No app is playing sound").bold()
                    Text("Start the stream, then pick its app here.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                let playing = sources.filter(\.isPlaying)
                let silent = sources.filter { !$0.isPlaying }
                if !playing.isEmpty { section("Playing sound", playing) }
                if !silent.isEmpty { section("Other apps", silent) }
            }
            Divider()
            Text("Only this app’s sound is heard. Other apps, notifications and your voice are ignored.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 380)
        .task {
            devices = InputDevice.list()
            while !Task.isCancelled {
                do { sources = try AudioSources.list(); failed = false } catch { failed = true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func section(_ title: String, _ list: [AudioSource]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(list) { source in
                Button { pick(source) } label: {
                    HStack(spacing: 10) {
                        AppIcon(bundleID: source.id)
                        VStack(alignment: .leading) {
                            Text(source.name).foregroundStyle(source.isPlaying ? .primary : .secondary)
                            Text(source.isPlaying ? "playing" : "silent").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.source?.id == source.id { Image(systemName: "checkmark").foregroundStyle(Color.kkAccent) }
                    }
                    .frame(height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    func pick(_ source: AudioSource) {
        dismiss()
        Task {
            if model.isLive { model.stop() }
            await model.start(source: source)
        }
    }
}

/// Export Transcript (spec §5.3): SRT / WebVTT / Markdown with a live preview.
struct ExportSheet: View {
    let lines: [TranscriptLine]
    let explanations: [UUID: [Explainer.Explanation]]
    let name: String
    @Environment(\.dismiss) var dismiss
    @State private var export = TranscriptExport()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Transcript").font(.title3.bold())
            Picker("Format", selection: $export.format) {
                ForEach(TranscriptExport.Format.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle("English", isOn: $export.includeEnglish)
            Toggle("Japanese (above English)", isOn: $export.includeJapanese)
            Toggle("Speaker labels", isOn: $export.includeSpeakers)
            Toggle("Notes and explanations", isOn: $export.includeNotes).disabled(export.format != .markdown)
            Text("Preview").font(.caption.bold()).foregroundStyle(.secondary)
            Text(String(export.render(Array(lines.prefix(2)), explanations: explanations).prefix(400)))
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                .padding(8).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack {
                Text("\(lines.count) lines").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(export.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? export.render(lines, explanations: explanations, title: name).write(to: url, atomically: true, encoding: .utf8)
        dismiss()
    }
}
