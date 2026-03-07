import Foundation

public typealias CleanupJobID = UUID

public enum CleanupAction: String, Sendable {
    case moveToTrash
}

public enum CleanupJobStatus: String, Sendable {
    case running
    case finished
    case partial
    case failed
}

public enum CleanupResultStatus: String, Sendable {
    case success
    case failed
}

public enum ReportFormat: String, CaseIterable, Sendable {
    case markdown
    case json
    case csv

    public var fileExtension: String {
        switch self {
        case .markdown:
            return "md"
        case .json:
            return "json"
        case .csv:
            return "csv"
        }
    }
}

public struct CleanupSummary: Sendable {
    public let jobID: CleanupJobID
    public let successCount: Int
    public let failCount: Int
    public let reclaimedBytes: Int64

    public init(jobID: CleanupJobID, successCount: Int, failCount: Int, reclaimedBytes: Int64) {
        self.jobID = jobID
        self.successCount = successCount
        self.failCount = failCount
        self.reclaimedBytes = reclaimedBytes
    }
}

public struct CleanupJobSnapshot: Sendable {
    public let jobID: CleanupJobID
    public let sessionID: ScanSessionID
    public let action: CleanupAction
    public let status: CleanupJobStatus

    public init(jobID: CleanupJobID, sessionID: ScanSessionID, action: CleanupAction, status: CleanupJobStatus) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.action = action
        self.status = status
    }
}

public struct CleanupJobRecord: Sendable {
    public let jobID: CleanupJobID
    public let sessionID: ScanSessionID
    public let action: CleanupAction
    public let status: CleanupJobStatus
    public let startedAt: Date
    public let finishedAt: Date?
    public let successCount: Int
    public let failCount: Int
    public let reclaimedBytes: Int64

    public init(
        jobID: CleanupJobID,
        sessionID: ScanSessionID,
        action: CleanupAction,
        status: CleanupJobStatus,
        startedAt: Date,
        finishedAt: Date?,
        successCount: Int,
        failCount: Int,
        reclaimedBytes: Int64
    ) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.action = action
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.successCount = successCount
        self.failCount = failCount
        self.reclaimedBytes = reclaimedBytes
    }
}

public struct FailedCleanupItem: Sendable {
    public let candidateID: CandidateID?
    public let filePath: String
    public let estimatedBytes: Int64
    public let errorMessage: String?

    public init(candidateID: CandidateID?, filePath: String, estimatedBytes: Int64, errorMessage: String?) {
        self.candidateID = candidateID
        self.filePath = filePath
        self.estimatedBytes = estimatedBytes
        self.errorMessage = errorMessage
    }
}

public struct CleanupResultRecord: Sendable {
    public let candidateID: CandidateID?
    public let filePath: String
    public let estimatedBytes: Int64
    public let action: CleanupAction
    public let result: CleanupResultStatus
    public let errorMessage: String?
    public let createdAt: Date

    public init(
        candidateID: CandidateID?,
        filePath: String,
        estimatedBytes: Int64,
        action: CleanupAction,
        result: CleanupResultStatus,
        errorMessage: String?,
        createdAt: Date
    ) {
        self.candidateID = candidateID
        self.filePath = filePath
        self.estimatedBytes = estimatedBytes
        self.action = action
        self.result = result
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}
