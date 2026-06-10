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

    var body: some View {
        TableScaffold(count: rows.count) {
            HStack {
                Text("Model").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                Text("Calls").headCol(50)
                Text("Credits").headCol(90)
                Text("Input tok").headCol(95)
                Text("Output tok").headCol(95)
            }
        } row: { i in
            let r = rows[i]
            HStack {
                Text(r.model).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.int(r.calls)).numCol(50)
                Text(Fmt.credits(r.credits)).numCol(90)
                Text(Fmt.int(r.inputTokens)).numCol(95)
                Text(Fmt.int(r.outputTokens)).numCol(95)
            }
        } footer: {
            totalFooter(total, store)
        }
    }
}

// ---------------------------------------------------------------------------
// Daily — credits per day per model
// ---------------------------------------------------------------------------

struct DailyTab: View {
    @EnvironmentObject var store: UsageStore
    let rows: [DailyRow]
    let total: Double

    var body: some View {
        TableScaffold(count: rows.count) {
            HStack {
                Text("Day").headCol(95, .leading)
                Text("Model").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                Text("Calls").headCol(55)
                Text("Credits").headCol(95)
            }
        } row: { i in
            let r = rows[i]
            HStack {
                Text(r.day).font(.callout).monospacedDigit().frame(width: 95, alignment: .leading)
                Text(r.model).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.int(r.calls)).numCol(55)
                Text(Fmt.credits(r.credits)).numCol(95)
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

    var body: some View {
        TableScaffold(count: rows.count) {
            HStack {
                Text("Session").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                Text("Started").headCol(92, .leading)
                Text("Calls").headCol(42)
                Text("Credits").headCol(78)
                Text("In").headCol(70)
                Text("Out").headCol(62)
            }
        } row: { i in
            let r = rows[i]
            HStack {
                Text(Fmt.shortId(r.sessionId))
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(r.sessionId)
                Text(shortDate(r.startedAt)).font(.callout).monospacedDigit().frame(width: 92, alignment: .leading)
                Text(Fmt.int(r.calls)).numCol(42)
                Text(Fmt.credits(r.credits)).numCol(78)
                Text(Fmt.int(r.inputTokens)).numCol(70)
                Text(Fmt.int(r.outputTokens)).numCol(62)
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
    let rows: [TopRow]

    var body: some View {
        TableScaffold(count: rows.count) {
            HStack {
                Text("#").headCol(26, .leading)
                Text("When").headCol(92, .leading)
                Text("Model").headCol(108, .leading)
                Text("Op").headCol(nil, .leading).frame(maxWidth: .infinity, alignment: .leading)
                Text("Credits").headCol(78)
                Text("In").headCol(68)
                Text("Out").headCol(58)
            }
        } row: { i in
            let r = rows[i]
            HStack {
                Text("\(r.rank)").font(.callout).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                Text(shortDate(r.startedAt)).font(.callout).monospacedDigit().frame(width: 92, alignment: .leading)
                Text(r.model).font(.callout).frame(width: 108, alignment: .leading).lineLimit(1)
                Text(r.operationName).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    .help(r.spanId)
                Text(Fmt.credits(r.credits)).numCol(78)
                Text(Fmt.int(r.inputTokens)).numCol(68)
                Text(Fmt.int(r.outputTokens)).numCol(58)
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
