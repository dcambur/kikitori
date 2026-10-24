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
    /// The line an Explain action points at (hotkey, menu, a row in the Watch panel), shown by the
    /// Live and Watch inspectors; `focusRequests` counts requests, so asking again reopens it.
    var explainFocus: UUID?
    var focusRequests = 0
    /// Lines whose English is still on its way (everything else without English stays Japanese only).
    var pendingLines: Set<UUID> = []
    /// The live line: Japanese words heard since the last line, still changing ("" for none).
    var hearing = ""
    /// The newest lines as first heard (before translation corrects or splits them), for the
    /// built-in player, whose subtitles are Japanese only and never wait for Claude.
    var recentHeard: [TranscriptLine] = []
    /// The clip playing now (its chunk's start time), for the rows' play buttons.
    var replaying: Double?
    /// The built-in player shows synced subtitles: cues made from the video's buffered audio,
    /// revealed as it plays (docs/design/realtime-sync.md). Meanwhile the process tap passes
    /// silence, so nothing is recognized or translated twice.
    var synced = false
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
    /// Set while a clip plays from a microphone source, which would hear it again: capture
    /// passes silence instead (keeping the timeline) until it stops.
    @ObservationIgnored nonisolated(unsafe) private var muteInput = false
    /// Set while synced: the player's sound is recognized from its buffered audio instead.
    @ObservationIgnored nonisolated(unsafe) private var muteForSync = false
    // Synced subtitles: the media pipeline's input, its events, and the cues not yet in the transcript.
    @ObservationIgnored private var mediaFeed: AsyncStream<MediaPipeline<SileroVAD>.Input>.Continuation?
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var cues: [UUID: Cue] = [:]
    @ObservationIgnored private var cueAudio: [UUID: [Float]] = [:]
    @ObservationIgnored private var revealedLines: Set<String> = []
    @ObservationIgnored private var playerVideo = ""
    @ObservationIgnored private var clips = LineClips()
    @ObservationIgnored private let clipPlayer = ClipPlayer()
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
        if source.id == PlayerController.sourceID { session?.streamTitle = PlayerController.shared.title }
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
            stopCapture()
            session = nil
            self.source = nil
            translator = nil
            state = .idle
            raiseStartFailure(error)
        }
    }

    /// A speech model that could not be installed or loaded (not an audio permission problem).
    private struct ModelUnavailable: Error { var message: String }

    private func raiseStartFailure(_ error: Error) {
        if let model = error as? ModelUnavailable { raise(.modelUnavailable(model.message)) } else { raise(.permissionRevoked) }
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
            raiseStartFailure(error)
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
        stopReplay()
        clips.removeAll()
        recentHeard = []
        state = .idle
    }

    /// Throws `CancellationError` when, during its awaits, capture was stopped (stop, pause, source
    /// quit) or another start got there first: the newest decision wins and no capture leaks.
    private func startCapture() async throws {
        guard let source else { return }
        let generation = captureGeneration
        let engine = AppleSpeechEngine()
        let vad: SileroVAD
        do {
            try await engine.prepare()
            vad = try await SileroVAD.load()
        } catch {
            throw ModelUnavailable(message: error.localizedDescription)
        }
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
        pipeline.preview = AppleLivePreview()
        pipeline.shouldTranslate = { [weak self] in await self?.translationAllowed() ?? false }
        let offset = session.map { Date.now.timeIntervalSince($0.start) } ?? 0
        let events = pipeline.run(metered(capture.samples))
        pipelineTask = Task { [weak self] in
            for await event in events { self?.handle(event, offset: offset) }
        }
        if source.id == PlayerController.sourceID { startSyncedSubtitles(engine: engine, vad: vad) }
    }

    /// The built-in player's synced subtitles run beside the tap: the page decodes the audio the
    /// site has buffered ahead, and the media pipeline makes cues from it before they are spoken.
    /// Which of the two shows depends on the video (`playerState`).
    private func startSyncedSubtitles(engine: AppleSpeechEngine, vad: SileroVAD) {
        var media = MediaPipeline(engine: engine, translator: translator, vad: vad)
        media.maxChunk = prefs.maxChunk
        media.shouldTranslate = { [weak self] in await self?.translationAllowed() ?? false }
        let (inputs, feed) = AsyncStream.makeStream(of: MediaPipeline<SileroVAD>.Input.self)
        let events = media.run(inputs)
        mediaFeed = feed
        mediaTask = Task { [weak self] in
            for await event in events { self?.handleSynced(event) }
        }
        PlayerController.shared.setMediaTap(true)
    }

    private func stopSyncedSubtitles() {
        guard mediaFeed != nil else { return }
        mediaFeed?.finish()
        mediaFeed = nil
        mediaTask?.cancel()
        mediaTask = nil
        PlayerController.shared.setMediaTap(false)
        if synced { synced = false; PlayerController.shared.setSynced(false, lines: prefs.overlayLines) }
        muteForSync = false
        PlayerController.shared.addCues([], reset: true)
        cues = [:]
        cueAudio = [:]
        revealedLines = []
        playerVideo = ""
    }

    /// The player's state, every 500 ms. Synced while the video's buffered audio is coming in and
    /// it isn't a live stream: live streams keep the unsynced subtitles until the player can be
    /// held behind the live edge (design doc §9 phase 5, decision 3 in §10). While an ad plays,
    /// its time is not the video's: nothing changes until it ends.
    func playerState(videoID: String, time: Double, live: Bool, hasAudio: Bool, ad: Bool) {
        guard let feed = mediaFeed, state == .listening, !videoID.isEmpty, time >= 0, !ad else { return }
        if videoID != playerVideo {   // a new video: the old one's cues are of no use
            playerVideo = videoID
            cues = cues.filter { $0.value.videoID == videoID }
            cueAudio = cueAudio.filter { cues[$0.key] != nil }
        }
        let want = hasAudio && !live
        if want != synced {
            synced = want
            muteForSync = want
            PlayerController.shared.setSynced(want, lines: prefs.overlayLines)
        }
        feed.yield(.playhead(videoID: videoID, time: time, process: want))
        // Audio of cues long past (revealed, or skipped by a seek) is no longer needed.
        for (id, cue) in cues where cue.end < time - 60 { cues[id] = nil; cueAudio[id] = nil }
    }

    /// Decoded audio from the player's page.
    func mediaArrived(_ packet: MediaPacket) {
        guard let feed = mediaFeed else { return }
        if packet.samples.contains(where: { abs($0) > 0.003 }) { lastSoundAt = .now }
        feed.yield(.packet(packet))
    }

    /// The page reloaded: tell it again what it has to do.
    func playerPageLoaded() {
        guard mediaFeed != nil else { return }
        PlayerController.shared.setMediaTap(true)
        if synced { PlayerController.shared.setSynced(true, lines: prefs.overlayLines) }
        PlayerController.shared.addCues(Array(cues.values).sorted { $0.start < $1.start }, reset: true)
    }

    /// A cue line began on the video: now it goes into the transcript (and the English with it).
    func revealed(cue id: UUID, line: Int) {
        guard let cue = cues[id], cue.lines.indices.contains(line), revealedLines.insert("\(id):\(line)").inserted,
              var record = session else { return }
        let l = cue.lines[line]
        let t = Date.now.timeIntervalSince(record.start)
        record.lines.append(TranscriptLine(time: t, ja: l.ja, en: l.en, note: l.note, term: l.term))
        if let audio = cueAudio[id] { clips.store(audio, at: t) }
        if (0..<cue.lines.count).allSatisfy({ revealedLines.contains("\(id):\($0)") }) { cueAudio[id] = nil }
        session = record
        overlayRevision += 1
    }

    private func handleSynced(_ event: MediaPipeline<SileroVAD>.Event) {
        switch event {
        case let .cue(cue, audio):
            guard cue.videoID == playerVideo else { return }
            cues[cue.id] = cue
            cueAudio[cue.id] = audio
            PlayerController.shared.addCues([cue])
            clear(.noAudio(name: source?.name ?? ""))
        case let .translated(cost, tokens):
            guard var record = session else { return }
            noteTranslated(cost: cost, tokens: tokens, in: &record)
            session = record
        case let .translationFailed(failure, cost, tokens):
            guard var record = session else { return }
            noteFailure(failure, cost: cost, tokens: tokens, in: &record)
            session = record
        case .translationSkipped: break
        }
    }

    /// Passes audio through and notes when it was last audible (at most one store per second).
    private func metered(_ input: AsyncStream<[Float]>) -> AsyncStream<[Float]> {
        let (output, feed) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
        Task.detached { [weak self] in
            var lastStore = Date.distantPast
            for await samples in input {
                let silent = self?.muteInput == true || self?.muteForSync == true
                feed.yield(silent ? [Float](repeating: 0, count: samples.count) : samples)
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
        do { try await startCapture() } catch is CancellationError {} catch { raiseStartFailure(error) }
    }

    /// Push the current profile and stream info to the live translator.
    func contextChanged() {
        let profile = activeProfile, info = streamInfo, settings = prefs.translation
        session?.profileName = profile?.name
        Task { await translator?.updateContext(profile: profile, streamInfo: info, settings: settings) }
    }

    private func stopCapture() {
        captureGeneration += 1   // a start still awaiting gives up instead of installing its capture
        stopSyncedSubtitles()
        capture?.stop()
        capture = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        // Translations still in flight were cancelled with the pipeline: their lines stay Japanese only.
        pendingLines.removeAll()
        hearing = ""
        pendingEnds.removeAll()
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
        // Several times a second: touch only the live line, not the session and its views.
        if case let .hearing(text) = event { hearing = text; return }
        guard var record = session else { return }
        switch event {
        case .hearing: break
        case let .heard(time, _, ja, asr, audio):
            let t = time + offset
            pendingEnds[t] = Date.now.addingTimeInterval(-asr)
            let line = TranscriptLine(time: t, ja: ja)
            record.lines.append(line)
            pendingLines.insert(line.id)
            clips.store(audio, at: t)
            recentHeard = Array((recentHeard + [line]).suffix(4))
            Task { [weak self, id = line.id] in   // subtitles leave the video once speech stops
                try? await Task.sleep(for: .seconds(8))
                self?.recentHeard.removeAll { $0.id == id }
            }
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
            noteTranslated(cost: cost, tokens: tokens, in: &record)
        case let .translationSkipped(time):
            settle(time + offset, in: &record)
        case let .translationFailed(time, failure, cost, tokens):
            settle(time + offset, in: &record)
            noteFailure(failure, cost: cost, tokens: tokens, in: &record)
        }
        session = record
        overlayRevision += 1
    }

    /// A translation came back (unsynced or synced): its cost, and the issues it clears.
    private func noteTranslated(cost: Double, tokens: Int, in record: inout SessionRecord) {
        record.cost += cost
        ledger.add(UsageEntry(session: record.id, model: LiveTranslator.model, kind: .live, cost: cost, tokens: tokens))
        consecutiveFailures = 0
        for issue in [Issue.offline, .apiOutage, .rateLimited, .keyInvalid, .creditsExhausted] { clear(issue) }
        saveLedgerSoon()
    }

    private func noteFailure(_ failure: ClaudeClient.Failure, cost: Double, tokens: Int, in record: inout SessionRecord) {
        if tokens > 0 {   // billed even though there is nothing to show: it still counts toward the cap
            record.cost += cost
            ledger.add(UsageEntry(session: record.id, model: LiveTranslator.model, kind: .live, cost: cost, tokens: tokens))
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
        // One explanation at a time: the others go back to their Explain button instead of loading forever.
        for (id, task) in explainTasks {
            task.cancel()
            if id != line.id, case .loading? = explain[id] { explain[id] = nil }
        }
        explainTasks = [:]
        let previous: [Explainer.Explanation]
        if case .result(let list, _) = explain[line.id] { previous = list } else { previous = [] }
        explain[line.id] = .loading
        let context = contextLines(before: line)
        let profile = activeProfile, info = streamInfo
        explainTasks[line.id] = Task {
            do {
                let r = try await Explainer(client: ClaudeClient(apiKey: key)).explain(line, context: context, profile: profile, streamInfo: info)
                guard !Task.isCancelled else { return }
                explain[line.id] = .result(previous + [r.explanation], cost: r.cost)
                ledger.add(UsageEntry(session: session?.id, model: Explainer.model, kind: .explain,
                                                 cost: r.cost, tokens: r.usage.inputTokens + r.usage.outputTokens))
                session?.cost += r.cost
                if prefs.saveExplanations { session?.explanations[line.id, default: []].append(r.explanation) }
                saveLedgerSoon()
            } catch {
                if let billed = error as? ClaudeClient.BilledFailure {   // billed with nothing to show: still counts
                    ledger.add(UsageEntry(session: session?.id, model: Explainer.model, kind: .explain,
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

    /// Explain `line` and bring its explanation into view.
    func focusExplanation(_ line: TranscriptLine) {
        explain(line)
        explainFocus = line.id
        focusRequests += 1
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

    /// Sent to the translator and the explainer. For the built-in player, the video's channel
    /// too (the title is filled in from the page; see PlayerController).
    var streamInfo: String {
        let channel = source?.id == PlayerController.sourceID ? PlayerController.shared.channel : ""
        return [session?.streamTitle ?? "", session?.game ?? "", channel.isEmpty ? "" : "channel: \(channel)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Replay

    /// `line`'s audio (16 kHz mono), while it is still in memory.
    func clipSamples(_ line: TranscriptLine) -> [Int16]? { clips.clip(at: line.time) }

    /// Whether `line`'s audio is still in memory (this session, last half hour or so).
    func canReplay(_ line: TranscriptLine) -> Bool { clips.clip(at: line.time) != nil }

    /// Play `line`'s audio again: every line from the same chunk shares it. Again on the same
    /// clip stops it.
    func replay(_ line: TranscriptLine, rate: Float = 1, loop: Bool = false) {
        if replaying == line.time { stopReplay(); return }
        guard let clip = clips.clip(at: line.time) else { return }
        clipPlayer.onFinish = { [weak self] in self?.replayEnded() }
        guard clipPlayer.play(clip, rate: rate, loop: loop) else { replayEnded(); return }
        muteInput = source?.id.hasPrefix("mic:") == true
        replaying = line.time
    }

    /// The row play button for `line`, if its audio is still in memory.
    func replayControl(for line: TranscriptLine) -> TranscriptRow.ReplayControl? {
        guard canReplay(line) else { return nil }
        return .init(playing: replaying == line.time) { [weak self] in self?.replay(line) }
    }

    func stopReplay() {
        clipPlayer.stop()
        replayEnded()
    }

    private func replayEnded() {
        replaying = nil
        muteInput = false
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
