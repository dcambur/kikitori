import Foundation
import KikitoriCore
import Observation

/// User settings (spec §5.8), stored in UserDefaults. Every property persists on change.
@MainActor @Observable
final class Preferences {
    enum OverlayStyle: String, CaseIterable { case dark = "Dark glass", light = "Light glass", outline = "Outline" }
    enum TextSize: String, CaseIterable {
        case s = "S", m = "M", l = "L", xl = "XL"
        var english: CGFloat { ["S": 18, "M": 24, "L": 34, "XL": 44][rawValue]! }
        var japanese: CGFloat { ["S": 13, "M": 15, "L": 20, "XL": 26][rawValue]! }
    }
    enum Position: String, CaseIterable {
        case topLeft = "Top Left", topCenter = "Top Center", topRight = "Top Right"
        case bottomLeft = "Bottom Left", bottomCenter = "Bottom Center", bottomRight = "Bottom Right"
    }
    enum CapAction: String, CaseIterable {
        case japaneseOnly = "Japanese only", noExplain = "Keep subtitles, stop explanations"
        case stop = "Stop listening", warn = "Only warn me"
    }
    enum Retention: String, CaseIterable {
        case forever = "Forever", year = "1 year", days90 = "90 days", days30 = "30 days", days7 = "7 days", none = "Don’t keep"
        var days: Int? { ["Forever": nil, "1 year": 365, "90 days": 90, "30 days": 30, "7 days": 7, "Don’t keep": 0][rawValue]! }
    }
    /// What the subtitles show (overlay and player). Japanese is the main line by default.
    enum SubtitleMode: String, CaseIterable {
        case japaneseMain, englishMain, englishOnly, japaneseOnly
        var title: String {
            switch self {
            case .japaneseMain: "Japanese, English below"
            case .englishMain: "English, Japanese above"
            case .englishOnly: "English only"
            case .japaneseOnly: "Japanese only"
            }
        }
    }
    /// What the transcript panels (Live, and beside the video in Watch) show for each line.
    enum TranscriptMode: String, CaseIterable {
        case both, japanese, english
        var title: String {
            switch self {
            case .both: "Japanese & English"
            case .japanese: "Japanese"
            case .english: "English"
            }
        }
    }
    enum SpeechModel: String, CaseIterable {
        case apple = "Apple Speech", whisperTurbo = "Whisper Large v3 Turbo"
    }

    private let defaults = UserDefaults.standard

    var onboardingDone: Bool { didSet { save(onboardingDone, "onboardingDone") } }
    var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, "showMenuBarIcon") } }
    var showInDock: Bool { didSet { save(showInDock, "showInDock") } }
    var retention: Retention { didSet { save(retention.rawValue, "retention") } }
    var saveExplanations: Bool { didSet { save(saveExplanations, "saveExplanations") } }
    var endAfterSilenceMinutes: Int { didSet { save(endAfterSilenceMinutes, "endAfterSilenceMinutes") } }
    var lastSourceID: String? { didSet { save(lastSourceID, "lastSourceID") } }

    var speechModel: SpeechModel { didSet { save(speechModel.rawValue, "speechModel") } }
    var maxChunk: Double { didSet { save(maxChunk, "maxChunk") } }
    /// Speaker labels in collabs (docs/design/speaker-labels.md): off by default, spec §6.
    var speakerLabels: Bool { didSet { save(speakerLabels, "speakerLabels") } }

    var translation: TranslationSettings { didSet { save(try? JSONEncoder().encode(translation), "translation") } }
    /// Translate lines into English with Claude as they are heard. Off by default: transcription
    /// is free and on-device, translation spends API credits on every line.
    var translate: Bool { didSet { save(translate, "translate") } }
    var transcriptMode: TranscriptMode { didSet { save(transcriptMode.rawValue, "transcriptMode") } }
    /// The ⌃⌥J switch: Japanese shown (with English) or English only.
    var showJapanese: Bool {
        get { transcriptMode != .english }
        set { transcriptMode = newValue ? .both : .english }
    }
    var subtitleMode: SubtitleMode { didSet { save(subtitleMode.rawValue, "subtitleMode") } }
    var showFurigana: Bool { didSet { save(showFurigana, "showFurigana") } }

    var overlayVisible: Bool { didSet { save(overlayVisible, "overlayVisible") } }
    var overlayStyle: OverlayStyle { didSet { save(overlayStyle.rawValue, "overlayStyle") } }
    var overlayOpacity: Double { didSet { save(overlayOpacity, "overlayOpacity") } }
    var textSize: TextSize { didSet { save(textSize.rawValue, "textSize") } }
    var overlayLines: Int { didSet { save(overlayLines, "overlayLines") } }
    var position: Position { didSet { save(position.rawValue, "position") } }
    var clickThrough: Bool { didSet { save(clickThrough, "clickThrough") } }
    var hideWhenSilent: Bool { didSet { save(hideWhenSilent, "hideWhenSilent") } }
    var alwaysShowDelay: Bool { didSet { save(alwaysShowDelay, "alwaysShowDelay") } }
    var announceLines: Bool { didSet { save(announceLines, "announceLines") } }

    var monthlyCap: Double { didSet { save(monthlyCap, "monthlyCap") } }
    var capAction: CapAction { didSet { save(capAction.rawValue, "capAction") } }
    var warnAt80: Bool { didSet { save(warnAt80, "warnAt80") } }
    var cycleStartDay: Int { didSet { save(cycleStartDay, "cycleStartDay") } }
    var transcriptTextSize: Double { didSet { save(transcriptTextSize, "transcriptTextSize") } }

    init() {
        let d = UserDefaults.standard
        func get<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }
        onboardingDone = get("onboardingDone", false)
        showMenuBarIcon = get("showMenuBarIcon", true)
        showInDock = get("showInDock", true)
        retention = Retention(rawValue: get("retention", "")) ?? .year
        saveExplanations = get("saveExplanations", true)
        endAfterSilenceMinutes = get("endAfterSilenceMinutes", 10)
        lastSourceID = d.string(forKey: "lastSourceID")
        speechModel = SpeechModel(rawValue: get("speechModel", "")) ?? .apple
        maxChunk = get("maxChunk", 6.0)
        speakerLabels = get("speakerLabels", false)
        translate = get("translate", false)
        translation = (d.data(forKey: "translation")).flatMap { try? JSONDecoder().decode(TranslationSettings.self, from: $0) } ?? .init()
        transcriptMode = TranscriptMode(rawValue: get("transcriptMode", ""))
            ?? (get("showJapanese", true) ? .both : .english)   // the earlier on/off setting
        subtitleMode = SubtitleMode(rawValue: get("subtitleMode", "")) ?? .japaneseMain
        showFurigana = get("showFurigana", false)
        overlayVisible = get("overlayVisible", true)
        overlayStyle = OverlayStyle(rawValue: get("overlayStyle", "")) ?? .dark
        overlayOpacity = get("overlayOpacity", 0.72)
        textSize = TextSize(rawValue: get("textSize", "")) ?? .m
        overlayLines = get("overlayLines", 1)
        position = Position(rawValue: get("position", "")) ?? .bottomCenter
        clickThrough = get("clickThrough", false)
        hideWhenSilent = get("hideWhenSilent", true)
        alwaysShowDelay = get("alwaysShowDelay", false)
        announceLines = get("announceLines", false)
        monthlyCap = get("monthlyCap", 100.0)
        capAction = CapAction(rawValue: get("capAction", "")) ?? .japaneseOnly
        warnAt80 = get("warnAt80", true)
        let firstLaunchDay = Calendar.current.component(.day, from: .now)
        cycleStartDay = get("cycleStartDay", min(firstLaunchDay, 28))
        transcriptTextSize = get("transcriptTextSize", 15.0)
        if d.object(forKey: "cycleStartDay") == nil { d.set(cycleStartDay, forKey: "cycleStartDay") }
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
