import Foundation

public struct DirectoryUsage: Sendable {
    public let parentPath: String
    public let bytes: Int64
    public let fileCount: Int

    public init(parentPath: String, bytes: Int64, fileCount: Int) {
        self.parentPath = parentPath
        self.bytes = bytes
        self.fileCount = fileCount
    }
}
