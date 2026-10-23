import AppKit
import Carbon.HIToolbox

/// Global hotkeys (spec §5.8) through Carbon `RegisterEventHotKey`: no Accessibility permission.
@MainActor
enum Hotkeys {
    enum Action: UInt32, CaseIterable {
        case toggleOverlay = 1, pause, explain, transcript, clickThrough, japanese, source

        var title: String {
            switch self {
            case .toggleOverlay: "Show or hide subtitles"
            case .pause: "Pause or resume"
            case .explain: "Explain the last line"
            case .transcript: "Open transcript"
            case .clickThrough: "Click-through on or off"
            case .japanese: "Show Japanese on or off"
            case .source: "Choose source"
            }
        }
        var key: Int {
            switch self {
            case .toggleOverlay: kVK_ANSI_S
            case .pause: kVK_ANSI_P
            case .explain: kVK_ANSI_E
            case .transcript: kVK_ANSI_T
            case .clickThrough: kVK_ANSI_C
            case .japanese: kVK_ANSI_J
            case .source: kVK_ANSI_O
            }
        }
        var label: String { "⌃⌥" + ["S", "P", "E", "T", "C", "J", "O"][Int(rawValue) - 1] }
    }

    private static var refs: [EventHotKeyRef] = []
    /// Actions whose shortcut another app already holds.
    private(set) static var failed: [Action] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, nil, nil)
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4B4B5452), id: action.rawValue)  // 'KKTR'
            let status = RegisterEventHotKey(UInt32(action.key), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.append(action) }
        }
    }

    static func perform(_ action: Action) {
        let model = AppModel.shared
        switch action {
        case .toggleOverlay: model.prefs.overlayVisible.toggle()
        case .pause: Task { await model.togglePause() }
        case .explain: explainLastLine()
        case .transcript: openMainWindow(.live)
        case .clickThrough: model.prefs.clickThrough.toggle()
        case .japanese: model.prefs.showJapanese.toggle()
        case .source: openMainWindow(.live)
        }
    }
}

/// Carbon calls this on the main thread; a C callback can't capture context, so it is file-level.
private func hotKeyPressed(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    let raw = id.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { if let action = Hotkeys.Action(rawValue: raw) { Hotkeys.perform(action) } }
    }
    return noErr
}
