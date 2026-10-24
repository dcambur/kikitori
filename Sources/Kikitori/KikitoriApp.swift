import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--live-test"), args.count > i + 3 {
            let (bundleID, seconds, log) = (args[i + 1], Double(args[i + 2]) ?? 30, args[i + 3])
            Task {
                await LiveTest.run(bundleID: bundleID, seconds: seconds, logPath: log)
                exit(0)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
            return
        }
        if let i = args.firstIndex(of: "--player-test"), args.count > i + 3 {
            let (input, seconds, log) = (args[i + 1], Double(args[i + 2]) ?? 60, args[i + 3])
            NSApplication.shared.setActivationPolicy(.accessory)
            Task { @MainActor in
                await PlayerTest.run(input: input, seconds: seconds, logPath: log, muted: args.contains("--muted"))
                exit(0)
            }
            NSApplication.shared.run()
            return
        }
        if let i = args.firstIndex(of: "--overlay-stress") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let seconds = args.count > i + 1 ? Double(args[i + 1]) ?? 8 : 8
            MainActor.assumeIsolated { Snapshots.overlayStress(seconds: seconds) }
            return
        }
        if let i = args.firstIndex(of: "--snapshots"), args.count > i + 1 {
            let folder = URL(fileURLWithPath: args[i + 1])
            NSApplication.shared.setActivationPolicy(.prohibited)
            MainActor.assumeIsolated { Snapshots.run(to: folder) }
            return
        }
        KikitoriApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            OverlayController.shared.setUp()
            Hotkeys.register()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
}

/// Scenes (spec §3): onboarding, main window, Settings, menu bar extra. The overlay is AppKit.
struct KikitoriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel.shared
    @Environment(\.openWindow) var openWindow

    var body: some Scene {
        Window("kikitori", id: "main") {
            MainView()
                .environment(model)
                .onAppear { if !model.prefs.onboardingDone { openWindow(id: "onboarding") } }
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in openWindow(id: "main") }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { KikitoriCommands(model: model) }

        Window("Welcome to kikitori", id: "onboarding") {
            OnboardingView().environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings { SettingsView().environment(model) }

        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarGlyph().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct KikitoriCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some Commands {
        CommandMenu("Session") {
            Button(model.state == .paused ? "Resume" : "Pause") { Task { await model.togglePause() } }
                .keyboardShortcut("p", modifiers: [.control, .option]).disabled(!model.isLive)
            Button("Stop Listening") { model.stop() }.disabled(!model.isLive)
            Button("Explain Last Line") { explainLastLine() }
                .keyboardShortcut("e", modifiers: [.control, .option]).disabled(model.lastLine == nil)
            Divider()
            Button("Watch in kikitori") { openWatch(openWindow) }
                .keyboardShortcut("w", modifiers: [.control, .option])   // ⇧⌘W stays Close for windows
        }
        CommandGroup(after: .sidebar) {
            // ⌘1–5 switch sections (spec §3 commands), listed here so they can be found.
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.rawValue) { selectSection(s); NSApp.activate(); openWindow(id: "main") }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Button("Make Text Bigger") { model.prefs.transcriptTextSize = min(model.prefs.transcriptTextSize + 1, 24) }
                .keyboardShortcut("+")
            Button("Make Text Smaller") { model.prefs.transcriptTextSize = max(model.prefs.transcriptTextSize - 1, 13) }
                .keyboardShortcut("-")
        }
    }
}
