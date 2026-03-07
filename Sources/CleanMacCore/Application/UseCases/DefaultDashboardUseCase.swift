import Foundation

public struct DefaultDashboardUseCase: DashboardUseCase {
    private let store: ScanSessionStore

    public init(store: ScanSessionStore) {
        self.store = store
    }

    public func fetchSession(sessionID: ScanSessionID) async throws -> ScanSessionSnapshot? {
        try await store.fetchSession(sessionID: sessionID)
    }

    public func topDirectories(sessionID: ScanSessionID, limit: Int) async throws -> [DirectoryUsage] {
        try await store.topDirectories(sessionID: sessionID, limit: limit)
    }
}
