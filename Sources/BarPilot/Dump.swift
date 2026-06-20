import Foundation

// ---------------------------------------------------------------------------
// Headless output path.
//
// Run the built binary with `--dump` to print the per-model summary as JSON on
// stdout — handy for scripting or regression-checking the aggregation. Optional
// `--from YYYY-MM-DD` / `--to YYYY-MM-DD`.
// ---------------------------------------------------------------------------

enum Dump {
    static func run() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let (records, status) = DataSources.loadAll()
        let defaultRange = PeriodResolver.range(kind: .thisMonth, customFrom: Date(), customTo: Date())
        let from = value("--from") ?? defaultRange.from
        let to = value("--to") ?? defaultRange.to
        let today = PeriodResolver.todayStr()

        let report = Aggregator.build(records: records, fromStr: from, toStr: to, todayStr: today)

        FileHandle.standardError.write(Data(
            "sources: VS Code found=\(status.vscodeFound) (\(status.vscodeCount)), Mac App found=\(status.macAppFound) (\(status.macAppCount))\n"
                .utf8))
        FileHandle.standardError.write(Data("range: \(from) → \(to)\n".utf8))

        let items = report.summary.map { r in
            "{\"model\":\"\(r.model)\",\"calls\":\(r.calls),\"credits\":\"\(Fmt.credits4(r.credits))\",\"cost ($)\":\"\(Fmt.cost(r.credits))\"}"
        }
        print("[" + items.joined(separator: ",") + "]")
        FileHandle.standardError.write(Data(
            "total: \(Fmt.credits4(report.totalCredits)) credits (\(Fmt.cost(report.totalCredits)))\n".utf8))
    }
}
