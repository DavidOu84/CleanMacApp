import AppKit
import Foundation

enum FullDiskAccessHelper {
    static func hasFullDiskAccess() -> Bool {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let probePaths = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/History.db",
            "\(home)/Library/Mail"
        ]

        for path in probePaths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                if (try? fileManager.contentsOfDirectory(atPath: path)) != nil {
                    return true
                }
                continue
            }

            if fileManager.isReadableFile(atPath: path) {
                return true
            }
        }

        return false
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
