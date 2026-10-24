import KikitoriCore
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    // Watch is last so Live · Sessions · Profiles · Usage keep ⌘1–4 (spec §3).
    case live = "Live", sessions = "Sessions", profiles = "Profiles", usage = "Usage", watch = "Watch"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .watch: "play.rectangle"
        case .sessions: "clock"
        case .profiles: "person.crop.circle"
        case .usage: "chart.bar"
        }
    }
}

/// The single main window (spec §3): sidebar Live · Sessions · Profiles · Usage · Watch.
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
            case .watch: PlayerView()
            case .sessions: SessionsView()
            case .profiles: ProfilesView()
            case .usage: UsageView()
            }
        }
        .frame(minWidth: 860, minHeight: 520)
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

/// Show the built-in player: the Watch section of the main window (opened if it was closed).
@MainActor func openWatch(_ openWindow: OpenWindowAction) {
    selectSection(.watch)
    NSApp.activate()
    openWindow(id: "main")
}

/// Explain the newest translated line where the viewer is looking: beside the video while the
/// player is on screen, otherwise in Live. `open` brings the main window forward.
@MainActor func explainLastLine(open: () -> Void = { openMainWindow() }) {
    let model = AppModel.shared
    guard let line = model.lastLine else { return }
    let watching = model.source?.id == PlayerController.sourceID && PlayerController.shared.isOnScreen
    if !watching { selectSection(.live) }
    model.focusExplanation(line)
    open()
}

/// Select a section of the main window (what MainView's `@AppStorage("section")` reads).
@MainActor func selectSection(_ section: SidebarSection) {
    UserDefaults.standard.set(section.rawValue, forKey: "section")
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
