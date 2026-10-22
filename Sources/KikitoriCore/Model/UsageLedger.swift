import Foundation

/// Every paid Claude request, kept so the Usage screen can show cycle spend, projections and
/// the per-model split (spec §5.6). Costs are estimates from token counts × pricing.json.
public struct UsageEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case live, explain }
    public var date: Date
    public var session: UUID?
    public var model: String
    public var kind: Kind
    public var cost: Double
    public var tokens: Int

    public init(date: Date = .now, session: UUID?, model: String, kind: Kind, cost: Double, tokens: Int) {
        self.date = date; self.session = session; self.model = model; self.kind = kind
        self.cost = cost; self.tokens = tokens
    }
}

public struct UsageLedger: Sendable {
    public var entries: [UsageEntry]
    /// Day of the month the Max billing cycle starts (1–28).
    public var cycleStartDay: Int
    var calendar = Calendar.current

    public init(entries: [UsageEntry] = [], cycleStartDay: Int) {
        self.entries = entries
        self.cycleStartDay = min(max(cycleStartDay, 1), 28)
    }

    /// The billing cycle containing `date`: [start, end).
    public func cycle(containing date: Date = .now) -> DateInterval {
        var start = calendar.dateComponents([.year, .month], from: date)
        start.day = cycleStartDay
        var startDate = calendar.date(from: start)!
        if startDate > date { startDate = calendar.date(byAdding: .month, value: -1, to: startDate)! }
        let end = calendar.date(byAdding: .month, value: 1, to: startDate)!
        return DateInterval(start: startDate, end: end)
    }

    public func spent(in interval: DateInterval, kind: UsageEntry.Kind? = nil) -> Double {
        entries.filter { interval.contains($0.date) && (kind == nil || $0.kind == kind) }.reduce(0) { $0 + $1.cost }
    }

    public func spentThisCycle(now: Date = .now) -> Double { spent(in: cycle(containing: now)) }

    public func spentToday(now: Date = .now) -> Double {
        spent(in: calendar.dateInterval(of: .day, for: now)!)
    }

    /// Spend per day of the current cycle, oldest first (days without spend are 0).
    public func daily(now: Date = .now) -> [(day: Date, cost: Double)] {
        let c = cycle(containing: now)
        var days: [(Date, Double)] = []
        var d = c.start
        while d < c.end {
            let next = calendar.date(byAdding: .day, value: 1, to: d)!
            days.append((d, spent(in: DateInterval(start: d, end: next))))
            d = next
        }
        return days
    }

    /// Spend so far + average daily spend of the last 7 active days × days left in the cycle.
    public func projectedCycleSpend(now: Date = .now) -> Double {
        let c = cycle(containing: now)
        let soFar = spent(in: DateInterval(start: c.start, end: now))
        let today = calendar.startOfDay(for: now)
        let active = daily(now: now).filter { $0.day <= today && $0.cost > 0 }.suffix(7)
        guard !active.isEmpty else { return soFar }
        let average = active.reduce(0) { $0 + $1.cost } / Double(active.count)
        let daysLeft = c.end.timeIntervalSince(now) / 86_400
        return soFar + average * daysLeft
    }

    /// When the projected pace reaches `amount`, if it does within this cycle.
    public func projectedDate(reaching amount: Double, now: Date = .now) -> Date? {
        let c = cycle(containing: now)
        let soFar = spentThisCycle(now: now)
        if soFar >= amount { return now }
        let projected = projectedCycleSpend(now: now)
        guard projected > soFar else { return nil }
        let perSecond = (projected - soFar) / c.end.timeIntervalSince(now)
        let date = now.addingTimeInterval((amount - soFar) / perSecond)
        return date < c.end ? date : nil
    }

    public func tokens(in interval: DateInterval, kind: UsageEntry.Kind) -> Int {
        entries.filter { interval.contains($0.date) && $0.kind == kind }.reduce(0) { $0 + $1.tokens }
    }

    public func count(in interval: DateInterval, kind: UsageEntry.Kind) -> Int {
        entries.filter { interval.contains($0.date) && $0.kind == kind }.count
    }
}
