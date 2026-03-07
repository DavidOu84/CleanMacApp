import Foundation

public protocol ScanUseCase: Sendable {
    func start(scope: ScanScope) async throws -> ScanSessionID
    func cancel(sessionID: ScanSessionID) async
    func progressStream(sessionID: ScanSessionID) async -> AsyncStream<ScanProgress>
}

public protocol DashboardUseCase: Sendable {
    func fetchSession(sessionID: ScanSessionID) async throws -> ScanSessionSnapshot?
    func topDirectories(sessionID: ScanSessionID, limit: Int) async throws -> [DirectoryUsage]
}

public protocol RecommendationUseCase: Sendable {
    func build(sessionID: ScanSessionID, rules: RecommendationRules) async throws
    func list(sessionID: ScanSessionID, type: CandidateType, limit: Int) async throws -> [CleanupCandidate]
    func summary(sessionID: ScanSessionID, type: CandidateType) async throws -> CandidateSummary
}

public protocol CleanupUseCase: Sendable {
    func execute(
        sessionID: ScanSessionID,
        candidateIDs: [CandidateID],
        action: CleanupAction
    ) async throws -> CleanupSummary

    func retryFailed(jobID: CleanupJobID) async throws -> CleanupSummary
    func retryFailed(jobID: CleanupJobID, filePaths: [String]?) async throws -> CleanupSummary
}

public protocol HistoryUseCase: Sendable {
    func recentJobs(limit: Int, offset: Int, query: String?) async throws -> [CleanupJobRecord]
    func failedItems(jobID: CleanupJobID) async throws -> [FailedCleanupItem]
    func cleanupResults(jobID: CleanupJobID, query: String?) async throws -> [CleanupResultRecord]
    func exportJobReport(jobID: CleanupJobID, directory: URL?, format: ReportFormat) async throws -> URL
}

public protocol FileSystemAdapter: Sendable {
    func enumerate(at roots: [URL]) -> AsyncThrowingStream<FileMetadata, Error>
    func computeQuickHash(of path: String) async throws -> String
    func computeFullHash(of path: String) async throws -> String
    func moveToTrash(paths: [String]) async -> [String: Error]
    func fileExists(_ path: String) -> Bool
}
