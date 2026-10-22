import Charts
import KikitoriCore
import SwiftUI

/// Main window › Usage (spec §5.6). All figures are estimates from token counts × pricing.json.
struct UsageView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let ledger = model.ledger
        let cycle = ledger.cycle()
        let spent = ledger.spentThisCycle()
        let projected = ledger.projectedCycleSpend()
        let cap = model.prefs.monthlyCap
        let warnAt = cap * 0.8
        let dayIndex = (Calendar.current.dateComponents([.day], from: cycle.start, to: .now).day ?? 0) + 1
        let days = Calendar.current.dateComponents([.day], from: cycle.start, to: cycle.end).day ?? 30

        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    if spent >= cap {
                        banner("**Monthly cap reached.** Translation is paused until \(cycle.end.formatted(.dateTime.month(.abbreviated).day())). Japanese subtitles keep working.",
                               tint: .kkDanger)
                    } else if spent >= warnAt && model.prefs.warnAt80 {
                        let when = ledger.projectedDate(reaching: cap).map { " around \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
                        banner("**80 % of your monthly cap is used.** At this pace you’ll reach \(Money.format(cap))\(when), and translation will pause then.",
                               tint: .kkNote)
                    }
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(Money.format(spent)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                                Text("of \(Money.format(cap)) monthly credit used").foregroundStyle(.secondary)
                            }
                            SpendBar(spent: spent, projected: projected, warnAt: warnAt, cap: cap)
                            HStack(spacing: 14) {
                                Text("Used \(Money.format(spent))")
                                Text("Projected \(Money.format(projected))")
                                Text("Warning at \(Money.format(warnAt))")
                                Spacer()
                                Text("Cap \(Money.format(cap))")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            Divider()
                            HStack {
                                stat("Projected by \(cycle.end.formatted(.dateTime.month(.abbreviated).day()))", Money.format(projected))
                                stat("Per stream hour", Money.format(perStreamHour))
                                stat("Left this cycle", Money.format(max(cap - spent, 0)))
                            }
                        }
                    }
                    card {
                        VStack(alignment: .leading) {
                            Text("Daily spend").font(.headline)
                            Chart(ledger.daily(), id: \.day) { d in
                                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Spend", d.cost))
                                    .foregroundStyle(Color.kkAccentFill)
                                    .cornerRadius(4)
                            }
                            .chartYAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text(Money.format(d)) } } } }
                            .frame(height: 140)
                            .accessibilityLabel("Daily spend this billing cycle")
                        }
                    }
                    card {
                        VStack(alignment: .leading) {
                            Text("Recent sessions").font(.headline)
                            Table(model.sessions.prefix(20)) {
                                TableColumn("Date") { s in Text(s.start.formatted(date: .abbreviated, time: .shortened)) }
                                TableColumn("Streamer") { s in Text(s.profileName ?? s.sourceName) }
                                TableColumn("Length") { s in Text(TimeText.format(s.duration)) }
                                TableColumn("Total") { s in Text(Money.format(s.cost)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                            }
                            .frame(minHeight: 140)
                        }
                    }
                }
                VStack(spacing: 16) {
                    card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("By model").font(.headline)
                            modelRow("Live subtitles", "Claude Haiku 5.5", ledger.spent(in: cycle, kind: .live),
                                     detail: "\(tokensText(ledger.tokens(in: cycle, kind: .live))) tokens", total: spent)
                            modelRow("Explanations", "Claude Sonnet 5.5", ledger.spent(in: cycle, kind: .explain),
                                     detail: "\(ledger.count(in: cycle, kind: .explain)) explanations", total: spent)
                        }
                    }
                    BudgetForm()
                }
                .frame(width: 280)
            }
            .padding(18)
        }
        .navigationTitle("Usage")
        .navigationSubtitle("Billing cycle \(cycle.start.formatted(.dateTime.month(.abbreviated).day())) – \(cycle.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day())) · day \(dayIndex) of \(days)")
        .toolbar {
            Link(destination: URL(string: "https://console.anthropic.com")!) { Label("Open Claude Console", systemImage: "arrow.up.right.square") }
        }
    }

    var perStreamHour: Double {
        let cycle = model.ledger.cycle()
        let hours = model.sessions.filter { cycle.contains($0.start) }.reduce(0) { $0 + $1.duration } / 3600
        return hours > 0.05 ? model.ledger.spent(in: cycle, kind: .live) / hours : 0
    }

    func tokensText(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0f K", Double(n) / 1e3) : "\(n)"
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    func banner(_ text: LocalizedStringKey, tint: Color) -> some View {
        Text(text).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func modelRow(_ title: String, _ model: String, _ cost: Double, detail: String, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(Money.format(cost)).monospacedDigit().bold() }
            ProgressView(value: total > 0 ? cost / total : 0).tint(Color.kkAccentFill)
            Text("\(model) · \(Int(total > 0 ? 100 * cost / total : 0)) % · \(detail)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Used (filled) + projected (outlined) + warning marker.
struct SpendBar: View {
    let spent, projected, warnAt, cap: Double
    var body: some View {
        GeometryReader { g in
            let scale = g.size.width / max(cap, projected, 0.01)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().strokeBorder(projected > warnAt ? Color.kkNote : Color.kkAccent, style: .init(lineWidth: 1, dash: [3, 2]))
                    .frame(width: max(projected * scale, 8))
                Capsule().fill(spent >= cap ? Color.kkDanger : Color.kkAccentFill).frame(width: max(spent * scale, 4))
                Rectangle().fill(.secondary).frame(width: 2).offset(x: warnAt * scale)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("\(Int(100 * spent / max(cap, 0.01))) percent of monthly credit used, \(Int(100 * projected / max(cap, 0.01))) percent projected")
    }
}

struct BudgetForm: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var prefs = model.prefs
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Monthly cap")
                Spacer()
                TextField("Cap", value: $prefs.monthlyCap, format: .currency(code: "USD"))
                    .frame(width: 90).multilineTextAlignment(.trailing)
                    .onChange(of: prefs.monthlyCap) { _, v in prefs.monthlyCap = min(max(v, 1), 500) }
            }
            Picker("When reached", selection: $prefs.capAction) {
                ForEach(Preferences.CapAction.allCases, id: \.self) { Text($0.rawValue) }
            }
            Toggle("Warn at 80 %", isOn: $prefs.warnAt80)
            if prefs.monthlyCap > 100 {
                Text("Above $100, extra spend uses other credit on the account, if any.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Credits included with Max expire at the end of each billing cycle and don’t carry over. Spend here is estimated from token counts; the Claude Console shows the exact amount.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}
