import KikitoriCore
import SwiftUI
import UniformTypeIdentifiers

/// Main window › Profiles (spec §5.5).
struct ProfilesView: View {
    @Environment(AppModel.self) var model
    @State private var selection: UUID?
    @State private var filter = ""
    @State private var showNew = false
    @State private var importing: (Profile, target: Profile?)?
    @State private var importError: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No streamer profiles", systemImage: "person.crop.circle")
                    } description: {
                        Text("A profile teaches the translator a streamer’s names, fan name, catchphrases and running jokes.")
                    } actions: {
                        Button("Import…") { importFile() }
                        Button("New Profile") { showNew = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(model.profiles.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.nameJa.contains(filter) }) { p in
                            HStack(spacing: 10) {
                                Avatar(profile: p, size: 28)
                                VStack(alignment: .leading) {
                                    Text(p.name)
                                    Text("\(p.glossary.count) terms").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.activeProfileID == p.id && model.isLive {
                                    Text("Live").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.kkAccentSoft, in: .capsule)
                                }
                            }
                            .tag(p.id)
                        }
                    }
                    .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
                }
            }
            .frame(minWidth: 230, idealWidth: 250, maxWidth: 300)

            Group {
                if let id = selection, let index = model.profiles.firstIndex(where: { $0.id == id }) {
                    ProfileEditor(profile: Binding(get: { model.profiles[index] }, set: { model.profiles[index] = $0 }),
                                  importAction: importFile)
                        .id(id)
                } else {
                    ContentUnavailableView("No profile selected", systemImage: "person.crop.circle")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Profiles")
        .toolbar {
            Button { showNew = true } label: { Label("New Profile", systemImage: "plus") }.keyboardShortcut("n")
        }
        .sheet(isPresented: $showNew) { NewProfileSheet { p in model.upsert(p); selection = p.id } }
        .sheet(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            if let (incoming, target) = importing {
                ImportSheet(incoming: incoming, target: target) { p in model.upsert(p); selection = p.id }
            }
        }
        .alert("This file isn’t a kikitori profile.", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: { Text(importError ?? "") }
        .onChange(of: model.profiles) { model.saveProfiles() }
        .onAppear { if selection == nil { selection = model.profiles.first?.id } }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try ProfileFile.parse(Data(contentsOf: url))
            importing = (p, model.profiles.first { $0.name == p.name })
        } catch {
            importError = "\(error)"
        }
    }
}

struct Avatar: View {
    let profile: Profile
    var size: CGFloat = 28
    var body: some View {
        Circle().fill(Color(hexString: profile.colour))
            .frame(width: size, height: size)
            .overlay(Text(String((profile.nameJa.isEmpty ? profile.name : profile.nameJa).prefix(1)))
                .font(.japanese(size * 0.45, weight: .bold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

struct ProfileEditor: View {
    @Environment(AppModel.self) var model
    @Binding var profile: Profile
    let importAction: () -> Void
    @State private var selectedTerms: Set<GlossaryTerm.ID> = []
    @State private var confirmDelete = false

    var tokens: Int { profile.promptBlock.count / 2 }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Avatar(profile: profile, size: 40)
                    VStack(alignment: .leading) {
                        Text(profile.name).font(.title2.bold())
                        if !profile.nameJa.isEmpty { Text(profile.nameJa).font(.japanese(13)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(model.activeProfileID == profile.id ? "In Use This Session" : "Use for This Session") {
                        model.activeProfileID = profile.id
                    }
                    .disabled(model.activeProfileID == profile.id)
                    Menu {
                        Button("Import…", action: importAction)
                        Button("Export Profile…") { export() }
                        Divider()
                        Button("Duplicate") {
                            var copy = profile; copy.id = UUID(); copy.name += " copy"; model.upsert(copy)
                        }
                        Button("Delete…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            Section {
                TextField("Name (English)", text: $profile.name)
                TextField("Name (Japanese)", text: $profile.nameJa)
                LabeledContent("Colour") {
                    HStack(spacing: 8) {
                        ForEach(Color.profileSwatches, id: \.hex) { swatch in
                            Button { profile.colour = swatch.hex } label: {
                                Circle().fill(Color(hexString: swatch.hex)).frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: profile.colour == swatch.hex ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(swatch.name)
                            .accessibilityAddTraits(profile.colour == swatch.hex ? .isSelected : [])
                            .help(swatch.name)
                        }
                    }
                }
                TextField("Channel link (optional)", text: $profile.channel)
            }
            Section {
                Table($profile.glossary, selection: $selectedTerms) {
                    TableColumn("Term") { $t in TextField("Term", text: $t.term).labelsHidden() }
                    TableColumn("Reading") { $t in TextField("Reading", text: $t.reading).labelsHidden() }
                    TableColumn("Meaning") { $t in TextField("Meaning", text: $t.meaning).labelsHidden() }
                    TableColumn("Translate as") { $t in TextField("Translate as", text: $t.translateAs).labelsHidden() }
                }
                .frame(minHeight: 180)
                .onDeleteCommand { profile.glossary.removeAll { selectedTerms.contains($0.id) } }
            } header: {
                HStack {
                    Text("Glossary")
                    Text("\(profile.glossary.count) terms").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Term") { profile.glossary.append(GlossaryTerm(term: "")) }
                }
            }
            Section("Notes for the translator") {
                TextEditor(text: $profile.notes).frame(minHeight: 80).font(.body)
            }
            Section {
                Text("Sent to Claude with every chunk: names, glossary and notes, about \(tokens.formatted()) tokens. It is prompt-cached, so it adds little to the cost.")
                    .font(.caption).foregroundStyle(.secondary)
                if tokens > 2000 {
                    Label("Long glossaries make every request bigger. Consider trimming rarely used terms.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Color.kkNote)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Delete “\(profile.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteProfile(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \(profile.glossary.count) glossary terms and notes are removed. Past sessions keep their transcripts.")
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name.lowercased().replacingOccurrences(of: " ", with: "-")).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ProfileFile.export(profile).write(to: url, options: .atomic)
    }
}

struct NewProfileSheet: View {
    let create: (Profile) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var nameJa = ""
    @State private var channel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Profile").font(.title3.bold())
            Form {
                TextField("Name (English)", text: $name)
                TextField("Name (Japanese)", text: $nameJa)
                TextField("Channel link (optional)", text: $channel)
                Text("Used only to match this profile to a stream automatically. kikitori does not visit the link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(Profile(name: name.trimmingCharacters(in: .whitespaces), nameJa: nameJa,
                                   colour: Color.profileSwatches.randomElement()!.hex, channel: channel))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }
}

/// Import a profile file: merge into an existing profile with the same name, or create one.
struct ImportSheet: View {
    let incoming: Profile
    let target: Profile?
    let done: (Profile) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var keep: [String: ProfileFile.Keep] = [:]
    @State private var appendNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import “\(incoming.name)”").font(.title3.bold())
            if let target {
                let plan = ProfileFile.plan(incoming, into: target)
                Text("Merging into **\(target.name)**: \(plan.added.count) new terms, \(plan.conflicts.count) terms differ.")
                if !plan.conflicts.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text("Term").bold(); Text("Yours").bold(); Text("Imported").bold(); Text("Keep").bold() }
                        ForEach(plan.conflicts, id: \.yours.term) { c in
                            GridRow {
                                Text(c.yours.term).font(.japanese(13))
                                Text(c.yours.translateAs.isEmpty ? c.yours.meaning : c.yours.translateAs).lineLimit(1)
                                Text(c.imported.translateAs.isEmpty ? c.imported.meaning : c.imported.translateAs).lineLimit(1)
                                Picker("", selection: Binding(get: { keep[c.yours.term] ?? .yours }, set: { keep[c.yours.term] = $0 })) {
                                    ForEach(ProfileFile.Keep.allCases, id: \.self) { Text($0.rawValue) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                    }
                }
                Toggle("Append imported notes to mine", isOn: $appendNotes)
            } else {
                Text("Creates a new profile with \(incoming.glossary.count) terms.")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(target == nil ? "Import" : "Import \(ProfileFile.plan(incoming, into: target!).added.count + keep.values.filter { $0 != .yours }.count) Terms") {
                    if let target {
                        done(ProfileFile.apply(ProfileFile.plan(incoming, into: target), to: target, keep: keep,
                                               appendNotes: appendNotes ? incoming.notes : nil))
                    } else {
                        done(incoming)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 520)
    }
}
