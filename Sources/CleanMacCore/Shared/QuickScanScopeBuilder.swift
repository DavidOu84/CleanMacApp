import Foundation

public enum QuickScanScopeBuilder {
    public static func build(fileManager: FileManager = .default) -> ScanScope {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Library/Caches", isDirectory: true)
        ]

        let roots = candidates.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        return ScanScope(roots: roots, isQuickMode: true)
    }
}
