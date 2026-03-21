import Foundation

public actor DefaultScanUseCase: ScanUseCase {
    nonisolated private let fileSystem: FileSystemAdapter
    nonisolated private let store: ScanSessionStore

    private var continuations: [ScanSessionID: AsyncStream<ScanProgress>.Continuation] = [:]
    private var tasks: [ScanSessionID: Task<Void, Never>] = [:]

    public init(fileSystem: FileSystemAdapter, store: ScanSessionStore) {
        self.fileSystem = fileSystem
        self.store = store
    }

    public func start(scope: ScanScope) async throws -> ScanSessionID {
        let sessionID = UUID()
        let mode: ScanMode = scope.isQuickMode ? .quick : .custom
        let startedAt = Date()
        try await store.createSession(id: sessionID, mode: mode, scope: scope, startedAt: startedAt)

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runScan(sessionID: sessionID, scope: scope)
        }
        tasks[sessionID] = task

        return sessionID
    }

    public func cancel(sessionID: ScanSessionID) async {
        tasks[sessionID]?.cancel()
    }

    public func progressStream(sessionID: ScanSessionID) async -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            registerContinuation(continuation, for: sessionID)
        }
    }

    private func registerContinuation(
        _ continuation: AsyncStream<ScanProgress>.Continuation,
        for sessionID: ScanSessionID
    ) {
        continuations[sessionID] = continuation
    }

    private func finishStream(sessionID: ScanSessionID) {
        continuations[sessionID]?.finish()
        continuations[sessionID] = nil
        tasks[sessionID] = nil
    }

    private func emit(_ progress: ScanProgress) {
        continuations[progress.sessionID]?.yield(progress)
    }

    private nonisolated func runScan(sessionID: ScanSessionID, scope: ScanScope) async {
        var scannedCount = 0
        var scannedBytes: Int64 = 0
        var lastPath = ""
        let useIncrementalBaseline = shouldUseIncrementalBaseline(scope: scope)
        var seenPaths: Set<String>? = useIncrementalBaseline ? [] : nil
        var baselineFingerprints: [String: FileFingerprint]? = nil

        defer {
            Task {
                await self.finishStream(sessionID: sessionID)
            }
        }

        do {
            if useIncrementalBaseline {
                do {
                    baselineFingerprints = try await loadBaselineIfAvailable(sessionID: sessionID, scope: scope)
                } catch {
                    baselineFingerprints = [:]
                }
            }

            try await fileSystem.enumerate(at: scope.roots) { metadata in
                if useIncrementalBaseline {
                    seenPaths?.insert(metadata.path)
                }

                let baseline = baselineFingerprints?[metadata.path]
                if shouldUpsert(metadata: metadata, baseline: baseline) {
                    try await store.upsertFile(sessionID: sessionID, metadata: metadata)
                }
                scannedCount += 1
                scannedBytes += metadata.size
                lastPath = metadata.path

                if scannedCount % 200 == 0 {
                    try await store.updateProgress(
                        sessionID: sessionID,
                        scannedCount: scannedCount,
                        scannedBytes: scannedBytes
                    )
                    await self.emit(
                        ScanProgress(
                            sessionID: sessionID,
                            scannedCount: scannedCount,
                            totalBytes: scannedBytes,
                            currentPath: lastPath,
                            percent: nil,
                            isIndeterminate: true
                        )
                    )
                }
            }

            if
                useIncrementalBaseline,
                let baselineFingerprints,
                !baselineFingerprints.isEmpty,
                let seenPaths
            {
                let removedPaths = baselineFingerprints.keys.filter { !seenPaths.contains($0) }
                if !removedPaths.isEmpty {
                    try await store.removeFiles(sessionID: sessionID, paths: removedPaths)
                }
            }

            try await store.updateProgress(sessionID: sessionID, scannedCount: scannedCount, scannedBytes: scannedBytes)
            try await store.finishSession(
                sessionID: sessionID,
                status: .finished,
                finishedAt: Date(),
                errorMessage: nil
            )
            await self.emit(
                ScanProgress(
                    sessionID: sessionID,
                    scannedCount: scannedCount,
                    totalBytes: scannedBytes,
                    currentPath: lastPath,
                    percent: 1.0,
                    isIndeterminate: false
                )
            )
            try? await store.performMaintenance()
        } catch is CancellationError {
            do {
                try await store.updateProgress(sessionID: sessionID, scannedCount: scannedCount, scannedBytes: scannedBytes)
                try await store.finishSession(
                    sessionID: sessionID,
                    status: .cancelled,
                    finishedAt: Date(),
                    errorMessage: nil
                )
            } catch {
                // Nothing else to do if persistence fails while handling scan cancellation.
            }
            try? await store.performMaintenance()
        } catch {
            do {
                try await store.updateProgress(sessionID: sessionID, scannedCount: scannedCount, scannedBytes: scannedBytes)
                try await store.finishSession(
                    sessionID: sessionID,
                    status: .failed(error.localizedDescription),
                    finishedAt: Date(),
                    errorMessage: error.localizedDescription
                )
            } catch {
                // Nothing else to do if persistence fails while handling scan failure.
            }
            try? await store.performMaintenance()
        }
    }

    private nonisolated func loadBaselineIfAvailable(
        sessionID: ScanSessionID,
        scope: ScanScope
    ) async throws -> [String: FileFingerprint] {
        let mode: ScanMode = scope.isQuickMode ? .quick : .custom

        guard let baselineSessionID = try await store.fetchMostRecentFinishedSession(mode: mode, scope: scope) else {
            return [:]
        }

        let fingerprints = try await store.fetchFileFingerprints(sessionID: baselineSessionID)
        try await store.cloneFileIndex(from: baselineSessionID, to: sessionID)
        return fingerprints
    }

    private nonisolated func shouldUseIncrementalBaseline(scope: ScanScope) -> Bool {
        // Full-disk scans can contain millions of files; loading baseline fingerprints
        // for those sessions can consume massive memory and cause OOM pressure.
        let hasRootPath = scope.roots.contains { $0.standardizedFileURL.path == "/" }
        if hasRootPath {
            return false
        }
        return true
    }

    private nonisolated func shouldUpsert(metadata: FileMetadata, baseline: FileFingerprint?) -> Bool {
        guard let baseline else {
            return true
        }

        let currentMtime = Int64(metadata.modifiedAt.timeIntervalSince1970)
        let baselineMtime = Int64(baseline.modifiedAt.timeIntervalSince1970)

        return !(
            metadata.size == baseline.sizeBytes &&
            currentMtime == baselineMtime &&
            metadata.inode == baseline.inode &&
            metadata.isDirectory == baseline.isDirectory &&
            metadata.fileExtension == baseline.fileExtension
        )
    }
}
