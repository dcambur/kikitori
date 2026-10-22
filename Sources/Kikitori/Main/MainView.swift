import KikitoriCore
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case live = "Live", sessions = "Sessions", profiles = "Profiles", usage = "Usage"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .sessions: "clock"
        case .profiles: "person.crop.circle"
        case .usage: "chart.bar"
        }
    }
}

/// The single main window (spec §3): sidebar Live · Sessions · Profiles · Usage.
struct MainView: View {
    @Environment(AppModel.self) var model
    @AppStorage("section") var section: SidebarSection = .live
    /// Snapshot mode shows a fixed section without touching the saved choice.
    var forced: SidebarSection?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
                ForEach(SidebarSection.allCases) { s in
                    Label(s.rawValue, systemImage: s.symbol)
                        .badge(badge(for: s))
                        .tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 208, max: 216)
            .safeAreaInset(edge: .bottom) { CycleFooter().padding(12) }
        } detail: {
            switch forced ?? section {
            case .live: LiveView()
            case .sessions: SessionsView()
            case .profiles: ProfilesView()
            case .usage: UsageView()
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .background {
            // ⌘1–4 switch sections (spec §3 commands).
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { i, s in
                Button("") { section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).hidden()
            }
        }
    }

    func badge(for s: SidebarSection) -> Text? {
        switch s {
        case .live:
            guard let session = model.session, model.isLive else { return Text("Idle") }
            return Text("● \(TranscriptExport.clock(session.duration))").foregroundStyle(Color.kkDanger)
        case .sessions: return model.sessions.isEmpty ? nil : Text("\(model.sessions.count)")
        default: return nil
        }
    }
}

/// Sidebar footer: “This cycle $6.12 of $100” + meter + reset date.
struct CycleFooter: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let spent = model.spentThisCycle
        let cap = model.prefs.monthlyCap
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This cycle").foregroundStyle(.secondary)
                Spacer()
                Text("\(Money.format(spent)) of \(Money.format(cap))").monospacedDigit().bold()
            }
            .font(.caption)
            ProgressView(value: min(spent / max(cap, 0.01), 1))
                .tint(spent >= cap ? Color.kkDanger : Color.kkAccentFill)
            Text("Credits reset \(model.ledger.cycle().end.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Int(100 * spent / max(cap, 0.01))) percent of monthly credit used")
    }
}
