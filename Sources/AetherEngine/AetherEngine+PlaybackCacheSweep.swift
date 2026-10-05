import Foundation

public extension AetherEngine {

    /// Filmio: removes the on-disk playback caches (segment cache, software packet spool, DVR
    /// scratch) that no running session holds, i.e. what a process killed mid-playback left in the
    /// temporary directory.
    ///
    /// A session deletes its own cache when it stops. Upstream reclaims a killed session's only
    /// when a later session starts, and only once it is an hour (segments) or a day (packet spool)
    /// old, so a large prefetch could sit in the temporary directory until then. A host calls this
    /// once per launch, off the main thread and away from the startup path.
    ///
    /// Liveness comes from each session's `flock` marker, as in the upstream sweeps, so a session
    /// that is running (or parked for the background) is never touched. `minimumAge` only covers
    /// the instant between a session creating its directory and taking that lock.
    ///
    /// `nonisolated`: it is file-system work with no engine state; call it from a detached task.
    nonisolated static func removeAbandonedPlaybackCaches(minimumAge: TimeInterval = 30) {
        removeAbandonedPlaybackCaches(
            segmentBaseDirectory: SegmentCache.defaultBaseDirectory,
            packetParentDirectory: FileManager.default.temporaryDirectory,
            minimumAge: minimumAge, now: Date())
    }
}

extension AetherEngine {

    /// Filmio: the sweep above against explicit directories, for tests.
    nonisolated static func removeAbandonedPlaybackCaches(segmentBaseDirectory: URL,
                                                          packetParentDirectory: URL,
                                                          minimumAge: TimeInterval, now: Date) {
        SegmentCache.sweepStaleSessionDirs(baseDir: segmentBaseDirectory, currentSession: "",
                                           minimumAge: minimumAge, now: now)
        let packets = SoftwarePacketDiskFIFO.sweepStaleSessionDirs(
            parentDirectory: packetParentDirectory, now: now, minimumAge: minimumAge,
            maxEntries: 4096, maxRemovals: 256)
        if packets.removedCount > 0 || packets.failureCount > 0 {
            EngineLog.emit(
                "[AetherEngine] launch sweep: removed \(packets.removedCount) abandoned packet spool(s), "
                + "\(packets.failureCount) failure(s)",
                category: .session)
        }
    }
}
