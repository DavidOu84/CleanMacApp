import Foundation

public protocol ScanSessionStore: Sendable {
    func createSession(id: ScanSessionID, mode: ScanMode, scope: ScanScope, startedAt: Date) async throws
    func fetchMostRecentFinishedSession(mode: ScanMode, scope: ScanScope) async throws -> ScanSessionID?
    func cloneFileIndex(from sourceSessionID: ScanSessionID, to targetSessionID: ScanSessionID) async throws
    func fetchFileFingerprints(sessionID: ScanSessionID) async throws -> [String: FileFingerprint]
    func removeFiles(sessionID: ScanSessionID, paths: [String]) async throws
    func upsertFile(sessionID: ScanSessionID, metadata: FileMetadata) async throws
    func updateProgress(sessionID: ScanSessionID, scannedCount: Int, scannedBytes: Int64) async throws
    func finishSession(
        sessionID: ScanSessionID,
        status: ScanStatus,
        finishedAt: Date,
        errorMessage: String?
    ) async throws
    func fetchSession(sessionID: ScanSessionID) async throws -> ScanSessionSnapshot?
    func topDirectories(sessionID: ScanSessionID, limit: Int) async throws -> [DirectoryUsage]
    func fetchLargeFileRecords(sessionID: ScanSessionID, minSizeBytes: Int64, limit: Int) async throws -> [IndexedFileRecord]
    func fetchCacheFileRecords(sessionID: ScanSessionID, limit: Int) async throws -> [IndexedFileRecord]
    func fetchDuplicateSizeBuckets(
        sessionID: ScanSessionID,
        minSizeBytes: Int64,
        limit: Int
    ) async throws -> [DuplicateSizeBucket]
    func fetchFileRecords(sessionID: ScanSessionID, exactSizeBytes: Int64, limit: Int) async throws -> [IndexedFileRecord]
    func replaceCandidates(
        sessionID: ScanSessionID,
        type: CandidateType,
        candidates: [CleanupCandidate]
    ) async throws
    func fetchCandidates(sessionID: ScanSessionID, type: CandidateType, limit: Int) async throws -> [CleanupCandidate]
    func fetchCandidates(sessionID: ScanSessionID, ids: [CandidateID]) async throws -> [CleanupCandidate]
    func fetchCandidateSummary(sessionID: ScanSessionID, type: CandidateType) async throws -> CandidateSummary
    func createCleanupJob(id: CleanupJobID, sessionID: ScanSessionID, action: CleanupAction, startedAt: Date) async throws
    func appendCleanupResult(
        jobID: CleanupJobID,
        candidateID: CandidateID?,
        filePath: String,
        estimatedBytes: Int64,
        action: CleanupAction,
        result: CleanupResultStatus,
        errorMessage: String?
    ) async throws
    func finishCleanupJob(
        jobID: CleanupJobID,
        status: CleanupJobStatus,
        finishedAt: Date,
        successCount: Int,
        failCount: Int,
        reclaimedBytes: Int64
    ) async throws
    func fetchCleanupJob(jobID: CleanupJobID) async throws -> CleanupJobSnapshot?
    func fetchCleanupJobRecord(jobID: CleanupJobID) async throws -> CleanupJobRecord?
    func fetchFailedCleanupItems(jobID: CleanupJobID) async throws -> [FailedCleanupItem]
    func fetchRecentCleanupJobs(limit: Int, offset: Int, query: String?) async throws -> [CleanupJobRecord]
    func fetchCleanupResults(jobID: CleanupJobID, query: String?) async throws -> [CleanupResultRecord]
}
