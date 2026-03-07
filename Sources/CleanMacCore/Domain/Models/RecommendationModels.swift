import Foundation

public typealias CandidateID = UUID

public enum CandidateType: String, Sendable {
    case largeFile
    case cache
    case duplicate
    case oldDownload
    case installerPackage
}

public enum RiskLevel: String, Sendable {
    case low
    case medium
    case high
}

public struct RecommendationRules: Sendable {
    public let largeFileThresholdBytes: Int64
    public let duplicateMinSizeBytes: Int64
    public let maxDuplicateBuckets: Int
    public let maxFilesPerDuplicateBucket: Int
    public let maxCandidatesPerType: Int

    public init(
        largeFileThresholdBytes: Int64,
        duplicateMinSizeBytes: Int64 = 1 * 1024 * 1024,
        maxDuplicateBuckets: Int = 300,
        maxFilesPerDuplicateBucket: Int = 200,
        maxCandidatesPerType: Int = 2000
    ) {
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.duplicateMinSizeBytes = duplicateMinSizeBytes
        self.maxDuplicateBuckets = maxDuplicateBuckets
        self.maxFilesPerDuplicateBucket = maxFilesPerDuplicateBucket
        self.maxCandidatesPerType = maxCandidatesPerType
    }

    public static let `default` = RecommendationRules(
        largeFileThresholdBytes: 500 * 1024 * 1024,
        maxCandidatesPerType: 2000
    )
}

public struct CleanupCandidate: Sendable, Identifiable {
    public let id: CandidateID
    public let sessionID: ScanSessionID
    public let filePath: String
    public let estimatedBytes: Int64
    public let type: CandidateType
    public let reason: String
    public let risk: RiskLevel
    public let selectedByDefault: Bool

    public init(
        id: CandidateID = UUID(),
        sessionID: ScanSessionID,
        filePath: String,
        estimatedBytes: Int64,
        type: CandidateType,
        reason: String,
        risk: RiskLevel,
        selectedByDefault: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.filePath = filePath
        self.estimatedBytes = estimatedBytes
        self.type = type
        self.reason = reason
        self.risk = risk
        self.selectedByDefault = selectedByDefault
    }
}

public struct IndexedFileRecord: Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let parentPath: String
    public let modifiedAt: Date
    public let accessedAt: Date?
    public let fileExtension: String

    public init(
        path: String,
        sizeBytes: Int64,
        parentPath: String,
        modifiedAt: Date,
        accessedAt: Date?,
        fileExtension: String
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.parentPath = parentPath
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
        self.fileExtension = fileExtension
    }
}

public struct DuplicateSizeBucket: Sendable {
    public let sizeBytes: Int64
    public let fileCount: Int

    public init(sizeBytes: Int64, fileCount: Int) {
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
    }
}

public struct CandidateSummary: Sendable {
    public let type: CandidateType
    public let count: Int
    public let totalBytes: Int64

    public init(type: CandidateType, count: Int, totalBytes: Int64) {
        self.type = type
        self.count = count
        self.totalBytes = totalBytes
    }
}
