import CleanMacCore
import Foundation

struct AppEnvironment {
    let scanUseCase: DefaultScanUseCase
    let dashboardUseCase: DefaultDashboardUseCase
    let recommendationUseCase: DefaultRecommendationUseCase
    let cleanupUseCase: DefaultCleanupUseCase
    let historyUseCase: DefaultHistoryUseCase

    static func live() throws -> AppEnvironment {
        let store = try SQLiteStore(databaseURL: makeDatabaseURL())
        let fileSystem = LocalFileSystemAdapter()

        return AppEnvironment(
            scanUseCase: DefaultScanUseCase(fileSystem: fileSystem, store: store),
            dashboardUseCase: DefaultDashboardUseCase(store: store),
            recommendationUseCase: DefaultRecommendationUseCase(fileSystem: fileSystem, store: store),
            cleanupUseCase: DefaultCleanupUseCase(fileSystem: fileSystem, store: store),
            historyUseCase: DefaultHistoryUseCase(store: store)
        )
    }

    private static func makeDatabaseURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(".cleanmacapp", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cleanmacapp.sqlite", isDirectory: false)
    }
}
