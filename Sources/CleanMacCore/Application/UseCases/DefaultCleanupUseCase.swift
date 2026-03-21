import Foundation

public struct DefaultCleanupUseCase: CleanupUseCase {
    private let fileSystem: FileSystemAdapter
    private let store: ScanSessionStore

    public init(fileSystem: FileSystemAdapter, store: ScanSessionStore) {
        self.fileSystem = fileSystem
        self.store = store
    }

    public func execute(
        sessionID: ScanSessionID,
        candidateIDs: [CandidateID],
        action: CleanupAction
    ) async throws -> CleanupSummary {
        let uniqueIDs = Array(Set(candidateIDs))
        guard !uniqueIDs.isEmpty else {
            return CleanupSummary(jobID: UUID(), successCount: 0, failCount: 0, reclaimedBytes: 0)
        }

        let candidates = try await store.fetchCandidates(sessionID: sessionID, ids: uniqueIDs)
        return try await runCleanup(sessionID: sessionID, action: action, items: candidates.map {
            FailedCleanupItem(candidateID: $0.id, filePath: $0.filePath, estimatedBytes: $0.estimatedBytes, errorMessage: nil)
        })
    }

    public func retryFailed(jobID: CleanupJobID) async throws -> CleanupSummary {
        try await retryFailed(jobID: jobID, filePaths: nil)
    }

    public func retryFailed(jobID: CleanupJobID, filePaths: [String]?) async throws -> CleanupSummary {
        guard let job = try await store.fetchCleanupJob(jobID: jobID) else {
            throw NSError(domain: "CleanMacApp", code: 404, userInfo: [NSLocalizedDescriptionKey: "Cleanup job not found"])
        }

        var failedItems = try await store.fetchFailedCleanupItems(jobID: jobID)
        if let filePaths, !filePaths.isEmpty {
            let pathSet = Set(filePaths)
            failedItems = failedItems.filter { pathSet.contains($0.filePath) }
        }

        guard !failedItems.isEmpty else {
            return CleanupSummary(jobID: UUID(), successCount: 0, failCount: 0, reclaimedBytes: 0)
        }

        return try await runCleanup(sessionID: job.sessionID, action: job.action, items: failedItems)
    }

    private func runCleanup(
        sessionID: ScanSessionID,
        action: CleanupAction,
        items: [FailedCleanupItem]
    ) async throws -> CleanupSummary {
        let jobID = UUID()
        try await store.createCleanupJob(id: jobID, sessionID: sessionID, action: action, startedAt: Date())

        let failures: [String: Error]
        switch action {
        case .moveToTrash:
            failures = await fileSystem.moveToTrash(paths: items.map { $0.filePath })
        }

        var successCount = 0
        var failCount = 0
        var reclaimedBytes: Int64 = 0
        var cleanedPaths: [String] = []

        for item in items {
            if let error = failures[item.filePath] {
                failCount += 1
                try await store.appendCleanupResult(
                    jobID: jobID,
                    candidateID: item.candidateID,
                    filePath: item.filePath,
                    estimatedBytes: item.estimatedBytes,
                    action: action,
                    result: .failed,
                    errorMessage: error.localizedDescription
                )
            } else {
                successCount += 1
                reclaimedBytes += item.estimatedBytes
                cleanedPaths.append(item.filePath)
                try await store.appendCleanupResult(
                    jobID: jobID,
                    candidateID: item.candidateID,
                    filePath: item.filePath,
                    estimatedBytes: item.estimatedBytes,
                    action: action,
                    result: .success,
                    errorMessage: nil
                )
            }
        }

        if !cleanedPaths.isEmpty {
            // Keep in-session index consistent with actual cleanup results
            // so recommendation rebuild does not re-surface already deleted files.
            do {
                try await store.removeFiles(sessionID: sessionID, paths: cleanedPaths)
            } catch {
                // Cleanup result itself is already committed in cleanup_result/history;
                // indexing refresh failure should not invalidate file operations.
            }
        }

        let status: CleanupJobStatus
        if failCount == 0 {
            status = .finished
        } else if successCount == 0 {
            status = .failed
        } else {
            status = .partial
        }

        try await store.finishCleanupJob(
            jobID: jobID,
            status: status,
            finishedAt: Date(),
            successCount: successCount,
            failCount: failCount,
            reclaimedBytes: reclaimedBytes
        )

        return CleanupSummary(
            jobID: jobID,
            successCount: successCount,
            failCount: failCount,
            reclaimedBytes: reclaimedBytes
        )
    }
}
