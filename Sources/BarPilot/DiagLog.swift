import Foundation

// ---------------------------------------------------------------------------
// DiagLog — a small, size-capped diagnostic log for support.
//
// One line per reload (duration, bytes scanned, records added) so a CPU or
// staleness complaint can be diagnosed from history rather than a lucky live
// sample. Always on: a user reporting a problem should already have the data,
// with no "enable it and reproduce" round trip.
//
// Bounded by construction: at `maxBytes` the file is rotated to `.1` (replacing
// any previous `.1`), so on-disk use never exceeds ~2x the cap.
//
// Contains counts, sizes and durations ONLY — never prompts, code, or usage
// content. Paths are written home-relative so a user can paste the log into a
// public issue without leaking their account name.
// ---------------------------------------------------------------------------

enum DiagLog {
    static let maxBytes: Int64 = 256 * 1024

    static var dir: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/BarPilot"
    }
    static var path: String { dir + "/barpilot.log" }
    static var rotatedPath: String { dir + "/barpilot.log.1" }

    /// Replace the user's home prefix with "~" so logs are safe to share.
    static func tildify(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Append one line, rotating first if the file has hit the cap.
    static func write(_ message: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64).flatMap({ $0 }),
           size >= maxBytes {
            try? fm.removeItem(atPath: rotatedPath)          // drop the older generation
            try? fm.moveItem(atPath: path, toPath: rotatedPath)
        }

        let line = "\(stamp.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The most recent `n` lines across both generations (oldest first).
    /// Historical lines from before this build recorded credit totals and the
    /// rendered menu amount; redact them on the way out so an upgraded install
    /// can't paste an old spending history into a public issue.
    static func tail(_ n: Int) -> [String] {
        func lines(_ p: String) -> [String] {
            (try? String(contentsOfFile: p, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        }
        let all = lines(rotatedPath) + lines(path)
        return all.suffix(n).map(redactLegacyFigures)
    }

    /// Strips ` · total <n> cr` and ` · menu "<amount>"` from pre-existing lines.
    static func redactLegacyFigures(_ line: String) -> String {
        var out = line
        for pattern in [#" · total [^·]*cr"#, #" · menu "[^"]*""#] {
            out = out.replacingOccurrences(
                of: pattern, with: " · [redacted]", options: .regularExpression)
        }
        return out
    }

    static func humanBytes(_ b: Int64) -> String {
        if b >= 1_073_741_824 { return String(format: "%.2f GB", Double(b) / 1_073_741_824) }
        if b >= 1_048_576     { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1024          { return String(format: "%.1f KB", Double(b) / 1024) }
        return "\(b) B"
    }
}
