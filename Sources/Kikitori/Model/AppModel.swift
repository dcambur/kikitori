import AppKit
import AVFoundation
import CoreAudio
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
    var activeProfileID: UUID? { didSet { if oldValue != activeProfileID { contextChanged() } } }
    var issues: [Issue] = []
    var latencies: [Double] = []
    var capOverride = false
    var explain: [UUID: ExplainState] = [:]
    /// Lines whose English is still on its way (everything else without English stays Japanese only).
    var pendingLines: Set<UUID> = []
    var hasAPIKey = KeychainStore.apiKey() != nil
    var overlayRevision = 0

    private var capture: (any AudioCapture)?
    private var pipelineTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var translator: LiveTranslator?
    private var pendingEnds: [Double: Date] = [:]   // chunk start → when its speech ended (wall clock)
    private var saveTimer: Timer?
    private var explainTasks: [UUID: Task<Void, Never>] = [:]
    private var consecutiveFailures = 0
    private var watchdog: Timer?
    private var sourceQuitAt: Date?
    @ObservationIgnored nonisolated(unsafe) private var lastSoundAt = Date.now
    private var warned80Cycle: Date?

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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.sourceRelaunched(bundleID: id) }
        }
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
            watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSession() }
            }
        } catch is CancellationError {
            // Stopped while starting: stop() already reset everything.
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
        case .paused: await resume()
        default: break
        }
    }

    /// Start capturing again. Only acts when paused, so a second call (double click, hotkey,
    /// auto-resume after the source relaunched) while one is starting or done changes nothing.
    func resume() async {
        guard state == .paused else { return }
        do {
            try await startCapture()
            state = .listening
        } catch is CancellationError {
            // Another resume won, or the session stopped or paused again meanwhile.
        } catch {
            raise(.permissionRevoked)
        }
    }

    func stop() {
        guard isLive || state == .starting else { return }
        stopCapture()
        saveTimer?.invalidate()
        watchdog?.invalidate()
        sourceQuitAt = nil
        session?.end = .now
        saveSession()
        session = nil
        source = nil
        translator = nil
        issues = []
        state = .idle
    }

    /// Throws `CancellationError` when, during its awaits, capture was stopped (stop, pause, source
    /// quit) or another start got there first: the newest decision wins and no capture leaks.
    private func startCapture() async throws {
        guard let source else { return }
        let generation = captureGeneration
        let engine = AppleSpeechEngine()
        try await engine.prepare()
        let vad = try await SileroVAD.load()
        if source.id.hasPrefix("mic:"), !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw CocoaError(.userCancelled)
        }
        // No awaits from here on, so nothing can change between this check and the install.
        guard generation == captureGeneration, self.capture == nil else { throw CancellationError() }
        let capture: any AudioCapture
        if source.id == PlayerController.sourceID {
            capture = try PlayerController.shared.makeAnyCapture()
        } else if source.id.hasPrefix("mic:") {
            let mic = MicrophoneCapture()
            try mic.start(device: AudioDeviceID(source.id.dropFirst(4)))
            capture = mic
        } else {
            // Refresh the process list: helpers come and go (a new tab may play from a new process).
            let fresh = (try? AudioSources.list().first { $0.id == source.id }) ?? source
            let tap = ProcessTapCapture()
            try tap.start(processObjects: fresh.processObjects)
            capture = tap
        }
        self.capture = capture
        lastSoundAt = .now
        var pipeline = LivePipeline(engine: engine, translator: translator, vad: vad, contextTerms: [])
        pipeline.maxChunk = prefs.maxChunk
        pipeline.shouldTranslate = { [weak self] in await self?.translationAllowed() ?? false }
        let offset = session.map { Date.now.timeIntervalSince($0.start) } ?? 0
        let events = pipeline.run(metered(capture.samples))
        pipelineTask = Task { [weak self] in
            for await event in events { self?.handle(event, offset: offset) }
        }
    }

    /// Passes audio through and notes when it was last audible (at most one store per second).
    private func metered(_ input: AsyncStream<[Float]>) -> AsyncStream<[Float]> {
        let (output, feed) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
        Task.detached { [weak self] in
            var lastStore = Date.distantPast
            for await samples in input {
                feed.yield(samples)
                if Date.now.timeIntervalSince(lastStore) > 1, samples.contains(where: { abs($0) > 0.003 }) {
                    lastStore = .now
                    self?.lastSoundAt = .now
                }
            }
            feed.finish()
        }
        return output
    }

    /// Every 5 s: silence, source gone, budget warnings (spec §5.10, §5.6).
    private func checkSession() {
        guard isLive else { return }
        if let quit = sourceQuitAt, Date.now.timeIntervalSince(quit) > 600 {
            let name = activeProfile?.name ?? source?.name ?? "kikitori"
            let duration = session.map { TimeText.format($0.duration) } ?? ""
            stop()
            Notifier.post("Session saved: \(name), \(duration)", body: "The source app didn’t come back within 10 minutes.")
            return
        }
        guard state == .listening else { return }
        let silent = Date.now.timeIntervalSince(lastSoundAt)
        if silent > 60 { raise(.noAudio(name: source?.name ?? "the source")) } else { clear(.noAudio(name: source?.name ?? "the source")) }
        if prefs.endAfterSilenceMinutes > 0, silent > Double(prefs.endAfterSilenceMinutes * 60) {
            stop()
            return
        }
        let cycle = ledger.cycle()
        if prefs.warnAt80, warned80Cycle != cycle.start, spentThisCycle >= prefs.monthlyCap * 0.8, spentThisCycle < prefs.monthlyCap {
            warned80Cycle = cycle.start
            Notifier.post("80 % of your monthly cap used",
                          body: "\(Money.format(spentThisCycle)) of \(Money.format(prefs.monthlyCap)).")
        }
    }

    private func sourceRelaunched(bundleID: String?) {
        guard state == .paused, let source, source.id == bundleID, issues.contains(.sourceQuit(name: source.name)) else { return }
        clear(.sourceQuit(name: source.name))
        sourceQuitAt = nil
        Task {
            try? await Task.sleep(for: .seconds(3))   // let the app start its audio helpers
            await resume()                            // not a toggle: the user may have resumed already
        }
    }

    /// Restart capture for the built-in player (after it switched from page audio to the process tap).
    func restartPlayerCapture() async {
        guard state == .listening, source?.id == PlayerController.sourceID else { return }
        stopCapture()
        do { try await startCapture() } catch is CancellationError {} catch { raise(.permissionRevoked) }
    }

    /// Push the current profile and stream info to the live translator.
    func contextChanged() {
        let profile = activeProfile, info = streamInfo, settings = prefs.translation
        session?.profileName = profile?.name
        Task { await translator?.updateContext(profile: profile, streamInfo: info, settings: settings) }
    }

    private func stopCapture() {
        captureGeneration += 1   // a start still awaiting gives up instead of installing its capture
        capture?.stop()
        capture = nil
        pipelineTask?.cancel()
        pipelineTask = nil
    }

    private func translationAllowed() -> Bool {
        if capReached && prefs.capAction != .noExplain {
            if !issues.contains(.capReached) {
                Notifier.post("Monthly cap reached", body: "Translation is paused. Japanese subtitles keep working.")
            }
            raise(.capReached)
            if prefs.capAction == .stop { Task { stop() } }
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
            let line = TranscriptLine(time: t, ja: ja)
            record.lines.append(line)
            pendingLines.insert(line.id)
            clear(.noAudio(name: source?.name ?? ""))
        case let .translated(time, lines, cost, _, tokens):
            let t = time + offset
            if let i = record.lines.firstIndex(where: { $0.time == t && $0.en == nil }) {
                pendingLines.remove(record.lines[i].id)
                let translated = lines.map { var l = $0; l.time = t; return l }
                // No lines back means fillers or backchannels: the Japanese stays, without English.
                if !translated.isEmpty { record.lines.replaceSubrange(i...i, with: translated) }
            }
            if let end = pendingEnds.removeValue(forKey: t) { latencies.append(Date.now.timeIntervalSince(end)) }
            record.cost += cost
            ledger.entries.append(UsageEntry(session: record.id, model: LiveTranslator.model, kind: .live,
                                             cost: cost, tokens: tokens))
            consecutiveFailures = 0
            for issue in [Issue.offline, .apiOutage, .rateLimited, .keyInvalid, .creditsExhausted] { clear(issue) }
            saveLedgerSoon()
        case let .translationSkipped(time):
            settle(time + offset, in: &record)
        case let .translationFailed(time, failure, cost, tokens):
            settle(time + offset, in: &record)
            if tokens > 0 {   // billed even though there is nothing to show: it still counts toward the cap
                record.cost += cost
                ledger.entries.append(UsageEntry(session: record.id, model: LiveTranslator.model, kind: .live,
                                                 cost: cost, tokens: tokens))
                saveLedgerSoon()
            }
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

    private func settle(_ time: Double, in record: inout SessionRecord) {
        if let line = record.lines.first(where: { $0.time == time && $0.en == nil }) { pendingLines.remove(line.id) }
        pendingEnds[time] = nil
    }

    func raise(_ issue: Issue) { if !issues.contains(issue) { issues.append(issue) } }
    func clear(_ issue: Issue) { issues.removeAll { $0 == issue } }

    private func sourceTerminated(bundleID: String?) {
        guard isLive, let source, source.id == bundleID else { return }
        stopCapture()
        state = .paused
        sourceQuitAt = .now
        raise(.sourceQuit(name: source.name))
    }

    func translateAnyway() {
        capOverride = true
        clear(.capReached)
    }

    // MARK: Explain

    func explain(_ line: TranscriptLine, again: Bool = false) {
        guard let key = KeychainStore.apiKey() else { explain[line.id] = .failed("Add an API key in Settings › Account."); return }
        if capReached {   // every cap action but "Only warn me" stops explanations, the dearest calls
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
            } catch {
                if let billed = error as? ClaudeClient.BilledFailure {   // billed with nothing to show: still counts
                    ledger.entries.append(UsageEntry(session: session?.id, model: Explainer.model, kind: .explain,
                                                     cost: billed.cost, tokens: billed.usage.inputTokens + billed.usage.outputTokens))
                    session?.cost += billed.cost
                    saveLedgerSoon()
                }
                guard !Task.isCancelled else { return }
                let failure = (error as? ClaudeClient.BilledFailure)?.failure ?? error as? ClaudeClient.Failure
                let message: String = switch failure {
                case .offline?: "You’re offline."
                case .rateLimited?, .overloaded?: "Claude is busy right now."
                case .invalidKey?: "Your API key stopped working."
                case .creditsExhausted?: "No API credits left."
                default: "Claude didn’t answer in time."
                }
                explain[line.id] = .failed(message)
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
