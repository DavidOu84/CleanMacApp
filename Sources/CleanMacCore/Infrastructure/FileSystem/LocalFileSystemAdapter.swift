import CryptoKit
import Foundation

public struct LocalFileSystemAdapter: FileSystemAdapter {
    public init() {}

    public func enumerate(at roots: [URL]) -> AsyncThrowingStream<FileMetadata, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .utility) {
                let fileManager = FileManager()
                let keys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .contentAccessDateKey,
                    .nameKey,
                    .fileResourceIdentifierKey
                ]

                for root in roots {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        continue
                    }

                    let enumerator = fileManager.enumerator(
                        at: root,
                        includingPropertiesForKeys: keys,
                        options: [.skipsPackageDescendants],
                        errorHandler: { _, _ in true }
                    )

                    while let next = enumerator?.nextObject() as? URL {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        autoreleasepool {
                            do {
                                let values = try next.resourceValues(forKeys: Set(keys))
                                let isRegular = values.isRegularFile ?? false
                                guard isRegular else { return }

                                let fileSize = Int64(values.fileSize ?? 0)
                                let modifiedAt = values.contentModificationDate ?? .distantPast
                                let accessedAt = values.contentAccessDate

                                let path = next.path
                                let parentPath = next.deletingLastPathComponent().path

                                continuation.yield(
                                    FileMetadata(
                                        path: path,
                                        parentPath: parentPath,
                                        size: fileSize,
                                        modifiedAt: modifiedAt,
                                        accessedAt: accessedAt,
                                        isDirectory: false,
                                        fileExtension: next.pathExtension.lowercased(),
                                        inode: nil
                                    )
                                )
                            } catch {
                                return
                            }
                        }
                    }
                }

                continuation.finish()
            }
        }
    }

    public func computeQuickHash(of path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func computeFullHash(of path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func moveToTrash(paths: [String]) async -> [String: Error] {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var failures: [String: Error] = [:]

            for path in paths {
                do {
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } catch {
                    failures[path] = error
                }
            }

            return failures
        }.value
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
