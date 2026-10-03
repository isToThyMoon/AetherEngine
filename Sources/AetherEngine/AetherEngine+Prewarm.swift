import Foundation

public extension AetherEngine {

    /// The default number of source bytes a warm retains, 8 MB.
    ///
    /// A byte budget rather than a duration, because a duration would need the bitrate, and the
    /// bitrate is known only after the probe, which is the round trip the warm exists to remove.
    static var defaultPrewarmByteBudget: Int { SourcePrewarmFetcher.defaultByteBudget }

    /// Fetch the opening bytes of a source the engine is not playing, so that a later `load()` of
    /// the same URL starts without paying for them (#551).
    ///
    /// For a host whose UI knows what comes next: the next episode, the item under the cursor. A
    /// cold open is two to three sequential round trips before the first sample read on a
    /// non-fast-start MP4, and on a slow origin the first byte of the data connection is the whole
    /// perceived start time. Those are spendable in advance, and this is how a host spends them.
    ///
    /// `nonisolated` and `static`: warming needs no engine, no audio session and no layer, so a
    /// host warms while its player is still on the current item. Call it from a detached task.
    ///
    /// What it does: one ranged GET from byte zero for `byteBudget` bytes, plus a second one for
    /// the trailing object only where the head says a cold open would go looking for it (an MP4
    /// whose `moov` sits behind the media). The bytes are held in memory, keyed by the exact URL,
    /// and the first `load()` of that URL takes them. They do not survive the app, and they are not
    /// a download: this is a head start, not an offline copy.
    ///
    /// What it deliberately does not do:
    ///
    /// - **It never queues for the origin.** A warm takes a request slot only if one is free right
    ///   now, and declines when the origin is metered down to one request at a time or is pacing
    ///   the engine (#377). A prewarm that would have to wait for the playing session's uplink has
    ///   stopped helping, and the report says so.
    /// - **It does not apply to `LoadOptions.nativeRemoteHLS`.** On that route AVPlayer issues the
    ///   requests and the engine sees none of them, so there is nothing here to adopt.
    ///
    /// Cancelling the task cancels the fetch and stores nothing: a host that has moved on must not
    /// find half a source warm for a URL it left behind.
    ///
    /// - Parameters:
    ///   - url: The exact source URL a later `load()` will use. A signed URL warmed under one
    ///     signature is not adopted under another, which is the conservative reading and the only
    ///     one that cannot serve the wrong bytes.
    ///   - httpHeaders: The same headers the load will carry (`LoadOptions.httpHeaders`), for
    ///     origins that enforce Referer / User-Agent / Authorization.
    ///   - byteBudget: How many bytes to retain from the head. Defaults to
    ///     ``defaultPrewarmByteBudget``.
    /// - Returns: A ``SourcePrewarmReport`` naming what was retained, or why nothing was.
    @discardableResult
    nonisolated static func prewarm(url: URL,
                                    httpHeaders: [String: String] = [:],
                                    byteBudget: Int? = nil) async -> SourcePrewarmReport {
        await SourcePrewarmFetcher.warm(url: url,
                                        extraHeaders: httpHeaders,
                                        byteBudget: byteBudget ?? SourcePrewarmFetcher.defaultByteBudget)
    }

    /// Whether a source is warm right now, without consuming it.
    ///
    /// For a host that wants to skip re-warming an item it already warmed. The playing session's
    /// adoption is what empties it, so this answers false again after the load that used it.
    nonisolated static func isPrewarmed(url: URL) -> Bool {
        SourcePrewarmStore.shared.isWarm(for: url)
    }

    /// Filmio: `probe(url:)` answered from the bytes a prewarm already holds for this URL, with no
    /// network I/O. Leaves the warm in place for the next `load()`. Returns nil when the URL is not
    /// warm or the warmed head is not enough to open the container (an MP4 whose `moov` lies past
    /// the head and was not warmed as the tail); the host can then fall back to `probe(url:)`.
    nonisolated static func probeWarmed(url: URL) -> SourceProbe? {
        guard let warm = SourcePrewarmStore.shared.peek(for: url), warm.head.start == 0, !warm.head.isEmpty else {
            return nil
        }
        let reader = WarmedSourceReader(warm: warm)
        // No byte cap: the reader ends at the warmed spans, and a REMUX with many tracks needs more
        // than the default 8 MB to resolve every stream. Packet and time caps still apply.
        return try? probe(source: .custom(reader, formatHint: nil),
                          limits: ProbeLimits(maxInputBytes: Int64(warm.byteCount) + 1))
    }

    /// Drop every warmed source.
    ///
    /// For a host leaving the context the warms were made for (a user signing out, a server
    /// changing). Warmed bytes cost memory until they are adopted or displaced, and a host that
    /// knows they will never be adopted can say so.
    nonisolated static func discardPrewarmedSources() {
        SourcePrewarmStore.shared.clear()
    }
}


/// Filmio: a read-only view over a warmed head (and tail, when one was fetched) for `probeWarmed`.
/// Reads outside the warmed spans end the stream rather than going to the network.
private final class WarmedSourceReader: IOReader, @unchecked Sendable {
    private let head: ResidentSpan
    private let tail: ResidentSpan?
    private let size: Int64
    private var position: Int64 = 0

    init(warm: PrewarmedSource) {
        head = warm.head
        tail = warm.tail
        size = warm.contentLength
    }

    var discImageProbeEnabled: Bool { false }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size count: Int32) -> Int32 {
        guard let buffer, count > 0 else { return 0 }
        for span in [head, tail].compactMap({ $0 }) where position >= span.start && position < span.end {
            let offset = Int(position - span.start)
            let length = min(Int(count), span.data.count - offset)
            span.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.update(from: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: length)
            }
            position += Int64(length)
            return Int32(length)
        }
        return 0
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        let target: Int64
        switch whence {
        case 65536: return size // AVSEEK_SIZE
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = size + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }

    func close() {}
}
