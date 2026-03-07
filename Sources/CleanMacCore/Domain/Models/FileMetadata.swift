import Foundation

public struct FileMetadata: Sendable {
    public let path: String
    public let parentPath: String
    public let size: Int64
    public let modifiedAt: Date
    public let accessedAt: Date?
    public let isDirectory: Bool
    public let fileExtension: String
    public let inode: UInt64?

    public init(
        path: String,
        parentPath: String,
        size: Int64,
        modifiedAt: Date,
        accessedAt: Date?,
        isDirectory: Bool,
        fileExtension: String,
        inode: UInt64?
    ) {
        self.path = path
        self.parentPath = parentPath
        self.size = size
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
        self.isDirectory = isDirectory
        self.fileExtension = fileExtension
        self.inode = inode
    }
}
