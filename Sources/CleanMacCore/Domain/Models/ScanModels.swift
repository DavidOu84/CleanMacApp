import Foundation

public typealias ScanSessionID = UUID

public struct ScanScope: Sendable {
    public let roots: [URL]
    public let isQuickMode: Bool

    public init(roots: [URL], isQuickMode: Bool) {
        self.roots = roots
        self.isQuickMode = isQuickMode
    }
}

public enum ScanMode: String, Sendable {
    case quick
    case custom
}

public enum ScanStatus: Sendable, Equatable {
    case idle
    case running
    case finished
    case failed(String)
    case cancelled

    public var rawValue: String {
        switch self {
        case .idle:
            return "idle"
        case .running:
            return "running"
        case .finished:
            return "finished"
        case let .failed(message):
            return "failed:\(message)"
        case .cancelled:
            return "cancelled"
        }
    }

    public static func from(storageValue: String) -> ScanStatus {
        if storageValue == "idle" {
            return .idle
        }
        if storageValue == "running" {
            return .running
        }
        if storageValue == "finished" {
            return .finished
        }
        if storageValue == "cancelled" {
            return .cancelled
        }
        if storageValue.hasPrefix("failed:") {
            let message = String(storageValue.dropFirst("failed:".count))
            return .failed(message)
        }
        return .failed("Unknown status: \(storageValue)")
    }
}

public struct ScanProgress: Sendable {
    public let sessionID: ScanSessionID
    public let scannedCount: Int
    public let totalBytes: Int64
    public let currentPath: String
    public let percent: Double?
    public let isIndeterminate: Bool

    public init(
        sessionID: ScanSessionID,
        scannedCount: Int,
        totalBytes: Int64,
        currentPath: String,
        percent: Double?,
        isIndeterminate: Bool
    ) {
        self.sessionID = sessionID
        self.scannedCount = scannedCount
        self.totalBytes = totalBytes
        self.currentPath = currentPath
        self.percent = percent
        self.isIndeterminate = isIndeterminate
    }
}

public struct ScanSessionSnapshot: Sendable {
    public let id: ScanSessionID
    public let mode: ScanMode
    public let status: ScanStatus
    public let startedAt: Date
    public let finishedAt: Date?
    public let scannedCount: Int
    public let scannedBytes: Int64
    public let errorMessage: String?

    public init(
        id: ScanSessionID,
        mode: ScanMode,
        status: ScanStatus,
        startedAt: Date,
        finishedAt: Date?,
        scannedCount: Int,
        scannedBytes: Int64,
        errorMessage: String?
    ) {
        self.id = id
        self.mode = mode
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scannedCount = scannedCount
        self.scannedBytes = scannedBytes
        self.errorMessage = errorMessage
    }
}

public struct FileFingerprint: Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let modifiedAt: Date
    public let inode: UInt64?
    public let isDirectory: Bool
    public let fileExtension: String

    public init(
        path: String,
        sizeBytes: Int64,
        modifiedAt: Date,
        inode: UInt64?,
        isDirectory: Bool,
        fileExtension: String
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.inode = inode
        self.isDirectory = isDirectory
        self.fileExtension = fileExtension
    }
}
