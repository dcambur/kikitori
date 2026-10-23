import AppKit
import KikitoriCore
import SwiftUI

/// Renders every screen offscreen into PNGs for review, with fictional sample data and throwaway
/// storage (no windows shown, no user data touched):
///   Kikitori --snapshots <output folder>
@MainActor
enum Snapshots {
    static func run(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = FileManager.default.temporaryDirectory.appending(path: "kikitori-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }
        KeychainStore.previewKey = "sk-ant-sample-key-0000"
        let model = AppModel(storage: storage)
        AppModel.shared = model
        loadSample(into: model)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for section in SidebarSection.allCases where section != .watch {   // Watch loads the real site
                render(MainView(forced: section), size: CGSize(width: 1180, height: 720), appearance: appearance,
                       model: model, to: folder.appending(path: "main-\(section.rawValue.lowercased())-\(suffix).png"))
            }
            // The smallest the main window can be (regression: header layout loop when narrow).
            for width in [860.0, 980.0] {
                for section in SidebarSection.allCases where section != .watch {   // Watch loads the real site
                    render(MainView(forced: section), size: CGSize(width: width, height: 520), appearance: appearance,
                           model: model, to: folder.appending(path: "main-\(section.rawValue.lowercased())-\(Int(width))-\(suffix).png"))
                }
            }
            render(MenuBarPanel(), size: CGSize(width: 320, height: 520), appearance: appearance, model: model,
                   to: folder.appending(path: "menubar-\(suffix).png"))
            render(ExplanationView(line: model.session!.lines[4]).background(Color.kkInspector),
                   size: CGSize(width: 330, height: 720), appearance: appearance, model: model,
                   to: folder.appending(path: "explanation-\(suffix).png"))
            for (name, view) in [("general", AnyView(GeneralTab())), ("translation", AnyView(TranslationTab())),
                                 ("overlay", AnyView(OverlayTab())), ("account", AnyView(AccountTab()))] {
                render(view, size: CGSize(width: 680, height: 560), appearance: appearance, model: model,
                       to: folder.appending(path: "settings-\(name)-\(suffix).png"))
            }
        }
        for step in 0...5 {
            UserDefaults.standard.set(step, forKey: "onboardingStep")
            render(OnboardingView(), size: CGSize(width: 640, height: 520), appearance: .aqua, model: model,
                   to: folder.appending(path: "onboarding-\(step).png"))
        }
        UserDefaults.standard.removeObject(forKey: "onboardingStep")
        // Overlay over a dark and a bright "video".
        for (name, background) in [("dark", Color(hex: 0x1B1B2F)), ("bright", Color(hex: 0xD8E6F0))] {
            render(ZStack { background; OverlayView() }, size: CGSize(width: 900, height: 260), appearance: .darkAqua,
                   model: model, to: folder.appending(path: "overlay-\(name).png"))
        }
        model.raise(.offline)
        render(ZStack { Color(hex: 0x1B1B2F); OverlayView() }, size: CGSize(width: 900, height: 300), appearance: .darkAqua,
               model: model, to: folder.appending(path: "overlay-offline.png"))
        print("snapshots written to \(folder.path)")
    }

    /// The real overlay panel, offscreen, fed lines of varying length every 150 ms for `seconds`.
    /// Regression check for the panel/content sizing loop that crashed the app on its first line.
    static func overlayStress(seconds: Double) {
        let storage = FileManager.default.temporaryDirectory.appending(path: "kikitori-stress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }
        KeychainStore.previewKey = "sk-ant-sample-key-0000"
        let model = AppModel(storage: storage)
        AppModel.shared = model
        loadSample(into: model)
        model.prefs.overlayVisible = true
        OverlayController.shared.offscreen = true
        OverlayController.shared.setUp()
        let texts = ["Hi!", "Wait, is that a creeper!? Oh no oh no oh no",
                     "The whole castle burned down last stream, so today is revenge, and this time we build it out of stone so nothing can burn it",
                     "LOL", "People keep calling my collab with Rio “tee-tee”…"]
        var i = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            i += 1
            var line = TranscriptLine(time: Double(i), ja: String(repeating: "あ", count: 3 + (i * 7) % 40),
                                      en: texts[i % texts.count])
            if i % 3 == 0 { line.note = "note"; line.term = "あ" }
            model.session?.lines.append(line)
            if i % 4 == 0 { model.pendingLines.insert(line.id) }
            model.overlayRevision += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        print("overlay stress ok: \(i) lines")
    }

    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, model: AppModel, to url: URL) {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        // The capture skips the window's own background, so paint it (else transparent = white).
        let host = NSHostingView(rootView: view.environment(model).environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        host.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let lists and charts lay out
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    /// The design's fictional streamer (spec: Hoshimi Kuu 星見くう, fans 星屑 “Stardust”).
    static func loadSample(into model: AppModel) {
        let kuu = Profile(name: "Hoshimi Kuu", nameJa: "星見くう", colour: "#8D7BE0", channel: "",
                          glossary: [GlossaryTerm(term: "星屑", reading: "hoshikuzu", meaning: "Kuu’s fans", translateAs: "Stardust"),
                                     GlossaryTerm(term: "くう", reading: "kuu", meaning: "Streamer’s name", translateAs: "Kuu"),
                                     GlossaryTerm(term: "マネちゃん", reading: "mane-chan", meaning: "Her manager", translateAs: "my manager")],
                          notes: "Cheerful Minecraft streamer. Collab partner Amane Rio (天音リオ).")
        let rio = Profile(name: "Amane Rio", nameJa: "天音リオ", colour: "#2F8FB8")
        model.profiles = [kuu, rio]
        model.activeProfileID = kuu.id
        var session = SessionRecord(start: .now.addingTimeInterval(-4_360), sourceName: "Safari", sourceID: "com.apple.Safari",
                                    profileName: kuu.name)
        session.streamTitle = "【Minecraft】空に浮かぶ城をつくる！#3"
        session.game = "Minecraft"
        session.lines = [
            TranscriptLine(time: 4_248, ja: "よし、じゃあ屋根の続きやっていきます", en: "Okay, let’s keep going on the roof."),
            TranscriptLine(time: 4_255, ja: "前回の配信で城が全部燃えたからね、今日はリベンジ", en: "The whole castle burned down last stream, so today is revenge.",
                           note: "Refers to the previous stream’s fire.", term: "前回の配信"),
            TranscriptLine(time: 4_269, ja: "え、待って、クリーパーいる！？やばいやばいやばい", en: "Wait, is that a creeper!? Oh no oh no oh no"),
            TranscriptLine(time: 4_274, ja: "草 www 今の見た？", en: "LOL, did you see that?", note: "草 = lol (grass ≈ wwww)", term: "草"),
            TranscriptLine(time: 4_290, ja: "リオちゃんとのコラボ、てぇてぇって言われてて…", en: "People keep calling my collab with Rio “tee-tee”…",
                           note: "Fan slang for wholesome", term: "てぇてぇ"),
            TranscriptLine(time: 4_301, ja: "いや、てぇてぇじゃないから！普通に仲良しなだけ！", en: "It’s not tee-tee! We’re just normal friends!"),
            TranscriptLine(time: 4_318, ja: "ねえ、マネちゃんに怒られちゃうよ", en: "Hey, my manager’s going to scold me."),
            TranscriptLine(time: 4_330, ja: "じゃあ次は塔の上に旗を立てて…"),
        ]
        session.cost = 0.14
        model.session = session
        model.pendingLines = [session.lines.last!.id]
        model.source = AudioSource(id: "com.apple.Safari", name: "Safari", pid: 0, processObjects: [], isPlaying: true)
        model.state = .listening
        model.latencies = [2.7, 2.9, 3.1, 2.8, 2.9]
        let noted = session.lines[4]
        model.explain[noted.id] = .result([Explainer.Explanation(
            term: "てぇてぇ", reading: "てぇてぇ", romaji: "tētē", gist: "Precious, heart-warming (between two people)",
            meaning: "A slurred, excited way of saying 尊い (tōtoi, “precious, sacred”). Fans use it for sweet moments between two streamers, especially in collabs.",
            inThisLine: "Kuu is a little embarrassed: chat has been “shipping” her with Amane Rio since their horror-game collab. The next line is her denying it.",
            parts: [.init(text: "コラボ", reading: "こらぼ", gloss: "collab stream"),
                    .init(text: "てぇてぇ", reading: "てぇてぇ", gloss: "so precious"),
                    .init(text: "言われてて", reading: "いわれてて", gloss: "keep being told")],
            fanSlang: ["wholesome", "precious", "they’re so cute together"])], cost: 0.004)
        model.ledger.cycleStartDay = 15
        for d in 0..<8 {
            let date = Date.now.addingTimeInterval(-Double(7 - d) * 86_400 - 3_600)
            model.ledger.entries.append(UsageEntry(date: date, session: nil, model: LiveTranslator.model, kind: .live,
                                                   cost: [0.42, 0.0, 1.1, 0.3, 0.0, 0.8, 0.5, 0.14][d], tokens: 380_000))
            model.ledger.entries.append(UsageEntry(date: date, session: nil, model: Explainer.model, kind: .explain,
                                                   cost: [0.12, 0.0, 0.3, 0.05, 0.0, 0.2, 0.1, 0.02][d], tokens: 3_000))
        }
    }
}
