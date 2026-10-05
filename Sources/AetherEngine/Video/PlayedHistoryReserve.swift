import Foundation

/// Filmio: the part of a session's disk budget that the forward prefetch may not take, so content the
/// viewer has already watched stays on disk and a backward seek into it is a cache hit.
///
/// Upstream lets an opt-in whole-source prefetch (#207) run until its own bytes reach the session
/// retention budget (`PrefetchDiskBudget`). The extras pruning then has nothing left for history:
/// `SegmentCache.pruneOutsideWindow` keeps the hard window first, and under a whole-source prefetch
/// that window is everything from `target - backwardWindow` to the producer's head, i.e. the whole
/// budget. On a source larger than the budget, everything more than `backwardWindow` segments
/// (~80 s) behind the playhead was evicted, and seeking back past that restarted the producer and
/// downloaded the same bytes from the origin again. The software path (`SoftwarePacketReadAhead`)
/// had the same shape: the producer parks only at the full budget, trimming consumed history to
/// make room for every new packet.
///
/// The prefetch now parks at the budget minus this reserve, which leaves the reserve to history.
/// Nothing new is written: the history is the session's own segment cache / packet spool, which
/// already lives in the temporary directory and is deleted when the session stops.
///
/// Only an opt-in whole-source prefetch is affected (`HLSVideoEngine.retentionCapRelaxed`). A
/// bounded forward window never reaches the park, and its history already gets whatever the window
/// leaves of the budget.
enum PlayedHistoryReserve {

    /// Ceiling on the reserve: 3 GiB, the same rewind allowance Filmio gives Android.
    static let maxReserveBytes = 3 << 30

    /// History the forward prefetch must leave room for: half the session budget, at most
    /// `maxReserveBytes`, so a small budget still keeps the larger half for what lies ahead.
    static func reserveBytes(sessionBudgetBytes: Int) -> Int {
        guard sessionBudgetBytes > 0 else { return 0 }
        return min(maxReserveBytes, sessionBudgetBytes / 2)
    }

    /// Disk the forward prefetch may fill before it parks. `capRelaxed` false (a bounded window)
    /// keeps the full budget, as upstream.
    static func forwardBudgetBytes(sessionBudgetBytes: Int, capRelaxed: Bool) -> Int {
        guard capRelaxed else { return sessionBudgetBytes }
        return sessionBudgetBytes - reserveBytes(sessionBudgetBytes: sessionBudgetBytes)
    }
}
