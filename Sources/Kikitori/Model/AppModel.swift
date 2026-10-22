import AppKit
import Foundation
import KikitoriCore
import Observation

/// The app's single source of truth: the live session, its status, stores and settings.
/// Every status surface (overlay pill, menu bar, banners) reads `status` (spec §4).
@MainActor @Observable
final class AppModel {
    /// Replaced before first use only by snapshot mode (throwaway storage, sample data).
    static var shared = AppModel()

    enum SessionState: Equatable { case idle, starting, listening, paused }

    /// Non-normal states, highest priority first (spec §4 precedence).
    enum Issue: Equatable {
        case permissionRevoked
        case sourceQuit(name: String)
        case modelUnavailable(String)
        case keyInvalid
        case noKey
        case creditsExhausted
        case capReached
        case offline
        case apiOutage
        case rateLimited
        case fallingBehind
        case noAudio(name: String)

        var blocking: Bool {
            switch self { case .permissionRevoked, .sourceQuit, .modelUnavailable: true; default: false }
        }
        var japaneseOnly: Bool {
            switch self { case .keyInvalid, .noKey, .creditsExhausted, .capReached, .offline, .apiOutage, .rateLimited: true
            default: false }
        }
        var rank: Int {
            switch self {
            case .permissionRevoked, .sourceQuit, .modelUnavailable: 0
            case .keyInvalid, .noKey: 1
            case .creditsExhausted: 2
            case .capReached: 3
            case .offline, .apiOutage: 4
            case .rateLimited: 5
            case .fallingBehind: 6
            case .noAudio: 7
            }
        }
    }

    enum ExplainState { case loading, result([Explainer.Explanation], cost: Double), failed(String) }

    let prefs = Preferences()
    let sessionStore: SessionStore
    private let supportURL: URL

    // Stores
    var profiles: [Profile] = []
    var ledger: UsageLedger
    var sessions: [SessionSummary] = []

    // Live session
    var state: SessionState = .idle
    var session: SessionRecord?
    var source: AudioSource?
    var activeProfileID: UUID?
    var issues: [Issue] = []
    var latencies: [Double] = []
    var capOverride = false
    var explain: [UUID: ExplainState] = [:]
    var hasAPIKey = KeychainStore.apiKey() != nil
    var overlayRevision = 0

    private var capture: ProcessTapCapture?
    private var pipelineTask: Task<Void, Never>?
    private var translator: LiveTranslator?
    private var pendingEnds: [Double: Date] = [:]   // chunk start → when its speech ended (wall clock)
    private var saveTimer: Timer?
    private var explainTasks: [UUID: Task<Void, Never>] = [:]
    private var consecutiveFailures = 0

    init(storage: URL = URL.applicationSupportDirectory.appending(path: "kikitori")) {
        supportURL = storage
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        sessionStore = SessionStore(directory: supportURL.appending(path: "sessions"))
        ledger = UsageLedger(cycleStartDay: 1)
        ledger = UsageLedger(entries: Self.load([UsageEntry].self, from: supportURL.appending(path: "usage.json")) ?? [],
                             cycleStartDay: prefs.cycleStartDay)
        profiles = Self.load([Profile].self, from: supportURL.appending(path: "profiles.json")) ?? []
        sessions = sessionStore.summaries()
        applyRetention()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.sourceTerminated(bundleID: id) }
        }
    }

    // MARK: Derived state

    /// The single issue the overlay shows (spec §4 precedence).
    var topIssue: Issue? { issues.min { $0.rank < $1.rank } }
    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }
    var spentThisCycle: Double { ledger.spentThisCycle() }
    var capReached: Bool { spentThisCycle >= prefs.monthlyCap && !capOverride && prefs.capAction != .warn }
    var isLive: Bool { state == .listening || state == .paused }

    /// Median of the last five latencies (spec §4).
    var latency: Double? {
        guard !latencies.isEmpty else { return nil }
        let last = latencies.suffix(5).sorted()
        return last[last.count / 2]
    }

    var statusText: String {
        switch state {
        case .idle: return "Not listening"
        case .starting: return "Starting…"
        case .paused: return "Paused"
        case .listening:
            if let issue = topIssue { return Self.shortText(issue) }
            if let latency { return String(format: "Translating · ≈ %.1f s", latency) }
            return "Listening"
        }
    }

    static func shortText(_ issue: Issue) -> String {
        switch issue {
        case .permissionRevoked: "Audio access was turned off"
        case .sourceQuit(let name): "\(name) quit"
        case .modelUnavailable: "Speech model unavailable"
        case .keyInvalid: "API key stopped working · Japanese only"
        case .noKey: "No API key · Japanese only"
        case .creditsExhausted: "No API credits left · Japanese only"
        case .capReached: "Monthly cap reached · Japanese only"
        case .offline: "Offline · Japanese only"
        case .apiOutage: "Claude isn’t responding · Japanese only"
        case .rateLimited: "Claude is busy · Japanese only meanwhile"
        case .fallingBehind: "Skipped ahead to live"
        case .noAudio(let name): "No sound from \(name)"
        }
    }

    // MARK: Session control

    func start(source: AudioSource) async {
        guard state == .idle else { return }
        state = .starting
        self.source = source
        prefs.lastSourceID = source.id
        issues = []
        latencies = []
        capOverride = false
        activeProfileID = activeProfileID ?? profiles.first(where: { $0.channel.isEmpty == false && source.name.contains($0.name) })?.id
        session = SessionRecord(sourceName: source.name, sourceID: source.id, profileName: activeProfile?.name)
        if let key = KeychainStore.apiKey() {
            hasAPIKey = true
            translator = LiveTranslator(client: ClaudeClient(apiKey: key), profile: activeProfile,
                                        streamInfo: streamInfo, settings: prefs.translation)
        } else {
            hasAPIKey = false
            translator = nil
            raise(.noKey)
        }
        do {
            try await startCapture()
            state = .listening
            saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveSession() }
            }
        } catch {
            state = .idle
            raise(.permissionRevoked)
            stopCapture()
        }
    }

    /// Pause = stop capturing (nothing captured or sent); the session stays open.
    func togglePause() async {
        switch state {
        case .listening: stopCapture(); state = .paused
        case .paused:
            do { try await startCapture(); state = .listening } catch { raise(.permissionRevoked) }
        default: break
        }
    }

    func stop() {
        guard isLive || state == .starting else { return }
        stopCapture()
        saveTimer?.invalidate()
        session?.end = .now
        saveSession()
        session = nil
        source = nil
        translator = nil
        issues = []
        state = .idle
    }

    private func startCapture() async throws {
        guard let source else { return }
        let engine = AppleSpeechEngine()
        try await engine.prepare()
        // Refresh the process list: helpers come and go (a new tab may play from a new process).
        let fresh = (try? AudioSources.list().first { $0.id == source.id }) ?? source
        let capture = ProcessTapCapture()
        try capture.start(processObjects: fresh.processObjects)
        self.capture = capture
        var pipeline = LivePipeline(engine: engine, translator: translator, vad: try await SileroVAD.load(),
                                    contextTerms: [])
        pipeline.maxChunk = prefs.maxChunk
        pipeline.shouldTranslate = { [weak self] in await self?.translationAllowed() ?? false }
        let offset = session.map { Date.now.timeIntervalSince($0.start) } ?? 0
        let events = pipeline.run(capture.samples)
        pipelineTask = Task { [weak self] in
            for await event in events { self?.handle(event, offset: offset) }
        }
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        pipelineTask?.cancel()
        pipelineTask = nil
    }

    private func translationAllowed() -> Bool {
        if capReached && prefs.capAction != .noExplain {
            raise(.capReached)
            return false
        }
        clear(.capReached)
        return true
    }

    private func handle(_ event: LivePipeline<SileroVAD>.Event, offset: Double) {
        guard var record = session else { return }
        switch event {
        case let .heard(time, duration, ja, asr):
            let t = time + offset
            pendingEnds[t] = Date.now.addingTimeInterval(-asr)
            _ = duration
            record.lines.append(TranscriptLine(time: t, ja: ja))
            clear(.noAudio(name: source?.name ?? ""))
        case let .translated(time, lines, cost, _, tokens):
            let t = time + offset
            if let i = record.lines.firstIndex(where: { $0.time == t && $0.en == nil }) {
                let translated = lines.map { var l = $0; l.time = t; return l }
                record.lines.replaceSubrange(i...i, with: translated.isEmpty ? [record.lines[i]] : translated)
            }
            if let end = pendingEnds.removeValue(forKey: t) { latencies.append(Date.now.timeIntervalSince(end)) }
            record.cost += cost
            ledger.entries.append(UsageEntry(session: record.id, model: LiveTranslator.model, kind: .live,
                                             cost: cost, tokens: tokens))
            consecutiveFailures = 0
            for issue in [Issue.offline, .apiOutage, .rateLimited, .keyInvalid, .creditsExhausted] { clear(issue) }
            saveLedgerSoon()
        case let .translationFailed(_, failure):
            consecutiveFailures += 1
            switch failure {
            case .invalidKey: raise(.keyInvalid)
            case .creditsExhausted: raise(.creditsExhausted)
            case .rateLimited: raise(.rateLimited)
            case .offline: raise(.offline)
            case .overloaded: if consecutiveFailures >= 3 { raise(.apiOutage) }
            default: break
            }
        }
        session = record
        overlayRevision += 1
    }

    func raise(_ issue: Issue) { if !issues.contains(issue) { issues.append(issue) } }
    func clear(_ issue: Issue) { issues.removeAll { $0 == issue } }

    private func sourceTerminated(bundleID: String?) {
        guard isLive, let source, source.id == bundleID else { return }
        stopCapture()
        state = .paused
        raise(.sourceQuit(name: source.name))
    }

    func translateAnyway() {
        capOverride = true
        clear(.capReached)
    }

    // MARK: Explain

    func explain(_ line: TranscriptLine, again: Bool = false) {
        guard let key = KeychainStore.apiKey() else { explain[line.id] = .failed("Add an API key in Settings › Account."); return }
        if prefs.capAction == .noExplain && spentThisCycle >= prefs.monthlyCap && !capOverride {
            explain[line.id] = .failed("Monthly cap reached. Explanations are paused.")
            return
        }
        if case .result = explain[line.id], !again { return }
        explainTasks.values.forEach { $0.cancel() }
        let previous: [Explainer.Explanation]
        if case .result(let list, _) = explain[line.id] { previous = list } else { previous = [] }
        explain[line.id] = .loading
        let context = contextLines(before: line)
        let profile = activeProfile
        explainTasks[line.id] = Task {
            do {
                let r = try await Explainer(client: ClaudeClient(apiKey: key)).explain(line, context: context, profile: profile)
                guard !Task.isCancelled else { return }
                explain[line.id] = .result(previous + [r.explanation], cost: r.cost)
                ledger.entries.append(UsageEntry(session: session?.id, model: Explainer.model, kind: .explain,
                                                 cost: r.cost, tokens: r.usage.inputTokens + r.usage.outputTokens))
                session?.cost += r.cost
                if prefs.saveExplanations { session?.explanations[line.id, default: []].append(r.explanation) }
                saveLedgerSoon()
            } catch let f as ClaudeClient.Failure {
                guard !Task.isCancelled else { return }
                let message: String = switch f {
                case .offline: "You’re offline."
                case .rateLimited, .overloaded: "Claude is busy right now."
                case .invalidKey: "Your API key stopped working."
                case .creditsExhausted: "No API credits left."
                default: "Claude didn’t answer in time."
                }
                explain[line.id] = .failed(message)
            } catch {
                if !Task.isCancelled { explain[line.id] = .failed("Claude didn’t answer in time.") }
            }
        }
    }

    func cancelExplain(_ id: UUID) {
        explainTasks[id]?.cancel()
        explain[id] = nil
    }

    private func contextLines(before line: TranscriptLine) -> [TranscriptLine] {
        let lines = session?.lines ?? []
        let i = lines.firstIndex { $0.id == line.id } ?? lines.count
        return Array(lines[max(0, i - 12)..<i])
    }

    var lastLine: TranscriptLine? { session?.lines.last { $0.en != nil } }

    var streamInfo: String {
        [session?.streamTitle ?? "", session?.game ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Profiles

    func saveProfiles() { Self.save(profiles, to: supportURL.appending(path: "profiles.json")) }

    func upsert(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
        saveProfiles()
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        saveProfiles()
    }

    // MARK: Persistence

    func saveSession() {
        guard let session else { return }
        try? sessionStore.save(session)
        sessions = sessionStore.summaries()
    }

    func deleteSessions(_ ids: [UUID]) {
        try? sessionStore.delete(ids)
        sessions = sessionStore.summaries()
    }

    private var ledgerSave: Task<Void, Never>?
    private func saveLedgerSoon() {
        ledgerSave?.cancel()
        ledgerSave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Self.save(ledger.entries, to: supportURL.appending(path: "usage.json"))
        }
    }

    func setCycleStartDay(_ day: Int) {
        prefs.cycleStartDay = day
        ledger.cycleStartDay = day
    }

    func applyRetention() {
        guard let days = prefs.retention.days else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let old = sessionStore.olderThan(cutoff).map(\.id)
        if !old.isEmpty { deleteSessions(old) }
    }

    var dataFolder: URL { supportURL }

    func deleteAllData() {
        deleteSessions(sessions.map(\.id))
        profiles = []
        saveProfiles()
        ledger.entries = []
        Self.save(ledger.entries, to: supportURL.appending(path: "usage.json"))
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.kikitori.decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        try? JSONEncoder.kikitori.encode(value).write(to: url, options: .atomic)
    }
}
