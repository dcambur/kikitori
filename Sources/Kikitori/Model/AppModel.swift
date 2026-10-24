import AppKit
import AVFoundation
import CoreAudio
import Foundation
import KikitoriCore
import Observation
import os
import Synchronization

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
    /// ⌃⌥O: Live opens its source picker as soon as it is on screen.
    var wantsSourcePicker = false
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
    // These three are also read or written by the audio task (`metered`), off the main actor.
    private nonisolated let lastSound = OSAllocatedUnfairLock(initialState: Date.now)
    /// Set while a clip plays from a microphone source, which would hear it again: capture
    /// passes silence instead (keeping the timeline) until it stops.
    private nonisolated let muteInput = Atomic(false)
    /// Set while synced: the player's sound is recognized from its buffered audio instead.
    private nonisolated let muteForSync = Atomic(false)
    // Synced subtitles: the media pipeline's input, its events, and the cues not yet in the transcript.
    @ObservationIgnored private var mediaFeed: AsyncStream<MediaPipeline<SileroVAD>.Input>.Continuation?
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    /// Who is speaking, for speaker labels: one per pipeline (the tap, the built-in player's
    /// read-ahead), kept for the whole session so a voice keeps its letter across pauses.
    @ObservationIgnored private var liveSpeakers: DeferredSpeakerTracker?
    @ObservationIgnored private var mediaSpeakers: DeferredSpeakerTracker?
    @ObservationIgnored private var cues: [UUID: Cue] = [:]
    @ObservationIgnored private var cueAudio: [UUID: [Float]] = [:]
    /// Cue lines in the transcript ("<cue>:<first character>" → its transcript line), and the
    /// cues whose translation has come back (or won't).
    @ObservationIgnored private var releasedLines: [String: UUID] = [:]
    @ObservationIgnored private var settledCues: Set<UUID> = []
    @ObservationIgnored private var playerVideo = ""
    @ObservationIgnored private var lastMediaAudio = Date.distantPast
    /// Audio packets from the page this session (for the player's log).
    @ObservationIgnored private(set) var mediaPackets = 0
    @ObservationIgnored private let syncLog = Logger(subsystem: "app.kikitori", category: "sync")
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
            if prefs.translate, let latency { return String(format: "Translating · ≈ %.1f s", latency) }
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
        startSpeakerTracking(player: source.id == PlayerController.sourceID)
        if let key = KeychainStore.apiKey() {
            hasAPIKey = true
            translator = LiveTranslator(client: ClaudeClient(apiKey: key), profile: activeProfile,
                                        streamInfo: streamInfo, settings: prefs.translation)
        } else {
            hasAPIKey = false
            translator = nil
            if prefs.translate { raise(.noKey) }
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
        saveLedgerNow()
        session = nil
        source = nil
        translator = nil
        issues = []
        stopReplay()
        liveSpeakers = nil
        mediaSpeakers = nil
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
        // After each await, a newer decision (stop, another start) wins over this start's own
        // failure, which would otherwise tear down the newer session.
        do {
            try await engine.prepare()
            vad = try await SileroVAD.load()
        } catch {
            guard generation == captureGeneration else { throw CancellationError() }
            throw ModelUnavailable(message: error.localizedDescription)
        }
        if source.id.hasPrefix("mic:"), !(await AVCaptureDevice.requestAccess(for: .audio)) {
            guard generation == captureGeneration else { throw CancellationError() }
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
        lastSound.withLock { $0 = .now }
        var pipeline = LivePipeline(engine: engine, translator: translator, vad: vad, contextTerms: [])
        pipeline.maxChunk = prefs.maxChunk
        pipeline.preview = AppleLivePreview()
        // The tracker lasts the session, the pipeline's clock restarts with each run: on the
        // session's clock, audio before a pause never stands in for audio after it.
        let installed = session.map { Date.now.timeIntervalSince($0.start) } ?? 0
        pipeline.speakers = liveSpeakers.map { ShiftedSpeakerTracker($0, by: installed) }
        pipeline.shouldTranslate = { [weak self] in await self?.translationAllowed() ?? false }
        // The run's clock starts at its first audio, which for the built-in player comes only once
        // the page first plays sound: line times count from then.
        let firstAudio = OSAllocatedUnfairLock<Date?>(initialState: nil)
        let sessionStart = session?.start ?? .now
        let events = pipeline.run(metered(capture.samples, firstAudio: firstAudio))
        let sessionID = session?.id
        pipelineTask = Task { [weak self] in
            for await event in events {
                // Paused or stopped: what is still queued belongs to the run that ended (its lines
                // would wait for English forever, or land in the next session); only its bills
                // count. The stream ends once its buffer is empty, and that stops the stages.
                guard !Task.isCancelled else {
                    switch event {
                    case let .translated(_, _, cost, _, tokens), let .translationFailed(_, _, cost, tokens):
                        self?.billLate(cost, tokens: tokens, session: sessionID)
                    default: break
                    }
                    continue
                }
                self?.handle(event, offset: (firstAudio.withLock { $0 } ?? .now).timeIntervalSince(sessionStart))
            }
        }
        if source.id == PlayerController.sourceID { startSyncedSubtitles(engine: engine, vad: vad) }
    }

    /// The built-in player's synced subtitles run beside the tap: the page decodes the audio the
    /// site has buffered ahead, and the media pipeline makes cues from it before they are spoken.
    /// Which of the two shows depends on the video (`playerState`).
    private func startSyncedSubtitles(engine: AppleSpeechEngine, vad: SileroVAD) {
        var media = MediaPipeline(engine: engine, translator: translator, vad: vad)
        media.maxChunk = prefs.maxChunk
        media.speakers = mediaSpeakers
        media.shouldTranslate = { [weak self] in await self?.translationAllowed() ?? false }
        let (inputs, feed) = AsyncStream.makeStream(of: MediaPipeline<SileroVAD>.Input.self)
        let events = media.run(inputs)
        mediaFeed = feed
        let sessionID = session?.id
        mediaTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else {   // as for the tap's pipeline (startCapture)
                    switch event {
                    case let .translation(_, _, cost, tokens), let .translationFailed(_, _, cost, tokens):
                        self?.billLate(cost, tokens: tokens, session: sessionID)
                    default: break
                    }
                    continue
                }
                self?.handleSynced(event)
            }
        }
        PlayerController.shared.setMediaTap(true)
    }

    private func stopSyncedSubtitles() {
        guard mediaFeed != nil else { return }
        mediaFeed?.finish()
        mediaFeed = nil
        mediaPackets = 0
        mediaTask?.cancel()
        mediaTask = nil
        PlayerController.shared.setMediaTap(false)
        if synced { synced = false; PlayerController.shared.setSynced(false, lines: prefs.overlayLines) }
        muteForSync.store(false, ordering: .relaxed)
        PlayerController.shared.addCues([], reset: true)
        cues = [:]
        cueAudio = [:]
        releasedLines = [:]
        settledCues = []
        playerVideo = ""
    }

    /// The player's state, every 500 ms. Synced while the video's buffered audio is coming in and
    /// it isn't a live stream: live streams keep the unsynced subtitles until the player can be
    /// held behind the live edge (design doc §9 phase 5, decision 3 in §10). While an ad plays,
    /// its time is not the video's: nothing changes until it ends.
    func playerState(videoID: String, time: Double, live: Bool, hasAudio: Bool, ad: Bool) {
        guard let feed = mediaFeed, state == .listening, !videoID.isEmpty, time >= 0, !ad else { return }
        if videoID != playerVideo {   // a new video: the old one's cues are of no use
            syncLog.notice("sync: now playing \(videoID, privacy: .public) (a new video, audio track, MediaSource after an ad, or a reload)")
            playerVideo = videoID
            cues = cues.filter { $0.value.videoID == videoID }
            cueAudio = cueAudio.filter { cues[$0.key] != nil }
        }
        // Leave synced mode only after 5 s without the video's audio at the playhead (decoding
        // stopped, say): a seek beyond what's decoded takes a moment to fill and shouldn't flap.
        if hasAudio { lastMediaAudio = .now }
        let want = !live && (hasAudio || (synced && Date.now.timeIntervalSince(lastMediaAudio) < 5))
        if want != synced {
            syncLog.notice("sync: \(want ? "synced" : "not synced", privacy: .public) (decoded audio at the playhead: \(hasAudio), live: \(live))")
            synced = want
            muteForSync.store(want, ordering: .relaxed)
            PlayerController.shared.setSynced(want, lines: prefs.overlayLines)
        }
        feed.yield(.playhead(videoID: videoID, time: time, process: want))
        // Audio of cues long past (revealed, or skipped by a seek) is no longer needed. The cues
        // themselves stay as long as the page keeps them (30 min): a seek back can still reveal
        // one, and a translation still on its way finds its lines.
        for id in Array(cueAudio.keys) where cues[id].map({ $0.end < time - 60 }) ?? true { cueAudio[id] = nil }
        for (id, cue) in cues where cue.end < time - 1800 {
            settleCue(id)
            cues[id] = nil; settledCues.remove(id)
            releasedLines = releasedLines.filter { !$0.key.hasPrefix("\(id):") }
        }
    }

    /// Decoded audio from the player's page.
    func mediaArrived(_ packet: MediaPacket) {
        guard let feed = mediaFeed else { return }
        mediaPackets += 1
        if packet.samples.contains(where: { abs($0) > 0.003 }) { lastSound.withLock { $0 = .now } }
        feed.yield(.packet(packet))
    }

    /// The page reloaded: tell it again what it has to do.
    func playerPageLoaded() {
        guard mediaFeed != nil else { return }
        PlayerController.shared.setMediaTap(true)
        if synced { PlayerController.shared.setSynced(true, lines: prefs.overlayLines) }
        PlayerController.shared.addCues(Array(cues.values).sorted { $0.start < $1.start }, reset: true)
    }

    /// A line began on the video (characters `from..<to` of the cue as the page has it): the
    /// cue's lines starting there go into the transcript, with their English if it has come.
    /// The page may still have the cue as one Japanese line while the app already has the
    /// translator's lines (the English came just as it began): then they all go in at once.
    func revealed(cue id: UUID, from: Int, to: Int) {
        guard let cue = cues[id], var record = session else { return }
        let t = Date.now.timeIntervalSince(record.start)
        for l in cue.lines where l.from >= from && l.from < max(to, from + 1) && releasedLines["\(id):\(l.from)"] == nil {
            var line = TranscriptLine(time: t, ja: l.ja, en: l.en, note: l.note, term: l.term)
            line.speaker = l.speaker
            record.lines.append(line)
            releasedLines["\(id):\(l.from)"] = line.id
            if !settledCues.contains(id) { pendingLines.insert(line.id) }   // its English is on the way
            if let audio = cueAudio[id] { clips.store(audio, at: t) }
        }
        if settledCues.contains(id), cue.lines.allSatisfy({ releasedLines["\(id):\($0.from)"] != nil }) { cueAudio[id] = nil }
        session = record
        overlayRevision += 1
    }

    /// The translation of a cue came back: the page gets its lines, unless it has begun showing
    /// it (then the video stays as it is) and its Japanese is in the transcript already: those
    /// lines take the English instead.
    private func cueTranslated(_ id: UUID, lines: [Cue.Line], in record: inout SessionRecord) {
        guard var cue = cues[id] else { return }
        let released = Set(releasedLines.filter { $0.key.hasPrefix("\(id):") }.values)
        cue.lines = lines
        cues[id] = cue
        settledCues.insert(id)
        guard !released.isEmpty else { PlayerController.shared.addCues([cue]); return }
        guard let i = record.lines.firstIndex(where: { released.contains($0.id) }) else { return }
        let time = record.lines[i].time
        record.lines.removeAll { released.contains($0.id) }
        let translated = lines.map { l in
            var line = TranscriptLine(time: time, ja: l.ja, en: l.en, note: l.note, term: l.term)
            line.speaker = l.speaker
            return line
        }
        record.lines.insert(contentsOf: translated, at: min(i, record.lines.count))
        for (l, line) in zip(lines, translated) { releasedLines["\(id):\(l.from)"] = line.id }
        pendingLines.subtract(released)
    }

    /// No English is coming for this cue: its lines in the transcript stop waiting for it.
    private func settleCue(_ id: UUID) {
        settledCues.insert(id)
        pendingLines.subtract(releasedLines.filter { $0.key.hasPrefix("\(id):") }.values)
    }

    private func handleSynced(_ event: MediaPipeline<SileroVAD>.Event) {
        switch event {
        case let .cue(cue, audio):
            guard cue.videoID == playerVideo else { return }
            cues[cue.id] = cue
            cueAudio[cue.id] = audio
            PlayerController.shared.addCues([cue])
            clear(.noAudio(name: source?.name ?? ""))
        case let .translation(id, lines, cost, tokens):
            guard var record = session else { return }
            noteTranslated(cost: cost, tokens: tokens, in: &record)
            cueTranslated(id, lines: lines, in: &record)
            session = record
            overlayRevision += 1
        case let .translationFailed(id, failure, cost, tokens):
            guard var record = session else { return }
            noteFailure(failure, cost: cost, tokens: tokens, in: &record)
            settleCue(id)
            session = record
        case let .translationSkipped(id):
            settleCue(id)
        }
    }

    /// Passes audio through and notes when it was last audible (at most one store per second),
    /// and when the first audio came (`firstAudio`).
    private func metered(_ input: AsyncStream<[Float]>, firstAudio: OSAllocatedUnfairLock<Date?>) -> AsyncStream<[Float]> {
        let (output, feed) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
        Task.detached { [weak self] in
            var lastStore = Date.distantPast
            for await samples in input {
                if lastStore == .distantPast { firstAudio.withLock { $0 = $0 ?? .now } }
                let silent = self.map { $0.muteInput.load(ordering: .relaxed) || $0.muteForSync.load(ordering: .relaxed) } ?? false
                feed.yield(silent ? [Float](repeating: 0, count: samples.count) : samples)
                if Date.now.timeIntervalSince(lastStore) > 1, samples.contains(where: { abs($0) > 0.003 }) {
                    lastStore = .now
                    self?.lastSound.withLock { $0 = .now }
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
        let silent = Date.now.timeIntervalSince(lastSound.withLock { $0 })
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

    /// Translation on or off (Live toolbar, Watch panel, menu bar, Settings). Takes effect from the
    /// next line; turning it off clears the issues only translation raises.
    func setTranslate(_ on: Bool) {
        prefs.translate = on
        if on {
            if isLive, translator == nil { raise(.noKey) }
        } else {
            for issue in [Issue.noKey, .keyInvalid, .creditsExhausted, .capReached, .offline, .apiOutage, .rateLimited] {
                clear(issue)
            }
        }
    }

    private func translationAllowed() -> Bool {
        guard prefs.translate else { return false }   // Japanese only: no request, no cost
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
        case let .heard(time, _, ja, asr, audio, turns):
            let t = time + offset
            pendingEnds[t] = Date.now.addingTimeInterval(-asr)
            // With speakers tracked, one line per speaker turn (same time: the chunk's start).
            let heard = turns.isEmpty ? [TranscriptLine(time: t, ja: ja)] : turns.map { var l = $0; l.time = t; return l }
            record.lines += heard
            if prefs.translate, translator != nil { pendingLines.formUnion(heard.map(\.id)) }   // else no dots: no English is coming
            clips.store(audio, at: t)
            recentHeard = Array((recentHeard + heard).suffix(4))
            Task { [weak self, ids = heard.map(\.id)] in   // subtitles leave the video once speech stops
                try? await Task.sleep(for: .seconds(8))
                self?.recentHeard.removeAll { ids.contains($0.id) }
            }
            clear(.noAudio(name: source?.name ?? ""))
        case let .translated(time, lines, cost, _, tokens):
            let t = time + offset
            // The chunk's untranslated lines (one, or one per speaker turn) are next to each other.
            if let i = record.lines.firstIndex(where: { $0.time == t && $0.en == nil }) {
                var j = i
                while j + 1 < record.lines.count, record.lines[j + 1].time == t, record.lines[j + 1].en == nil { j += 1 }
                for line in record.lines[i...j] { pendingLines.remove(line.id) }
                let translated = lines.map { var l = $0; l.time = t; return l }
                // No lines back means fillers or backchannels: the Japanese stays, without English.
                if !translated.isEmpty { record.lines.replaceSubrange(i...j, with: translated) }
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

    /// A translation that came back after its run was paused or stopped: nothing shows it, but
    /// it was billed.
    private func billLate(_ cost: Double, tokens: Int, session id: UUID?) {
        guard tokens > 0 else { return }
        if session?.id == id { session?.cost += cost }
        ledger.add(UsageEntry(session: id, model: LiveTranslator.model, kind: .live, cost: cost, tokens: tokens))
        saveLedgerNow()   // it may come just before the app quits
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
        case .overloaded, .timedOut: if consecutiveFailures >= 3 { raise(.apiOutage) }
        default: break
        }
    }

    private func settle(_ time: Double, in record: inout SessionRecord) {
        for line in record.lines where line.time == time && line.en == nil { pendingLines.remove(line.id) }
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
                // Billed even if it was cancelled meanwhile (another Explain): it counts toward the cap.
                ledger.add(UsageEntry(session: session?.id, model: Explainer.model, kind: .explain,
                                                 cost: r.cost, tokens: r.usage.total))
                session?.cost += r.cost
                saveLedgerSoon()
                guard !Task.isCancelled else { return }
                explain[line.id] = .result(previous + [r.explanation], cost: r.cost)
                if prefs.saveExplanations { session?.explanations[line.id, default: []].append(r.explanation) }
            } catch {
                if let billed = error as? ClaudeClient.BilledFailure {   // billed with nothing to show: still counts
                    ledger.add(UsageEntry(session: session?.id, model: Explainer.model, kind: .explain,
                                                     cost: billed.cost, tokens: billed.usage.total))
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

    /// What an explanation has cost on average so far, to show on the Explain button.
    var explainCost: Double? {
        let past = ledger.entries.filter { $0.kind == .explain && $0.cost > 0 }
        return past.isEmpty ? nil : past.reduce(0) { $0 + $1.cost } / Double(past.count)
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

    /// The newest line Explain can take: translated, or settled without English (translation off).
    var lastLine: TranscriptLine? { session?.lines.last { !pendingLines.contains($0.id) } }

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
        muteInput.store(source?.id.hasPrefix("mic:") == true, ordering: .relaxed)
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
        muteInput.store(false, ordering: .relaxed)
    }

    // MARK: Profiles

    // MARK: Speaker labels

    /// Speaker labels for this session, when the setting is on: the trackers load in the
    /// background (lines stay unlabelled until then). The active profile's saved voice, if any,
    /// gets a slot first and its name.
    private func startSpeakerTracking(player: Bool) {
        liveSpeakers = nil
        mediaSpeakers = nil
        guard prefs.speakerLabels else { return }
        let voices = activeProfile.flatMap { p in voiceSample(for: p).map { [(name: p.name, samples: $0)] } } ?? []
        let sessionID = session?.id
        let named: @Sendable ([Int: String]) -> Void = { [weak self] names in
            Task { @MainActor in
                guard let self, self.session?.id == sessionID else { return }
                for (slot, name) in names { self.session?.speakerNames = (self.session?.speakerNames ?? [:]).merging([SpeakerLabeler.label(slot): name]) { $1 } }
            }
        }
        liveSpeakers = DeferredSpeakerTracker(voices: voices, onLoad: named)
        if player { mediaSpeakers = DeferredSpeakerTracker(voices: voices, onLoad: named) }
    }

    /// Names a speaker label for the rest of this session ("A" → "Fubuki"). With a profile, also
    /// remembers the voice (experimental, asked for separately): the newest seconds where only that
    /// voice spoke become the profile's voice sample, and the next session with this profile puts
    /// it in a slot from the start.
    func nameSpeaker(_ label: String, as name: String, profile: Profile? = nil) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard session != nil, !name.isEmpty else { return }
        session?.speakerNames = (session?.speakerNames ?? [:]).merging([label: name]) { $1 }
        guard let profile, let slot = label.unicodeScalars.first.map({ Int($0.value) - 65 }) else { return }
        let tracker = synced ? mediaSpeakers : liveSpeakers
        Task { [weak self] in
            let samples = await tracker?.voice(slot: slot) ?? []
            guard samples.count >= 16_000 * 3 else { return }   // too little to tell a voice by
            self?.saveVoice(samples, for: profile)
        }
    }

    private func voiceURL(_ profile: Profile) -> URL { supportURL.appending(path: "voices/\(profile.id.uuidString).f32") }

    /// A profile's saved voice sample (16 kHz mono), if one was saved.
    func voiceSample(for profile: Profile) -> [Float]? {
        guard let data = try? Data(contentsOf: voiceURL(profile)), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func hasVoice(_ profile: Profile) -> Bool { FileManager.default.fileExists(atPath: voiceURL(profile).path) }

    private func saveVoice(_ samples: [Float], for profile: Profile) {
        let url = voiceURL(profile)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? samples.withUnsafeBytes { Data($0) }.write(to: url)
    }

    func forgetVoice(_ profile: Profile) { try? FileManager.default.removeItem(at: voiceURL(profile)) }

    func saveProfiles() { Self.save(profiles, to: supportURL.appending(path: "profiles.json")) }

    func upsert(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
        saveProfiles()
    }

    func deleteProfile(_ id: UUID) {
        if let p = profiles.first(where: { $0.id == id }) { forgetVoice(p) }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        saveProfiles()
    }

    // MARK: Persistence

    func saveSession() {
        guard let session else { return }
        do { try sessionStore.save(session) } catch { Self.storeLog.error("session not saved: \(error, privacy: .public)") }
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

    func saveLedgerNow() {
        ledgerSave?.cancel()
        Self.save(ledger.entries, to: supportURL.appending(path: "usage.json"))
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
        try? FileManager.default.removeItem(at: supportURL.appending(path: "voices"))   // the profiles' voice samples
        ledger.entries = []
        Self.save(ledger.entries, to: supportURL.appending(path: "usage.json"))
    }

    /// A file that can't be read is moved aside, not left for the next save to overwrite: wiping
    /// profiles, or the spend the monthly cap counts.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder.kikitori.decode(T.self, from: data)
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            storeLog.error("\(url.lastPathComponent, privacy: .public) can't be read, kept as \(aside.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        do { try JSONEncoder.kikitori.encode(value).write(to: url, options: .atomic) } catch {
            storeLog.error("\(url.lastPathComponent, privacy: .public) not saved: \(error, privacy: .public)")
        }
    }

    private static let storeLog = Logger(subsystem: "app.kikitori", category: "store")
}
