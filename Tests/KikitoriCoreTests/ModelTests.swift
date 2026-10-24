import Foundation
import Testing
@testable import KikitoriCore

/// A temporary folder removed when the test ends, pass or fail.
final class TempDir {
    let url = FileManager.default.temporaryDirectory.appending(path: "kikitori-test-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

func day(_ s: String, _ hour: Int = 12) -> Date {
    var c = DateComponents(); c.calendar = .current
    let p = s.split(separator: "-").map { Int($0)! }
    c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = hour
    return c.date!
}

@Suite struct UsageLedgerTests {
    @Test func cycleStartsOnTheConfiguredDay() {
        let l = UsageLedger(cycleStartDay: 15)
        #expect(l.cycle(containing: day("2026-10-22")).start == day("2026-10-15", 0))
        #expect(l.cycle(containing: day("2026-10-22")).end == day("2026-11-15", 0))
        #expect(l.cycle(containing: day("2026-10-03")).start == day("2026-09-15", 0))
    }

    @Test func spendTodayCycleAndProjection() {
        let entries = [
            UsageEntry(date: day("2026-10-14"), session: nil, model: "h", kind: .live, cost: 5, tokens: 1),  // last cycle
            UsageEntry(date: day("2026-10-16"), session: nil, model: "h", kind: .live, cost: 1, tokens: 10),
            UsageEntry(date: day("2026-10-18"), session: nil, model: "s", kind: .explain, cost: 1, tokens: 20),
            UsageEntry(date: day("2026-10-22", 9), session: nil, model: "h", kind: .live, cost: 1, tokens: 30),
        ]
        let l = UsageLedger(entries: entries, cycleStartDay: 15)
        let now = day("2026-10-22", 12)
        #expect(l.spentThisCycle(now: now) == 3)
        #expect(l.spentToday(now: now) == 1)
        #expect(l.tokens(in: l.cycle(containing: now), kind: .live) == 40)
        // 3 active days averaging $1/day, plus ~23.5 days left (one more hour when summer time ends).
        #expect(abs(l.projectedCycleSpend(now: now) - (3 + 23.5)) < 0.05)
        #expect(l.daily(now: now).count == 31)
        let reach = try! #require(l.projectedDate(reaching: 10, now: now))
        #expect(reach > now && reach < l.cycle(containing: now).end)
        #expect(l.projectedDate(reaching: 100, now: now) == nil)
    }

    @Test func liveRequestsMergePerSessionHour() {
        let session = UUID()
        func live(_ minute: Int, hour: Int = 12, _ s: UUID? = nil) -> UsageEntry {
            UsageEntry(date: day("2026-10-22", hour).addingTimeInterval(Double(minute * 60)), session: s ?? session,
                       model: "h", kind: .live, cost: 1, tokens: 10)
        }
        var l = UsageLedger(entries: [live(0), live(1), live(2)], cycleStartDay: 15)   // loaded per chunk: compacted
        #expect(l.entries.count == 1 && l.entries[0].cost == 3 && l.entries[0].tokens == 30)
        l.add(live(59))
        l.add(live(0, hour: 13))                // next hour
        l.add(live(5, hour: 13, UUID()))        // another session
        l.add(UsageEntry(date: day("2026-10-22", 13), session: session, model: "s", kind: .explain, cost: 1, tokens: 1))
        l.add(UsageEntry(date: day("2026-10-22", 13), session: session, model: "s", kind: .explain, cost: 1, tokens: 1))
        #expect(l.entries.map(\.cost) == [4, 1, 1, 1, 1])
        #expect(l.spentToday(now: day("2026-10-22", 18)) == 8)
    }
}

@Suite struct SessionStoreTests {
    @Test func savesLoadsSearchesAndDeletes() throws {
        let dir = TempDir()
        let store = SessionStore(directory: dir.url)
        var r = SessionRecord(start: .now.addingTimeInterval(-600), sourceName: "Firefox", sourceID: "org.mozilla.firefox",
                              profileName: "Hoshimi Kuu")
        r.lines = [TranscriptLine(time: 1, ja: "てぇてぇ", en: "So wholesome", note: "fan slang", term: "てぇてぇ")]
        try store.save(r)
        #expect(store.summaries().map(\.id) == [r.id])
        #expect(store.load(r.id) == r)
        #expect(store.search("wholesome") == [r.id])
        #expect(store.search("創造") == [])
        try store.delete([r.id])
        #expect(store.summaries().isEmpty && store.load(r.id) == nil)
    }

    @Test func aDamagedIndexLosesNoSessions() throws {
        let dir = TempDir()
        let store = SessionStore(directory: dir.url)
        func session(_ ago: Double) -> SessionRecord {
            var r = SessionRecord(start: .now.addingTimeInterval(-ago), sourceName: "Firefox", sourceID: "f", profileName: nil)
            r.lines = [TranscriptLine(time: 1, ja: "おはよう")]
            return r
        }
        let a = session(900), b = session(600)
        try store.save(a)
        try store.save(b)
        try Data("{".utf8).write(to: store.indexURL)   // cut off by a crash or a full disk
        #expect(store.summaries().map(\.id) == [b.id, a.id])
        let c = session(300)
        try store.save(c)
        #expect(store.summaries().map(\.id) == [c.id, b.id, a.id])
    }

    @Test func shortEmptySessionsAreNotKept() throws {
        let dir = TempDir()
        let store = SessionStore(directory: dir.url)
        try store.save(SessionRecord(start: .now.addingTimeInterval(-20), sourceName: "Safari", sourceID: "s", profileName: nil))
        #expect(store.summaries().isEmpty)
    }
}

@Suite struct ExportAndProfileFileTests {
    let lines = [TranscriptLine(time: 1.5, ja: "え、待って", en: "Wait, what?"),
                 TranscriptLine(time: 3661.25, ja: "草", en: "LOL", note: "laughter slang", term: "草")]

    @Test func srtAndVttCues() {
        var e = TranscriptExport()
        e.format = .srt
        let srt = e.render(lines)
        #expect(srt.hasPrefix("1\n00:00:01,500 --> 00:00:08,500\nえ、待って\nWait, what?\n"))
        #expect(srt.contains("2\n01:01:01,250 --> 01:01:05,250\n草\nLOL"))
        e.format = .vtt
        e.includeJapanese = false
        #expect(e.render(lines).hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:08.500\nWait, what?\n"))
    }

    @Test func linesOfOneChunkFollowEachOther() {
        let chunk = [TranscriptLine(time: 10, ja: "あ", en: "A"), TranscriptLine(time: 10, ja: "い", en: "B"),
                     TranscriptLine(time: 10, ja: "う", en: "C"), TranscriptLine(time: 16, ja: "え", en: "D")]
        let srt = TranscriptExport().render(chunk)
        #expect(srt.contains("00:00:10,000 --> 00:00:12,000\nあ"))
        #expect(srt.contains("00:00:12,000 --> 00:00:14,000\nい"))
        #expect(srt.contains("00:00:14,000 --> 00:00:16,000\nう"))
        #expect(srt.contains("00:00:16,000 --> 00:00:20,000\nえ"))
    }

    @Test func markdownHasNotes() {
        var e = TranscriptExport()
        e.format = .markdown
        let md = e.render(lines, title: "Kuu")
        #expect(md.contains("# Kuu") && md.contains("**1:01:01**") && md.contains("> 注 草: laughter slang"))
    }

    @Test func profileRoundTripAndMerge() throws {
        let mine = Profile(name: "Hoshimi Kuu", nameJa: "星見くう",
                           glossary: [GlossaryTerm(term: "星屑", translateAs: "Stardust"), GlossaryTerm(term: "くう", reading: "kuu")])
        let parsed = try ProfileFile.parse(ProfileFile.export(mine))
        #expect(parsed.glossary == mine.glossary && parsed.nameJa == "星見くう")

        var theirs = mine
        theirs.glossary = [GlossaryTerm(term: "星屑", translateAs: "Stardusts"), GlossaryTerm(term: "てぇてぇ")]
        let plan = ProfileFile.plan(theirs, into: mine)
        #expect(plan.added.map(\.term) == ["てぇてぇ"] && plan.conflicts.count == 1)
        let merged = ProfileFile.apply(plan, to: mine, keep: ["星屑": .imported], appendNotes: "new note")
        #expect(merged.glossary.first { $0.term == "星屑" }?.translateAs == "Stardusts")
        #expect(merged.glossary.count == 3 && merged.notes == "new note")
    }

    @Test func badProfileFilesAreRejected() {
        #expect(throws: ProfileFile.ImportError.self) { try ProfileFile.parse(Data("{}".utf8)) }
        #expect(throws: ProfileFile.ImportError.self) {
            try ProfileFile.parse(Data(#"{"version":2,"name":"x","nameJa":"","colour":"","channel":"","glossary":[],"notes":""}"#.utf8))
        }
    }
}
