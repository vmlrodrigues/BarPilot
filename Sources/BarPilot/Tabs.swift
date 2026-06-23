import SwiftUI

// ---------------------------------------------------------------------------
// Shared table styling helpers
// ---------------------------------------------------------------------------

private let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "MM/dd HH:mm"
    return f
}()

private func shortDate(_ ms: Int64) -> String {
    shortDateFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
}

private extension View {
    /// Fixed-width, right-aligned, monospaced numeric cell.
    func numCol(_ w: CGFloat) -> some View {
        self.font(.callout).monospacedDigit().frame(width: w, alignment: .trailing)
    }
    /// Header cell.
    func headCol(_ w: CGFloat?, _ align: Alignment = .trailing) -> some View {
        self.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: w, alignment: align)
    }
}

/// Reusable scaffold: sticky header, zebra-striped scrolling rows, optional footer.
private struct TableScaffold<Header: View, Row: View, Footer: View>: View {
    let count: Int
    @ViewBuilder var header: () -> Header
    @ViewBuilder var row: (Int) -> Row
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.vertical, 6).padding(.horizontal, 10)
            Divider()
            if count == 0 {
                Spacer()
                Text("No data for this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { i in
                            row(i)
                                .padding(.vertical, 5).padding(.horizontal, 10)
                                .background(i % 2 == 1 ? Color.primary.opacity(0.04) : Color.clear)
                        }
                    }
                }
            }
            Divider()
            footer()
                .font(.callout)
                .padding(.vertical, 7).padding(.horizontal, 10)
        }
    }
}

@MainActor
private func totalFooter(_ credits: Double, _ store: UsageStore) -> some View {
    HStack {
        Text("Total").fontWeight(.semibold)
        Spacer()
        Text("\(Fmt.credits(credits)) credits").monospacedDigit()
        Text(store.costString(credits: credits)).monospacedDigit().fontWeight(.semibold)
    }
}

// ---------------------------------------------------------------------------
// Summary — credits by model
// ---------------------------------------------------------------------------

struct SummaryTab: View {
    @EnvironmentObject var store: UsageStore
    let rows: [SummaryRow]
    let total: Double

    var body: some View {
        TableScaffold(count: rows.count) {
            HStack {
                Text("Model").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                Text("Calls").headCol(60)
                Text("Credits").headCol(95)
                Text("Cost").headCol(70)
            }
        } row: { i in
            let r = rows[i]
            HStack {
                Text(r.model).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.int(r.calls)).numCol(60)
                Text(Fmt.credits(r.credits)).numCol(95)
                Text(store.costString(credits: r.credits)).numCol(70)
            }
        } footer: {
            totalFooter(total, store)
        }
    }
}

// ---------------------------------------------------------------------------
// Models — credits + token breakdown by model
// ---------------------------------------------------------------------------

struct ModelsTab: View {
    @EnvironmentObject var store: UsageStore
    let rows: [ModelRow]
    let total: Double
    @State private var showingRateInfo = false

    var body: some View {
        TableScaffold(count: rows.count) {
            HStack {
                Text("Model").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                Text("Calls").headCol(40)
                Text("Credits").headCol(64)
                Text("In tok").headCol(50)
                Text("Out tok").headCol(52)
                Text("in $/Mtok").headCol(58)
                Text("out $/Mtok").headCol(60)
                HStack(spacing: 3) {
                    Text("Fit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button { showingRateInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingRateInfo) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Effective per-token cost")
                                .font(.caption.weight(.semibold))
                            Text("**in / out $/Mtok** — what you actually paid per million input and output tokens through this model, cache discounts included. Input is usually far cheaper because most of it is cache hits; output bills at the full rate.")
                                .foregroundStyle(.secondary)
                            Text("**Fit** — how well a single input + output rate explains your real credits (100% = perfect). Lower means the mix varied, typically from cache tiers this view can't separate.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding()
                        .frame(width: 300)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 54, alignment: .trailing)
            }
        } row: { i in
            let r = rows[i]
            HStack {
                Text(r.model).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.int(r.calls)).numCol(40)
                Text(Fmt.credits(r.credits)).numCol(64)
                Text(Fmt.tokens(r.inputTokens)).numCol(50)
                Text(Fmt.tokens(r.outputTokens)).numCol(52)
                Text(r.inRate.isNaN ? "—" : store.costString(credits: r.inRate * 1_000_000)).numCol(58)
                Text(r.outRate.isNaN ? "—" : store.costString(credits: r.outRate * 1_000_000)).numCol(60)
                Text(r.fit.isNaN ? "—" : String(format: "%.0f%%", r.fit * 100)).numCol(54)
            }
        } footer: {
            totalFooter(total, store)
        }
    }
}

// ---------------------------------------------------------------------------
// Daily — credits + cost per day per model, with daily subtotals
// ---------------------------------------------------------------------------

struct DailyTab: View {
    @EnvironmentObject var store: UsageStore
    let rows: [DailyRow]
    let total: Double
    @State private var sortAscending = false

    private enum DailyItem: Identifiable {
        case detail(DailyRow)
        case subtotal(day: String, calls: Int, credits: Double)
        var id: String {
            switch self {
            case .detail(let r): return r.id.uuidString
            case .subtotal(let d, _, _): return "total-\(d)"
            }
        }
    }

    private var items: [DailyItem] {
        var days: [String] = []
        var grouped: [String: [DailyRow]] = [:]
        for row in rows {
            if grouped[row.day] == nil { days.append(row.day) }
            grouped[row.day, default: []].append(row)
        }
        let sortedDays = sortAscending ? days.sorted() : days.sorted().reversed()
        var result: [DailyItem] = []
        for day in sortedDays {
            let dayRows = grouped[day] ?? []
            for row in dayRows { result.append(.detail(row)) }
            result.append(.subtotal(
                day: day,
                calls: dayRows.reduce(0) { $0 + $1.calls },
                credits: dayRows.reduce(0.0) { $0 + $1.credits }
            ))
        }
        return result
    }

    var body: some View {
        TableScaffold(count: items.count) {
            HStack {
                Button { sortAscending.toggle() } label: {
                    HStack(spacing: 2) {
                        Text("Day")
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 95, alignment: .leading)
                }
                .buttonStyle(.borderless)
                Text("Model").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                Text("Calls").headCol(55)
                Text("Credits").headCol(80)
                Text("Cost").headCol(70)
            }
        } row: { i in
            let item = items[i]
            switch item {
            case .detail(let r):
                HStack {
                    Text(r.day).font(.callout).monospacedDigit().frame(width: 95, alignment: .leading)
                    Text(r.model).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.int(r.calls)).numCol(55)
                    Text(Fmt.credits(r.credits)).numCol(80)
                    Text(store.costString(credits: r.credits)).numCol(70)
                }
            case .subtotal(let day, let calls, let credits):
                HStack {
                    Text(day).font(.callout.weight(.semibold)).monospacedDigit().frame(width: 95, alignment: .leading)
                    Text("Daily total").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.int(calls)).numCol(55).fontWeight(.semibold)
                    Text(Fmt.credits(credits)).numCol(80).fontWeight(.semibold)
                    Text(store.costString(credits: credits)).numCol(70).fontWeight(.semibold)
                }
            }
        } footer: {
            totalFooter(total, store)
        }
    }
}

// ---------------------------------------------------------------------------
// Sessions — credits per chat session
// ---------------------------------------------------------------------------

struct SessionsTab: View {
    @EnvironmentObject var store: UsageStore
    let rows: [SessionRow]
    let total: Double

    enum SortKey { case started, lastActive, calls, cost }
    @State private var sortKey: SortKey = .lastActive
    @State private var sortAscending = false

    private var sorted: [SessionRow] {
        rows.sorted {
            switch sortKey {
            case .started:    return sortAscending ? $0.startedAt    < $1.startedAt    : $0.startedAt    > $1.startedAt
            case .lastActive: return sortAscending ? $0.lastActiveAt < $1.lastActiveAt : $0.lastActiveAt > $1.lastActiveAt
            case .calls:      return sortAscending ? $0.calls        < $1.calls        : $0.calls        > $1.calls
            case .cost:       return sortAscending ? $0.credits      < $1.credits      : $0.credits      > $1.credits
            }
        }
    }

    @ViewBuilder
    private func colHeader(_ label: String, key: SortKey, width: CGFloat, align: Alignment = .leading) -> some View {
        Button {
            if sortKey == key { sortAscending.toggle() }
            else { sortKey = key; sortAscending = false }
        } label: {
            HStack(spacing: 2) {
                if align == .trailing {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .opacity(sortKey == key ? 1 : 0)
                }
                Text(label)
                if align != .trailing {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .opacity(sortKey == key ? 1 : 0)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: align)
        }
        .buttonStyle(.borderless)
    }

    var body: some View {
        TableScaffold(count: sorted.count) {
            HStack {
                Text("Session").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                colHeader("Started", key: .started, width: 88)
                colHeader("Last active", key: .lastActive, width: 88)
                colHeader("Calls", key: .calls, width: 42, align: .trailing)
                Text("Credits").headCol(78)
                colHeader("Cost", key: .cost, width: 65, align: .trailing)
            }
        } row: { i in
            let r = sorted[i]
            HStack {
                Text(Fmt.shortId(r.sessionId))
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(r.sessionId)
                Text(shortDate(r.startedAt)).font(.callout).monospacedDigit().frame(width: 88, alignment: .leading)
                Text(shortDate(r.lastActiveAt)).font(.callout).monospacedDigit().frame(width: 88, alignment: .leading)
                Text(Fmt.int(r.calls)).numCol(42)
                Text(Fmt.credits(r.credits)).numCol(78)
                Text(store.costString(credits: r.credits)).numCol(65)
            }
        } footer: {
            totalFooter(total, store)
        }
    }
}

// ---------------------------------------------------------------------------
// Top — N most expensive individual calls
// ---------------------------------------------------------------------------

struct TopTab: View {
    @EnvironmentObject var store: UsageStore
    let rows: [TopRow]
    @State private var showingOpInfo = false

    var body: some View {
        TableScaffold(count: rows.count) {
            HStack {
                Text("#").headCol(26, .leading)
                Text("When").headCol(92, .leading)
                Text("Model").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text("Op")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button { showingOpInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingOpInfo) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("**chat**").font(.caption.weight(.semibold))
                            Text("A standard Copilot Chat turn — one request and one response.")
                                .foregroundStyle(.secondary)
                            Text("**invoke\\_agent**").font(.caption.weight(.semibold))
                            Text("An agent/multi-step call — chains multiple LLM calls and is typically more expensive.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding()
                        .frame(width: 280)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 90, alignment: .leading)
                Text("Credits").headCol(78)
                Text("Cost").headCol(65)
            }
        } row: { i in
            let r = rows[i]
            HStack {
                Text("\(r.rank)").font(.callout).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                Text(shortDate(r.startedAt)).font(.callout).monospacedDigit().frame(width: 92, alignment: .leading)
                Text(r.model).font(.callout).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                Text(r.operationName).font(.callout).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading).lineLimit(1)
                    .help(r.spanId)
                Text(Fmt.credits(r.credits)).numCol(78)
                Text(store.costString(credits: r.credits)).numCol(65)
            }
        } footer: {
            HStack {
                Text("Showing top \(rows.count) calls")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
