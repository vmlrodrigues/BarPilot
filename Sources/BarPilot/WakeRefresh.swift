import Foundation

enum ServerUsageRefreshOutcome: Equatable {
    case refreshed
    case retryableFailure
    case notNeeded
}

enum WakeRefreshPolicy {
    static let networkSettleDelaySeconds: TimeInterval = 2
    static let networkSettleDelayNanoseconds = UInt64(
        networkSettleDelaySeconds * 1_000_000_000
    )
    static let retryDelayNanoseconds: UInt64 = 5_000_000_000

    static func hasPostWakeSample(capturedAt: Date?, wokeAt: Date) -> Bool {
        capturedAt.map { $0 >= wokeAt } ?? false
    }

    static func shouldRetry(
        outcome: ServerUsageRefreshOutcome,
        latestCapturedAt: Date?,
        wokeAt: Date
    ) -> Bool {
        guard !hasPostWakeSample(capturedAt: latestCapturedAt, wokeAt: wokeAt) else {
            return false
        }
        return outcome == .retryableFailure
    }

    static func verify() {
        var pass = 0
        var fail = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                pass += 1
            } else {
                fail += 1
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
            }
        }

        let wake = Date(timeIntervalSince1970: 1_000)
        check(
            shouldRetry(outcome: .retryableFailure, latestCapturedAt: nil, wokeAt: wake),
            "transient failure without a sample retries"
        )
        check(
            !shouldRetry(
                outcome: .retryableFailure,
                latestCapturedAt: wake,
                wokeAt: wake
            ),
            "sample captured at wake suppresses retry"
        )
        check(
            hasPostWakeSample(
                capturedAt: wake.addingTimeInterval(1),
                wokeAt: wake
            ),
            "post-wake sample is recognized"
        )
        check(
            !shouldRetry(outcome: .refreshed, latestCapturedAt: nil, wokeAt: wake),
            "successful refresh never retries"
        )
        check(
            !shouldRetry(outcome: .notNeeded, latestCapturedAt: nil, wokeAt: wake),
            "terminal or disconnected state never retries"
        )
        check(
            networkSettleDelaySeconds > 0
                && networkSettleDelayNanoseconds > 0
                && retryDelayNanoseconds > 0,
            "wake delays remain bounded and nonzero"
        )

        FileHandle.standardError.write(Data(
            "verify-wake-refresh: \(fail == 0 ? "PASS" : "FAIL") — \(pass) ok, \(fail) failed\n".utf8
        ))
        if fail > 0 { exit(1) }
    }
}
