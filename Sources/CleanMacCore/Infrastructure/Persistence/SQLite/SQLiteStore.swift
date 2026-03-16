import Foundation
import SQLite3

public enum SQLiteStoreError: Error {
    case openDatabase(String)
    case prepare(String)
    case step(String)
}

public final class SQLiteStore: @unchecked Sendable, ScanSessionStore {
    private let db: OpaquePointer?
    private let databaseURL: URL
    private let lock = NSLock()
    private var lastMaintenanceAt: Date = .distantPast
    private let maintenanceInterval: TimeInterval = 5 * 60
    private let staleRunningSessionTimeout: TimeInterval = 6 * 60 * 60
    private let keepRecentSessions = 3
    private let vacuumThresholdBytes: Int64 = 1_000_000_000

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL

        let fileManager = FileManager.default
        let folder = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var connection: OpaquePointer?
        let rc = sqlite3_open(databaseURL.path, &connection)
        guard rc == SQLITE_OK, let connection else {
            throw SQLiteStoreError.openDatabase("Unable to open database at \(databaseURL.path)")
        }

        db = connection
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func createSession(id: ScanSessionID, mode: ScanMode, scope: ScanScope, startedAt: Date) async throws {
        try lockAndRun {
            let sql = """
            INSERT INTO scan_session (
                id, mode, scope_json, started_at, finished_at, status, scanned_count, scanned_bytes, error_message
            ) VALUES (?, ?, ?, ?, NULL, ?, 0, 0, NULL);
            """
            let scopeString = serializeScope(scope)
            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_text(stmt, 1, id.uuidString, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 2, mode.rawValue, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 3, scopeString, -1, transientDestructor)
                    sqlite3_bind_double(stmt, 4, startedAt.timeIntervalSince1970)
                    sqlite3_bind_text(stmt, 5, ScanStatus.running.rawValue, -1, transientDestructor)
                }
            )
        }
    }

    public func fetchMostRecentFinishedSession(mode: ScanMode, scope: ScanScope) async throws -> ScanSessionID? {
        try lockAndRun {
            let sql = """
            SELECT id
            FROM scan_session
            WHERE mode = ? AND scope_json = ? AND status = ?
            ORDER BY finished_at DESC
            LIMIT 1;
            """

            guard let statement = try prepare(sql: sql) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, mode.rawValue, -1, transientDestructor)
            sqlite3_bind_text(statement, 2, serializeScope(scope), -1, transientDestructor)
            sqlite3_bind_text(statement, 3, ScanStatus.finished.rawValue, -1, transientDestructor)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            guard let idRaw = stringValue(statement, at: 0) else {
                return nil
            }
            return UUID(uuidString: idRaw)
        }
    }

    public func cloneFileIndex(from sourceSessionID: ScanSessionID, to targetSessionID: ScanSessionID) async throws {
        try lockAndRun {
            let sql = """
            INSERT INTO file_index (
                session_id, path, parent_path, size_bytes, mtime, atime,
                file_type, inode, is_directory, ext, created_at
            )
            SELECT ?, path, parent_path, size_bytes, mtime, atime,
                   file_type, inode, is_directory, ext, created_at
            FROM file_index
            WHERE session_id = ?;
            """

            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_text(stmt, 1, targetSessionID.uuidString, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 2, sourceSessionID.uuidString, -1, transientDestructor)
                }
            )
        }
    }

    public func fetchFileFingerprints(sessionID: ScanSessionID) async throws -> [String: FileFingerprint] {
        try lockAndRun {
            let sql = """
            SELECT path, size_bytes, mtime, inode, is_directory, ext
            FROM file_index
            WHERE session_id = ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return [:]
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)

            var result: [String: FileFingerprint] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let path = stringValue(statement, at: 0) ?? ""
                let size = sqlite3_column_int64(statement, 1)
                let mtime = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let inode: UInt64?
                if sqlite3_column_type(statement, 3) == SQLITE_NULL {
                    inode = nil
                } else {
                    inode = UInt64(sqlite3_column_int64(statement, 3))
                }
                let isDirectory = sqlite3_column_int(statement, 4) == 1
                let ext = stringValue(statement, at: 5) ?? ""

                result[path] = FileFingerprint(
                    path: path,
                    sizeBytes: size,
                    modifiedAt: mtime,
                    inode: inode,
                    isDirectory: isDirectory,
                    fileExtension: ext
                )
            }

            return result
        }
    }

    public func removeFiles(sessionID: ScanSessionID, paths: [String]) async throws {
        guard !paths.isEmpty else { return }

        try lockAndRun {
            let chunkSize = 300
            var start = 0

            while start < paths.count {
                let end = min(start + chunkSize, paths.count)
                let chunk = Array(paths[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let sql = """
                DELETE FROM file_index
                WHERE session_id = ? AND path IN (\(placeholders));
                """

                try execute(
                    sql: sql,
                    binder: { stmt in
                        sqlite3_bind_text(stmt, 1, sessionID.uuidString, -1, transientDestructor)
                        for (index, path) in chunk.enumerated() {
                            sqlite3_bind_text(stmt, Int32(index + 2), path, -1, transientDestructor)
                        }
                    }
                )

                start = end
            }
        }
    }

    public func upsertFile(sessionID: ScanSessionID, metadata: FileMetadata) async throws {
        try lockAndRun {
            let sql = """
            INSERT INTO file_index (
                session_id, path, parent_path, size_bytes, mtime, atime,
                file_type, inode, is_directory, ext, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, path) DO UPDATE SET
                parent_path = excluded.parent_path,
                size_bytes = excluded.size_bytes,
                mtime = excluded.mtime,
                atime = excluded.atime,
                file_type = excluded.file_type,
                inode = excluded.inode,
                is_directory = excluded.is_directory,
                ext = excluded.ext;
            """

            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_text(stmt, 1, sessionID.uuidString, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 2, metadata.path, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 3, metadata.parentPath, -1, transientDestructor)
                    sqlite3_bind_int64(stmt, 4, metadata.size)
                    sqlite3_bind_double(stmt, 5, metadata.modifiedAt.timeIntervalSince1970)
                    if let accessedAt = metadata.accessedAt {
                        sqlite3_bind_double(stmt, 6, accessedAt.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(stmt, 6)
                    }
                    sqlite3_bind_text(stmt, 7, "file", -1, transientDestructor)
                    if let inode = metadata.inode {
                        sqlite3_bind_int64(stmt, 8, sqlite3_int64(inode))
                    } else {
                        sqlite3_bind_null(stmt, 8)
                    }
                    sqlite3_bind_int(stmt, 9, metadata.isDirectory ? 1 : 0)
                    sqlite3_bind_text(stmt, 10, metadata.fileExtension, -1, transientDestructor)
                    sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970)
                }
            )
        }
    }

    public func updateProgress(sessionID: ScanSessionID, scannedCount: Int, scannedBytes: Int64) async throws {
        try lockAndRun {
            let sql = """
            UPDATE scan_session
            SET scanned_count = ?, scanned_bytes = ?
            WHERE id = ?;
            """
            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(scannedCount))
                    sqlite3_bind_int64(stmt, 2, scannedBytes)
                    sqlite3_bind_text(stmt, 3, sessionID.uuidString, -1, transientDestructor)
                }
            )
        }
    }

    public func finishSession(
        sessionID: ScanSessionID,
        status: ScanStatus,
        finishedAt: Date,
        errorMessage: String?
    ) async throws {
        try lockAndRun {
            let sql = """
            UPDATE scan_session
            SET status = ?, finished_at = ?, error_message = ?
            WHERE id = ?;
            """
            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_text(stmt, 1, status.rawValue, -1, transientDestructor)
                    sqlite3_bind_double(stmt, 2, finishedAt.timeIntervalSince1970)
                    if let errorMessage {
                        sqlite3_bind_text(stmt, 3, errorMessage, -1, transientDestructor)
                    } else {
                        sqlite3_bind_null(stmt, 3)
                    }
                    sqlite3_bind_text(stmt, 4, sessionID.uuidString, -1, transientDestructor)
                }
            )
        }
    }

    public func fetchSession(sessionID: ScanSessionID) async throws -> ScanSessionSnapshot? {
        try lockAndRun {
            let sql = """
            SELECT mode, status, started_at, finished_at, scanned_count, scanned_bytes, error_message
            FROM scan_session
            WHERE id = ?
            LIMIT 1;
            """

            guard let statement = try prepare(sql: sql) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            if sqlite3_step(statement) != SQLITE_ROW {
                return nil
            }

            let modeRaw = stringValue(statement, at: 0) ?? ScanMode.quick.rawValue
            let statusRaw = stringValue(statement, at: 1) ?? ScanStatus.failed("Unknown").rawValue
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))

            let finishedAt: Date?
            if sqlite3_column_type(statement, 3) == SQLITE_NULL {
                finishedAt = nil
            } else {
                finishedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            }

            let scannedCount = Int(sqlite3_column_int64(statement, 4))
            let scannedBytes = sqlite3_column_int64(statement, 5)
            let errorMessage = stringValue(statement, at: 6)

            return ScanSessionSnapshot(
                id: sessionID,
                mode: ScanMode(rawValue: modeRaw) ?? .quick,
                status: ScanStatus.from(storageValue: statusRaw),
                startedAt: startedAt,
                finishedAt: finishedAt,
                scannedCount: scannedCount,
                scannedBytes: scannedBytes,
                errorMessage: errorMessage
            )
        }
    }

    public func performMaintenance() async throws {
        try lockAndRun {
            let now = Date()
            if now.timeIntervalSince(lastMaintenanceAt) < maintenanceInterval {
                return
            }
            lastMaintenanceAt = now

            try normalizeStaleRunningSessions(now: now)
            let staleSessionIDs = try fetchStaleSessionIDs(keepingMostRecent: keepRecentSessions)
            if !staleSessionIDs.isEmpty {
                try pruneSessions(sessionIDs: staleSessionIDs)
            }

            try execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")

            if !staleSessionIDs.isEmpty && databaseFileSize() >= vacuumThresholdBytes {
                try execute(sql: "VACUUM;")
            }
        }
    }

    public func topDirectories(sessionID: ScanSessionID, limit: Int) async throws -> [DirectoryUsage] {
        try lockAndRun {
            let sql = """
            SELECT parent_path, SUM(size_bytes) AS total_bytes, COUNT(*) AS file_count
            FROM file_index
            WHERE session_id = ?
            GROUP BY parent_path
            ORDER BY total_bytes DESC
            LIMIT ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var results: [DirectoryUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let parentPath = stringValue(statement, at: 0) ?? ""
                let totalBytes = sqlite3_column_int64(statement, 1)
                let fileCount = Int(sqlite3_column_int64(statement, 2))
                results.append(DirectoryUsage(parentPath: parentPath, bytes: totalBytes, fileCount: fileCount))
            }

            return results
        }
    }

    public func fetchLargeFileRecords(
        sessionID: ScanSessionID,
        minSizeBytes: Int64,
        limit: Int
    ) async throws -> [IndexedFileRecord] {
        try lockAndRun {
            let sql = """
            SELECT path, size_bytes, parent_path, mtime, atime, ext
            FROM file_index
            WHERE session_id = ? AND is_directory = 0 AND size_bytes >= ?
            ORDER BY size_bytes DESC
            LIMIT ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            sqlite3_bind_int64(statement, 2, minSizeBytes)
            sqlite3_bind_int(statement, 3, Int32(limit))

            var records: [IndexedFileRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let path = stringValue(statement, at: 0) ?? ""
                let size = sqlite3_column_int64(statement, 1)
                let parentPath = stringValue(statement, at: 2) ?? ""
                let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let accessedAt: Date?
                if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                    accessedAt = nil
                } else {
                    accessedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                }
                let ext = stringValue(statement, at: 5) ?? ""
                records.append(
                    IndexedFileRecord(
                        path: path,
                        sizeBytes: size,
                        parentPath: parentPath,
                        modifiedAt: modifiedAt,
                        accessedAt: accessedAt,
                        fileExtension: ext
                    )
                )
            }
            return records
        }
    }

    public func fetchCacheFileRecords(sessionID: ScanSessionID, limit: Int) async throws -> [IndexedFileRecord] {
        try lockAndRun {
            let sql = """
            SELECT path, size_bytes, parent_path, mtime, atime, ext
            FROM file_index
            WHERE session_id = ?
              AND is_directory = 0
              AND path LIKE '%/Library/Caches/%'
              AND size_bytes > 0
            ORDER BY size_bytes DESC
            LIMIT ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var records: [IndexedFileRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let path = stringValue(statement, at: 0) ?? ""
                let size = sqlite3_column_int64(statement, 1)
                let parentPath = stringValue(statement, at: 2) ?? ""
                let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let accessedAt: Date?
                if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                    accessedAt = nil
                } else {
                    accessedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                }
                let ext = stringValue(statement, at: 5) ?? ""
                records.append(
                    IndexedFileRecord(
                        path: path,
                        sizeBytes: size,
                        parentPath: parentPath,
                        modifiedAt: modifiedAt,
                        accessedAt: accessedAt,
                        fileExtension: ext
                    )
                )
            }
            return records
        }
    }

    public func fetchDuplicateSizeBuckets(
        sessionID: ScanSessionID,
        minSizeBytes: Int64,
        limit: Int
    ) async throws -> [DuplicateSizeBucket] {
        try lockAndRun {
            let sql = """
            SELECT size_bytes, COUNT(*) AS file_count
            FROM file_index
            WHERE session_id = ? AND is_directory = 0 AND size_bytes >= ?
            GROUP BY size_bytes
            HAVING COUNT(*) >= 2
            ORDER BY size_bytes DESC
            LIMIT ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            sqlite3_bind_int64(statement, 2, minSizeBytes)
            sqlite3_bind_int(statement, 3, Int32(limit))

            var buckets: [DuplicateSizeBucket] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                buckets.append(
                    DuplicateSizeBucket(
                        sizeBytes: sqlite3_column_int64(statement, 0),
                        fileCount: Int(sqlite3_column_int64(statement, 1))
                    )
                )
            }
            return buckets
        }
    }

    public func fetchFileRecords(
        sessionID: ScanSessionID,
        exactSizeBytes: Int64,
        limit: Int
    ) async throws -> [IndexedFileRecord] {
        try lockAndRun {
            let sql = """
            SELECT path, size_bytes, parent_path, mtime, atime, ext
            FROM file_index
            WHERE session_id = ? AND is_directory = 0 AND size_bytes = ?
            ORDER BY mtime DESC
            LIMIT ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            sqlite3_bind_int64(statement, 2, exactSizeBytes)
            sqlite3_bind_int(statement, 3, Int32(limit))

            var records: [IndexedFileRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let path = stringValue(statement, at: 0) ?? ""
                let size = sqlite3_column_int64(statement, 1)
                let parentPath = stringValue(statement, at: 2) ?? ""
                let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let accessedAt: Date?
                if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                    accessedAt = nil
                } else {
                    accessedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                }
                let ext = stringValue(statement, at: 5) ?? ""

                records.append(
                    IndexedFileRecord(
                        path: path,
                        sizeBytes: size,
                        parentPath: parentPath,
                        modifiedAt: modifiedAt,
                        accessedAt: accessedAt,
                        fileExtension: ext
                    )
                )
            }
            return records
        }
    }

    public func replaceCandidates(
        sessionID: ScanSessionID,
        type: CandidateType,
        candidates: [CleanupCandidate]
    ) async throws {
        try lockAndRun {
            try execute(sql: "BEGIN TRANSACTION;")

            do {
                try execute(
                    sql: "DELETE FROM cleanup_candidate WHERE session_id = ? AND candidate_type = ?;",
                    binder: { stmt in
                        sqlite3_bind_text(stmt, 1, sessionID.uuidString, -1, transientDestructor)
                        sqlite3_bind_text(stmt, 2, type.rawValue, -1, transientDestructor)
                    }
                )

                let insertSQL = """
                INSERT INTO cleanup_candidate (
                    id, session_id, candidate_type, file_path, estimated_bytes,
                    reason, risk_level, selected_by_default, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """

                for candidate in candidates {
                    try execute(
                        sql: insertSQL,
                        binder: { stmt in
                            sqlite3_bind_text(stmt, 1, candidate.id.uuidString, -1, transientDestructor)
                            sqlite3_bind_text(stmt, 2, candidate.sessionID.uuidString, -1, transientDestructor)
                            sqlite3_bind_text(stmt, 3, candidate.type.rawValue, -1, transientDestructor)
                            sqlite3_bind_text(stmt, 4, candidate.filePath, -1, transientDestructor)
                            sqlite3_bind_int64(stmt, 5, candidate.estimatedBytes)
                            sqlite3_bind_text(stmt, 6, candidate.reason, -1, transientDestructor)
                            sqlite3_bind_text(stmt, 7, candidate.risk.rawValue, -1, transientDestructor)
                            sqlite3_bind_int(stmt, 8, candidate.selectedByDefault ? 1 : 0)
                            sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
                        }
                    )
                }

                try execute(sql: "COMMIT;")
            } catch {
                try? execute(sql: "ROLLBACK;")
                throw error
            }
        }
    }

    public func fetchCandidates(
        sessionID: ScanSessionID,
        type: CandidateType,
        limit: Int
    ) async throws -> [CleanupCandidate] {
        try lockAndRun {
            let sql = """
            SELECT id, file_path, estimated_bytes, reason, risk_level, selected_by_default
            FROM cleanup_candidate
            WHERE session_id = ? AND candidate_type = ?
            ORDER BY estimated_bytes DESC
            LIMIT ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            sqlite3_bind_text(statement, 2, type.rawValue, -1, transientDestructor)
            sqlite3_bind_int(statement, 3, Int32(limit))

            var results: [CleanupCandidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let idRaw = stringValue(statement, at: 0) ?? UUID().uuidString
                let filePath = stringValue(statement, at: 1) ?? ""
                let estimatedBytes = sqlite3_column_int64(statement, 2)
                let reason = stringValue(statement, at: 3) ?? ""
                let riskRaw = stringValue(statement, at: 4) ?? RiskLevel.medium.rawValue
                let selectedByDefault = sqlite3_column_int(statement, 5) == 1

                results.append(
                    CleanupCandidate(
                        id: UUID(uuidString: idRaw) ?? UUID(),
                        sessionID: sessionID,
                        filePath: filePath,
                        estimatedBytes: estimatedBytes,
                        type: type,
                        reason: reason,
                        risk: RiskLevel(rawValue: riskRaw) ?? .medium,
                        selectedByDefault: selectedByDefault
                    )
                )
            }
            return results
        }
    }

    public func fetchCandidates(sessionID: ScanSessionID, ids: [CandidateID]) async throws -> [CleanupCandidate] {
        try lockAndRun {
            guard !ids.isEmpty else {
                return []
            }

            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let sql = """
            SELECT id, candidate_type, file_path, estimated_bytes, reason, risk_level, selected_by_default
            FROM cleanup_candidate
            WHERE session_id = ? AND id IN (\(placeholders));
            """

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            for (index, id) in ids.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 2), id.uuidString, -1, transientDestructor)
            }

            var results: [CleanupCandidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let idRaw = stringValue(statement, at: 0) ?? UUID().uuidString
                let typeRaw = stringValue(statement, at: 1) ?? CandidateType.cache.rawValue
                let filePath = stringValue(statement, at: 2) ?? ""
                let estimatedBytes = sqlite3_column_int64(statement, 3)
                let reason = stringValue(statement, at: 4) ?? ""
                let riskRaw = stringValue(statement, at: 5) ?? RiskLevel.medium.rawValue
                let selectedByDefault = sqlite3_column_int(statement, 6) == 1

                results.append(
                    CleanupCandidate(
                        id: UUID(uuidString: idRaw) ?? UUID(),
                        sessionID: sessionID,
                        filePath: filePath,
                        estimatedBytes: estimatedBytes,
                        type: CandidateType(rawValue: typeRaw) ?? .cache,
                        reason: reason,
                        risk: RiskLevel(rawValue: riskRaw) ?? .medium,
                        selectedByDefault: selectedByDefault
                    )
                )
            }
            return results
        }
    }

    public func fetchCandidateSummary(sessionID: ScanSessionID, type: CandidateType) async throws -> CandidateSummary {
        try lockAndRun {
            let sql = """
            SELECT COUNT(*), COALESCE(SUM(estimated_bytes), 0)
            FROM cleanup_candidate
            WHERE session_id = ? AND candidate_type = ?;
            """

            guard let statement = try prepare(sql: sql) else {
                return CandidateSummary(type: type, count: 0, totalBytes: 0)
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transientDestructor)
            sqlite3_bind_text(statement, 2, type.rawValue, -1, transientDestructor)

            if sqlite3_step(statement) != SQLITE_ROW {
                return CandidateSummary(type: type, count: 0, totalBytes: 0)
            }

            let count = Int(sqlite3_column_int64(statement, 0))
            let totalBytes = sqlite3_column_int64(statement, 1)
            return CandidateSummary(type: type, count: count, totalBytes: totalBytes)
        }
    }

    public func createCleanupJob(
        id: CleanupJobID,
        sessionID: ScanSessionID,
        action: CleanupAction,
        startedAt: Date
    ) async throws {
        try lockAndRun {
            let sql = """
            INSERT INTO cleanup_job (
                id, session_id, action, started_at, finished_at, status,
                success_count, fail_count, reclaimed_bytes
            ) VALUES (?, ?, ?, ?, NULL, ?, 0, 0, 0);
            """
            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_text(stmt, 1, id.uuidString, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 2, sessionID.uuidString, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 3, action.rawValue, -1, transientDestructor)
                    sqlite3_bind_double(stmt, 4, startedAt.timeIntervalSince1970)
                    sqlite3_bind_text(stmt, 5, CleanupJobStatus.running.rawValue, -1, transientDestructor)
                }
            )
        }
    }

    public func appendCleanupResult(
        jobID: CleanupJobID,
        candidateID: CandidateID?,
        filePath: String,
        estimatedBytes: Int64,
        action: CleanupAction,
        result: CleanupResultStatus,
        errorMessage: String?
    ) async throws {
        try lockAndRun {
            let sql = """
            INSERT INTO cleanup_result (
                job_id, candidate_id, file_path, estimated_bytes, action, result, error_message, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_text(stmt, 1, jobID.uuidString, -1, transientDestructor)
                    if let candidateID {
                        sqlite3_bind_text(stmt, 2, candidateID.uuidString, -1, transientDestructor)
                    } else {
                        sqlite3_bind_null(stmt, 2)
                    }
                    sqlite3_bind_text(stmt, 3, filePath, -1, transientDestructor)
                    sqlite3_bind_int64(stmt, 4, estimatedBytes)
                    sqlite3_bind_text(stmt, 5, action.rawValue, -1, transientDestructor)
                    sqlite3_bind_text(stmt, 6, result.rawValue, -1, transientDestructor)
                    if let errorMessage {
                        sqlite3_bind_text(stmt, 7, errorMessage, -1, transientDestructor)
                    } else {
                        sqlite3_bind_null(stmt, 7)
                    }
                    sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)
                }
            )
        }
    }

    public func finishCleanupJob(
        jobID: CleanupJobID,
        status: CleanupJobStatus,
        finishedAt: Date,
        successCount: Int,
        failCount: Int,
        reclaimedBytes: Int64
    ) async throws {
        try lockAndRun {
            let sql = """
            UPDATE cleanup_job
            SET status = ?, finished_at = ?, success_count = ?, fail_count = ?, reclaimed_bytes = ?
            WHERE id = ?;
            """
            try execute(
                sql: sql,
                binder: { stmt in
                    sqlite3_bind_text(stmt, 1, status.rawValue, -1, transientDestructor)
                    sqlite3_bind_double(stmt, 2, finishedAt.timeIntervalSince1970)
                    sqlite3_bind_int64(stmt, 3, Int64(successCount))
                    sqlite3_bind_int64(stmt, 4, Int64(failCount))
                    sqlite3_bind_int64(stmt, 5, reclaimedBytes)
                    sqlite3_bind_text(stmt, 6, jobID.uuidString, -1, transientDestructor)
                }
            )
        }
    }

    public func fetchCleanupJob(jobID: CleanupJobID) async throws -> CleanupJobSnapshot? {
        try lockAndRun {
            let sql = """
            SELECT session_id, action, status
            FROM cleanup_job
            WHERE id = ?
            LIMIT 1;
            """
            guard let statement = try prepare(sql: sql) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, jobID.uuidString, -1, transientDestructor)
            if sqlite3_step(statement) != SQLITE_ROW {
                return nil
            }

            let sessionIDRaw = stringValue(statement, at: 0) ?? ""
            let actionRaw = stringValue(statement, at: 1) ?? CleanupAction.moveToTrash.rawValue
            let statusRaw = stringValue(statement, at: 2) ?? CleanupJobStatus.failed.rawValue

            guard let sessionID = UUID(uuidString: sessionIDRaw) else {
                return nil
            }

            return CleanupJobSnapshot(
                jobID: jobID,
                sessionID: sessionID,
                action: CleanupAction(rawValue: actionRaw) ?? .moveToTrash,
                status: CleanupJobStatus(rawValue: statusRaw) ?? .failed
            )
        }
    }

    public func fetchCleanupJobRecord(jobID: CleanupJobID) async throws -> CleanupJobRecord? {
        try lockAndRun {
            let sql = """
            SELECT id, session_id, action, status, started_at, finished_at, success_count, fail_count, reclaimed_bytes
            FROM cleanup_job
            WHERE id = ?
            LIMIT 1;
            """
            guard let statement = try prepare(sql: sql) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, jobID.uuidString, -1, transientDestructor)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            let jobIDRaw = stringValue(statement, at: 0) ?? ""
            let sessionIDRaw = stringValue(statement, at: 1) ?? ""
            guard
                let parsedJobID = UUID(uuidString: jobIDRaw),
                let sessionID = UUID(uuidString: sessionIDRaw)
            else {
                return nil
            }

            let actionRaw = stringValue(statement, at: 2) ?? CleanupAction.moveToTrash.rawValue
            let statusRaw = stringValue(statement, at: 3) ?? CleanupJobStatus.failed.rawValue
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let finishedAt: Date?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                finishedAt = nil
            } else {
                finishedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            }
            let successCount = Int(sqlite3_column_int64(statement, 6))
            let failCount = Int(sqlite3_column_int64(statement, 7))
            let reclaimedBytes = sqlite3_column_int64(statement, 8)

            return CleanupJobRecord(
                jobID: parsedJobID,
                sessionID: sessionID,
                action: CleanupAction(rawValue: actionRaw) ?? .moveToTrash,
                status: CleanupJobStatus(rawValue: statusRaw) ?? .failed,
                startedAt: startedAt,
                finishedAt: finishedAt,
                successCount: successCount,
                failCount: failCount,
                reclaimedBytes: reclaimedBytes
            )
        }
    }

    public func fetchFailedCleanupItems(jobID: CleanupJobID) async throws -> [FailedCleanupItem] {
        try lockAndRun {
            let sql = """
            SELECT candidate_id, file_path, estimated_bytes, error_message
            FROM cleanup_result
            WHERE job_id = ? AND result = ?
            ORDER BY rowid ASC;
            """
            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, jobID.uuidString, -1, transientDestructor)
            sqlite3_bind_text(statement, 2, CleanupResultStatus.failed.rawValue, -1, transientDestructor)

            var results: [FailedCleanupItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let candidateIDRaw = stringValue(statement, at: 0)
                let filePath = stringValue(statement, at: 1) ?? ""
                let estimatedBytes = sqlite3_column_int64(statement, 2)
                let errorMessage = stringValue(statement, at: 3)
                results.append(
                    FailedCleanupItem(
                        candidateID: candidateIDRaw.flatMap(UUID.init(uuidString:)),
                        filePath: filePath,
                        estimatedBytes: estimatedBytes,
                        errorMessage: errorMessage
                    )
                )
            }
            return results
        }
    }

    public func fetchRecentCleanupJobs(limit: Int, offset: Int, query: String?) async throws -> [CleanupJobRecord] {
        try lockAndRun {
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasQuery = !trimmed.isEmpty
            let parsed = hasQuery ? parseHistoryQuery(trimmed) : ParsedHistoryQuery()
            let weights = rankingWeights(for: parsed.rankingProfile)

            let sql: String
            var bindings: [String] = []
            var queryLimit = limit
            var queryOffset = offset

            if hasQuery {
                let compiledRegex = compileRegexQuery(from: parsed)
                let idTerms = mergeTerms(parsed.jobID, fallback: parsed.free)
                let sessionTerms = mergeTerms(parsed.sessionID, fallback: parsed.free)
                let actionTerms = mergeTerms(parsed.action, fallback: parsed.free)
                let statusTerms = mergeTerms(parsed.status, fallback: parsed.free)
                let pathTerms = mergeTerms(parsed.path, fallback: parsed.free)
                let errorTerms = mergeTerms(parsed.error, fallback: parsed.free)
                let ftsTerms = mergeTerms(parsed.path + parsed.error, fallback: parsed.free)

                var scoreClauses: [String] = []

                for term in idTerms {
                    if !term.isFuzzy {
                        scoreClauses.append("CASE WHEN lower(j.id) = ? THEN \(weights.jobIDExact) ELSE 0 END")
                        bindings.append(term.value)
                    }
                    scoreClauses.append("CASE WHEN lower(j.id) LIKE ? THEN \(weights.jobIDLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                for term in sessionTerms {
                    scoreClauses.append("CASE WHEN lower(j.session_id) LIKE ? THEN \(weights.sessionLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                for term in actionTerms {
                    if !term.isFuzzy {
                        scoreClauses.append("CASE WHEN lower(j.action) = ? THEN \(weights.actionExact) ELSE 0 END")
                        bindings.append(term.value)
                    }
                    scoreClauses.append("CASE WHEN lower(j.action) LIKE ? THEN \(weights.actionLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                for term in statusTerms {
                    if !term.isFuzzy {
                        scoreClauses.append("CASE WHEN lower(j.status) = ? THEN \(weights.statusExact) ELSE 0 END")
                        bindings.append(term.value)
                    }
                    scoreClauses.append("CASE WHEN lower(j.status) LIKE ? THEN \(weights.statusLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                for term in pathTerms {
                    scoreClauses.append(
                        """
                        CASE WHEN EXISTS (
                            SELECT 1
                            FROM cleanup_result r
                            WHERE r.job_id = j.id
                              AND lower(r.file_path) LIKE ?
                        ) THEN \(weights.pathLike) ELSE 0 END
                        """
                    )
                    bindings.append(buildLikePattern(for: term))
                }

                for term in errorTerms {
                    scoreClauses.append(
                        """
                        CASE WHEN EXISTS (
                            SELECT 1
                            FROM cleanup_result r
                            WHERE r.job_id = j.id
                              AND lower(COALESCE(r.error_message, '')) LIKE ?
                        ) THEN \(weights.errorLike) ELSE 0 END
                        """
                    )
                    bindings.append(buildLikePattern(for: term))
                }

                if let ftsMatch = ftsQuery(from: ftsTerms) {
                    scoreClauses.append(
                        """
                        CASE WHEN EXISTS (
                            SELECT 1
                            FROM cleanup_result_fts f
                            WHERE f.job_id = j.id
                              AND f.cleanup_result_fts MATCH ?
                        ) THEN \(weights.ftsHit) ELSE 0 END
                        """
                    )
                    bindings.append(ftsMatch)
                }

                let baseScoreExpression = scoreClauses.isEmpty ? "1" : scoreClauses.joined(separator: " + ")
                sql = """
                WITH scored AS (
                    SELECT
                        j.id,
                        j.session_id,
                        j.action,
                        j.status,
                        j.started_at,
                        j.finished_at,
                        j.success_count,
                        j.fail_count,
                        j.reclaimed_bytes,
                        (\(baseScoreExpression)) AS base_score,
                        CASE
                            WHEN (strftime('%s', 'now') - CAST(j.started_at AS INTEGER)) <= 86400 THEN \(weights.jobRecency1d)
                            WHEN (strftime('%s', 'now') - CAST(j.started_at AS INTEGER)) <= 604800 THEN \(weights.jobRecency7d)
                            WHEN (strftime('%s', 'now') - CAST(j.started_at AS INTEGER)) <= 2592000 THEN \(weights.jobRecency30d)
                            ELSE 0
                        END AS recency_score
                    FROM cleanup_job j
                )
                SELECT id, session_id, action, status, started_at, finished_at, success_count, fail_count, reclaimed_bytes
                FROM scored
                WHERE base_score > 0
                ORDER BY (base_score + recency_score) DESC, started_at DESC
                LIMIT ? OFFSET ?;
                """

                // For regex query, fetch a larger window first and filter in-memory.
                if compiledRegex.hasAny {
                    queryLimit = max(limit + offset, 200)
                    queryOffset = 0
                }
            } else {
                sql = """
                SELECT id, session_id, action, status, started_at, finished_at, success_count, fail_count, reclaimed_bytes
                FROM cleanup_job
                ORDER BY started_at DESC
                LIMIT ? OFFSET ?;
                """
            }

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var bindIndex: Int32 = 1
            if hasQuery {
                for value in bindings {
                    sqlite3_bind_text(statement, bindIndex, value, -1, transientDestructor)
                    bindIndex += 1
                }
            }

            sqlite3_bind_int(statement, bindIndex, Int32(queryLimit))
            bindIndex += 1
            sqlite3_bind_int(statement, bindIndex, Int32(queryOffset))
            bindIndex += 1

            var results: [CleanupJobRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let jobIDRaw = stringValue(statement, at: 0) ?? ""
                let sessionIDRaw = stringValue(statement, at: 1) ?? ""
                guard
                    let jobID = UUID(uuidString: jobIDRaw),
                    let sessionID = UUID(uuidString: sessionIDRaw)
                else {
                    continue
                }

                let actionRaw = stringValue(statement, at: 2) ?? CleanupAction.moveToTrash.rawValue
                let statusRaw = stringValue(statement, at: 3) ?? CleanupJobStatus.failed.rawValue
                let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                let finishedAt: Date?
                if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                    finishedAt = nil
                } else {
                    finishedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                }
                let successCount = Int(sqlite3_column_int64(statement, 6))
                let failCount = Int(sqlite3_column_int64(statement, 7))
                let reclaimedBytes = sqlite3_column_int64(statement, 8)

                results.append(
                    CleanupJobRecord(
                        jobID: jobID,
                        sessionID: sessionID,
                        action: CleanupAction(rawValue: actionRaw) ?? .moveToTrash,
                        status: CleanupJobStatus(rawValue: statusRaw) ?? .failed,
                        startedAt: startedAt,
                        finishedAt: finishedAt,
                        successCount: successCount,
                        failCount: failCount,
                        reclaimedBytes: reclaimedBytes
                    )
                )
            }
            guard hasQuery else {
                return results
            }

            let compiledRegex = compileRegexQuery(from: parsed)
            guard compiledRegex.hasAny else {
                return results
            }

            var filtered: [(CleanupJobRecord, Int)] = []
            for job in results {
                let rows = try fetchCleanupResultSearchRows(jobID: job.jobID)
                let regexScore = scoreJobRegex(job: job, rows: rows, regex: compiledRegex, weights: weights)
                if regexScore > 0 {
                    filtered.append((job, regexScore))
                }
            }

            filtered.sort { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.startedAt > rhs.0.startedAt
            }

            let start = min(offset, filtered.count)
            let end = min(start + limit, filtered.count)
            if start >= end {
                return []
            }
            return Array(filtered[start..<end].map(\.0))
        }
    }

    public func fetchCleanupResults(jobID: CleanupJobID, query: String?) async throws -> [CleanupResultRecord] {
        try lockAndRun {
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasQuery = !trimmed.isEmpty
            let parsed = hasQuery ? parseHistoryQuery(trimmed) : ParsedHistoryQuery()
            let weights = rankingWeights(for: parsed.rankingProfile)

            let sql: String
            var bindings: [String] = []

            if hasQuery {
                let resultTerms = mergeTerms(parsed.result, fallback: parsed.free)
                let actionTerms = mergeTerms(parsed.action, fallback: parsed.free)
                let pathTerms = mergeTerms(parsed.path, fallback: parsed.free)
                let errorTerms = mergeTerms(parsed.error, fallback: parsed.free)
                let ftsTerms = mergeTerms(parsed.path + parsed.error, fallback: parsed.free)

                var scoreClauses: [String] = []

                for term in resultTerms {
                    if !term.isFuzzy {
                        scoreClauses.append("CASE WHEN lower(r.result) = ? THEN \(weights.resultExact) ELSE 0 END")
                        bindings.append(term.value)
                    }
                    scoreClauses.append("CASE WHEN lower(r.result) LIKE ? THEN \(weights.resultLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                for term in actionTerms {
                    if !term.isFuzzy {
                        scoreClauses.append("CASE WHEN lower(r.action) = ? THEN \(weights.resultActionExact) ELSE 0 END")
                        bindings.append(term.value)
                    }
                    scoreClauses.append("CASE WHEN lower(r.action) LIKE ? THEN \(weights.resultActionLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                for term in pathTerms {
                    scoreClauses.append("CASE WHEN lower(r.file_path) LIKE ? THEN \(weights.resultPathLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                for term in errorTerms {
                    scoreClauses.append("CASE WHEN lower(COALESCE(r.error_message, '')) LIKE ? THEN \(weights.resultErrorLike) ELSE 0 END")
                    bindings.append(buildLikePattern(for: term))
                }

                if let ftsMatch = ftsQuery(from: ftsTerms) {
                    scoreClauses.append(
                        """
                        CASE WHEN EXISTS (
                            SELECT 1
                            FROM cleanup_result_fts f
                            WHERE f.rowid = r.id
                              AND f.cleanup_result_fts MATCH ?
                        ) THEN \(weights.resultFtsHit) ELSE 0 END
                        """
                    )
                    bindings.append(ftsMatch)
                }

                let baseScoreExpression = scoreClauses.isEmpty ? "1" : scoreClauses.joined(separator: " + ")
                sql = """
                WITH scored AS (
                    SELECT
                        r.candidate_id,
                        r.file_path,
                        r.estimated_bytes,
                        r.action,
                        r.result,
                        r.error_message,
                        r.created_at,
                        (\(baseScoreExpression)) AS base_score,
                        CASE
                            WHEN (strftime('%s', 'now') - CAST(r.created_at AS INTEGER)) <= 86400 THEN \(weights.resultRecency1d)
                            WHEN (strftime('%s', 'now') - CAST(r.created_at AS INTEGER)) <= 604800 THEN \(weights.resultRecency7d)
                            WHEN (strftime('%s', 'now') - CAST(r.created_at AS INTEGER)) <= 2592000 THEN \(weights.resultRecency30d)
                            ELSE 0
                        END AS recency_score
                    FROM cleanup_result r
                    WHERE r.job_id = ?
                )
                SELECT candidate_id, file_path, estimated_bytes, action, result, error_message, created_at
                FROM scored
                WHERE base_score > 0
                ORDER BY (base_score + recency_score) DESC, created_at DESC, file_path ASC;
                """
            } else {
                sql = """
                SELECT candidate_id, file_path, estimated_bytes, action, result, error_message, created_at
                FROM cleanup_result
                WHERE job_id = ?
                ORDER BY id ASC;
                """
            }

            guard let statement = try prepare(sql: sql) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var bindIndex: Int32 = 1
            if hasQuery {
                for value in bindings {
                    sqlite3_bind_text(statement, bindIndex, value, -1, transientDestructor)
                    bindIndex += 1
                }
            }
            sqlite3_bind_text(statement, bindIndex, jobID.uuidString, -1, transientDestructor)
            bindIndex += 1

            var results: [CleanupResultRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let candidateIDRaw = stringValue(statement, at: 0)
                let filePath = stringValue(statement, at: 1) ?? ""
                let estimatedBytes = sqlite3_column_int64(statement, 2)
                let actionRaw = stringValue(statement, at: 3) ?? CleanupAction.moveToTrash.rawValue
                let resultRaw = stringValue(statement, at: 4) ?? CleanupResultStatus.failed.rawValue
                let errorMessage = stringValue(statement, at: 5)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))

                results.append(
                    CleanupResultRecord(
                        candidateID: candidateIDRaw.flatMap(UUID.init(uuidString:)),
                        filePath: filePath,
                        estimatedBytes: estimatedBytes,
                        action: CleanupAction(rawValue: actionRaw) ?? .moveToTrash,
                        result: CleanupResultStatus(rawValue: resultRaw) ?? .failed,
                        errorMessage: errorMessage,
                        createdAt: createdAt
                    )
                )
            }
            guard hasQuery else {
                return results
            }

            let compiledRegex = compileRegexQuery(from: parsed)
            guard compiledRegex.hasAny else {
                return results
            }

            var filtered: [(CleanupResultRecord, Int)] = []
            for item in results {
                let score = scoreResultRegex(result: item, regex: compiledRegex, weights: weights)
                if score > 0 {
                    filtered.append((item, score))
                }
            }

            filtered.sort { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                if lhs.0.createdAt != rhs.0.createdAt {
                    return lhs.0.createdAt > rhs.0.createdAt
                }
                return lhs.0.filePath < rhs.0.filePath
            }

            return filtered.map(\.0)
        }
    }

    private func migrate() throws {
        lock.lock()
        defer { lock.unlock() }

        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS scan_session (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            scope_json TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL,
            scanned_count INTEGER NOT NULL DEFAULT 0,
            scanned_bytes INTEGER NOT NULL DEFAULT 0,
            error_message TEXT
        );
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS file_index (
            session_id TEXT NOT NULL,
            path TEXT NOT NULL,
            parent_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            mtime REAL NOT NULL,
            atime REAL,
            file_type TEXT NOT NULL,
            inode INTEGER,
            is_directory INTEGER NOT NULL,
            ext TEXT NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (session_id, path),
            FOREIGN KEY (session_id) REFERENCES scan_session(id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_file_index_session_parent
        ON file_index(session_id, parent_path);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_file_index_session_size
        ON file_index(session_id, size_bytes);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS cleanup_candidate (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            candidate_type TEXT NOT NULL,
            file_path TEXT NOT NULL,
            estimated_bytes INTEGER NOT NULL,
            reason TEXT NOT NULL,
            risk_level TEXT NOT NULL,
            selected_by_default INTEGER NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY (session_id) REFERENCES scan_session(id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_cleanup_candidate_session_type
        ON cleanup_candidate(session_id, candidate_type);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_cleanup_candidate_session_size
        ON cleanup_candidate(session_id, estimated_bytes DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS cleanup_job (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            action TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL,
            success_count INTEGER NOT NULL,
            fail_count INTEGER NOT NULL,
            reclaimed_bytes INTEGER NOT NULL,
            FOREIGN KEY (session_id) REFERENCES scan_session(id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_cleanup_job_session
        ON cleanup_job(session_id, started_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS cleanup_result (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL,
            candidate_id TEXT,
            file_path TEXT NOT NULL,
            estimated_bytes INTEGER NOT NULL,
            action TEXT NOT NULL,
            result TEXT NOT NULL,
            error_message TEXT,
            created_at REAL NOT NULL,
            FOREIGN KEY (job_id) REFERENCES cleanup_job(id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_cleanup_result_job
        ON cleanup_result(job_id);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_cleanup_result_job_result
        ON cleanup_result(job_id, result);
        """)

        try execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS cleanup_result_fts
        USING fts5(job_id, file_path, error_message, tokenize='unicode61');
        """)

        try execute(sql: """
        CREATE TRIGGER IF NOT EXISTS cleanup_result_ai
        AFTER INSERT ON cleanup_result
        BEGIN
            INSERT INTO cleanup_result_fts(rowid, job_id, file_path, error_message)
            VALUES (new.id, new.job_id, new.file_path, COALESCE(new.error_message, ''));
        END;
        """)

        try execute(sql: """
        CREATE TRIGGER IF NOT EXISTS cleanup_result_ad
        AFTER DELETE ON cleanup_result
        BEGIN
            DELETE FROM cleanup_result_fts WHERE rowid = old.id;
        END;
        """)

        try execute(sql: """
        CREATE TRIGGER IF NOT EXISTS cleanup_result_au
        AFTER UPDATE ON cleanup_result
        BEGIN
            DELETE FROM cleanup_result_fts WHERE rowid = old.id;
            INSERT INTO cleanup_result_fts(rowid, job_id, file_path, error_message)
            VALUES (new.id, new.job_id, new.file_path, COALESCE(new.error_message, ''));
        END;
        """)

        try execute(sql: """
        DELETE FROM cleanup_result_fts
        WHERE rowid NOT IN (SELECT id FROM cleanup_result);
        """)

        try execute(sql: """
        INSERT INTO cleanup_result_fts(rowid, job_id, file_path, error_message)
        SELECT r.id, r.job_id, r.file_path, COALESCE(r.error_message, '')
        FROM cleanup_result r
        WHERE r.id NOT IN (SELECT rowid FROM cleanup_result_fts);
        """)
    }

    private func lockAndRun<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func fetchStaleSessionIDs(keepingMostRecent keepCount: Int) throws -> [String] {
        let sql = """
        SELECT id
        FROM scan_session
        WHERE status <> ?
        ORDER BY started_at DESC
        LIMIT -1 OFFSET ?;
        """

        guard let statement = try prepare(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ScanStatus.running.rawValue, -1, transientDestructor)
        sqlite3_bind_int(statement, 2, Int32(max(0, keepCount)))

        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = stringValue(statement, at: 0), !id.isEmpty {
                ids.append(id)
            }
        }

        return ids
    }

    private func normalizeStaleRunningSessions(now: Date) throws {
        let cutoff = now.addingTimeInterval(-staleRunningSessionTimeout).timeIntervalSince1970
        try execute(
            sql: """
            UPDATE scan_session
            SET status = ?, finished_at = ?, error_message = ?
            WHERE status = ? AND started_at < ?;
            """,
            binder: { stmt in
                sqlite3_bind_text(stmt, 1, "failed:interrupted", -1, transientDestructor)
                sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, "Scan interrupted unexpectedly; auto-closed by maintenance.", -1, transientDestructor)
                sqlite3_bind_text(stmt, 4, ScanStatus.running.rawValue, -1, transientDestructor)
                sqlite3_bind_double(stmt, 5, cutoff)
            }
        )
    }

    private func pruneSessions(sessionIDs: [String]) throws {
        guard !sessionIDs.isEmpty else { return }

        let chunkSize = 200
        var start = 0

        while start < sessionIDs.count {
            let end = min(start + chunkSize, sessionIDs.count)
            let chunk = Array(sessionIDs[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")

            try execute(
                sql: """
                DELETE FROM cleanup_result
                WHERE job_id IN (
                    SELECT id FROM cleanup_job WHERE session_id IN (\(placeholders))
                );
                """,
                binder: { stmt in
                    for (index, id) in chunk.enumerated() {
                        sqlite3_bind_text(stmt, Int32(index + 1), id, -1, transientDestructor)
                    }
                }
            )

            try execute(
                sql: """
                DELETE FROM cleanup_job
                WHERE session_id IN (\(placeholders));
                """,
                binder: { stmt in
                    for (index, id) in chunk.enumerated() {
                        sqlite3_bind_text(stmt, Int32(index + 1), id, -1, transientDestructor)
                    }
                }
            )

            try execute(
                sql: """
                DELETE FROM cleanup_candidate
                WHERE session_id IN (\(placeholders));
                """,
                binder: { stmt in
                    for (index, id) in chunk.enumerated() {
                        sqlite3_bind_text(stmt, Int32(index + 1), id, -1, transientDestructor)
                    }
                }
            )

            try execute(
                sql: """
                DELETE FROM file_index
                WHERE session_id IN (\(placeholders));
                """,
                binder: { stmt in
                    for (index, id) in chunk.enumerated() {
                        sqlite3_bind_text(stmt, Int32(index + 1), id, -1, transientDestructor)
                    }
                }
            )

            try execute(
                sql: """
                DELETE FROM scan_session
                WHERE id IN (\(placeholders));
                """,
                binder: { stmt in
                    for (index, id) in chunk.enumerated() {
                        sqlite3_bind_text(stmt, Int32(index + 1), id, -1, transientDestructor)
                    }
                }
            )

            start = end
        }
    }

    private func databaseFileSize() -> Int64 {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
            let number = attrs[.size] as? NSNumber
        else {
            return 0
        }

        return number.int64Value
    }

    private func prepare(sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw SQLiteStoreError.prepare(lastErrorMessage())
        }
        return statement
    }

    private func execute(sql: String, binder: ((OpaquePointer?) -> Void)? = nil) throws {
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        binder?(statement)

        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteStoreError.step(lastErrorMessage())
        }
    }

    private func stringValue(_ statement: OpaquePointer?, at column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }

    private func lastErrorMessage() -> String {
        if let cMessage = sqlite3_errmsg(db) {
            return String(cString: cMessage)
        }
        return "Unknown SQLite error"
    }

    private func serializeScope(_ scope: ScanScope) -> String {
        scope.roots.map { $0.path }.joined(separator: "\n")
    }

    private struct HistorySearchTerm: Hashable {
        let value: String
        let isFuzzy: Bool
    }

    private enum HistoryRankingProfile: String {
        case balanced
        case recency
        case path
    }

    private struct HistoryRankingWeights {
        let jobIDExact: Int
        let jobIDLike: Int
        let sessionLike: Int
        let actionExact: Int
        let actionLike: Int
        let statusExact: Int
        let statusLike: Int
        let pathLike: Int
        let errorLike: Int
        let ftsHit: Int
        let jobRecency1d: Int
        let jobRecency7d: Int
        let jobRecency30d: Int

        let resultExact: Int
        let resultLike: Int
        let resultActionExact: Int
        let resultActionLike: Int
        let resultPathLike: Int
        let resultErrorLike: Int
        let resultFtsHit: Int
        let resultRecency1d: Int
        let resultRecency7d: Int
        let resultRecency30d: Int

        let regexJobID: Int
        let regexSessionID: Int
        let regexStatus: Int
        let regexAction: Int
        let regexPath: Int
        let regexError: Int
        let regexResult: Int
        let regexAnyRow: Int
        let regexAnyJob: Int

        static let balanced = HistoryRankingWeights(
            jobIDExact: 120,
            jobIDLike: 80,
            sessionLike: 70,
            actionExact: 60,
            actionLike: 35,
            statusExact: 60,
            statusLike: 35,
            pathLike: 85,
            errorLike: 55,
            ftsHit: 100,
            jobRecency1d: 18,
            jobRecency7d: 10,
            jobRecency30d: 4,
            resultExact: 50,
            resultLike: 20,
            resultActionExact: 45,
            resultActionLike: 20,
            resultPathLike: 90,
            resultErrorLike: 60,
            resultFtsHit: 100,
            resultRecency1d: 14,
            resultRecency7d: 8,
            resultRecency30d: 3,
            regexJobID: 120,
            regexSessionID: 70,
            regexStatus: 60,
            regexAction: 60,
            regexPath: 85,
            regexError: 55,
            regexResult: 35,
            regexAnyRow: 90,
            regexAnyJob: 80
        )
    }

    private struct ParsedHistoryQuery {
        var free: [HistorySearchTerm] = []
        var jobID: [HistorySearchTerm] = []
        var sessionID: [HistorySearchTerm] = []
        var status: [HistorySearchTerm] = []
        var action: [HistorySearchTerm] = []
        var path: [HistorySearchTerm] = []
        var error: [HistorySearchTerm] = []
        var result: [HistorySearchTerm] = []
        var regexAny: [String] = []
        var regexJobID: [String] = []
        var regexSessionID: [String] = []
        var regexStatus: [String] = []
        var regexAction: [String] = []
        var regexPath: [String] = []
        var regexError: [String] = []
        var regexResult: [String] = []
        var rankingProfile: HistoryRankingProfile = .balanced
        var regexCaseSensitive = false
        var regexDotMatchesNewline = false

        var hasRegex: Bool {
            !regexAny.isEmpty ||
            !regexJobID.isEmpty ||
            !regexSessionID.isEmpty ||
            !regexStatus.isEmpty ||
            !regexAction.isEmpty ||
            !regexPath.isEmpty ||
            !regexError.isEmpty ||
            !regexResult.isEmpty
        }
    }

    private struct CompiledHistoryRegexQuery {
        var any: [NSRegularExpression] = []
        var jobID: [NSRegularExpression] = []
        var sessionID: [NSRegularExpression] = []
        var status: [NSRegularExpression] = []
        var action: [NSRegularExpression] = []
        var path: [NSRegularExpression] = []
        var error: [NSRegularExpression] = []
        var result: [NSRegularExpression] = []

        var hasAny: Bool {
            !any.isEmpty ||
            !jobID.isEmpty ||
            !sessionID.isEmpty ||
            !status.isEmpty ||
            !action.isEmpty ||
            !path.isEmpty ||
            !error.isEmpty ||
            !result.isEmpty
        }
    }

    private struct CleanupResultSearchRow {
        let filePath: String
        let errorMessage: String
        let action: String
        let result: String
    }

    private func likePattern(_ query: String) -> String {
        "%\(query.lowercased())%"
    }

    private func parseHistoryQuery(_ query: String) -> ParsedHistoryQuery {
        var parsed = ParsedHistoryQuery()
        let tokens = tokenizeHistoryQuery(query)

        for token in tokens {
            guard !token.isEmpty else { continue }

            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let key = String(token[..<colon]).lowercased()
                let rawValue = String(token[token.index(after: colon)...])
                if let term = makeSearchTerm(rawValue) {
                    switch key {
                    case "id", "job":
                        parsed.jobID.append(term)
                    case "session", "sid":
                        parsed.sessionID.append(term)
                    case "status":
                        parsed.status.append(term)
                    case "action":
                        parsed.action.append(term)
                    case "path", "file":
                        parsed.path.append(term)
                    case "error", "err":
                        parsed.error.append(term)
                    case "result":
                        parsed.result.append(term)
                    case "rank", "ranking":
                        let rankRaw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        switch rankRaw {
                        case "balanced", "default":
                            parsed.rankingProfile = .balanced
                        case "recency", "recent":
                            parsed.rankingProfile = .recency
                        case "path", "path-heavy", "pathheavy":
                            parsed.rankingProfile = .path
                        default:
                            break
                        }
                    case "regex_case":
                        let mode = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        switch mode {
                        case "sensitive", "case-sensitive", "cs":
                            parsed.regexCaseSensitive = true
                        case "insensitive", "case-insensitive", "ci":
                            parsed.regexCaseSensitive = false
                        default:
                            break
                        }
                    case "regex_dotall":
                        if let enabled = parseBoolean(rawValue) {
                            parsed.regexDotMatchesNewline = enabled
                        }
                    case "re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexAny.append(regex)
                        }
                    case "id_re", "job_re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexJobID.append(regex)
                        }
                    case "session_re", "sid_re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexSessionID.append(regex)
                        }
                    case "status_re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexStatus.append(regex)
                        }
                    case "action_re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexAction.append(regex)
                        }
                    case "path_re", "file_re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexPath.append(regex)
                        }
                    case "error_re", "err_re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexError.append(regex)
                        }
                    case "result_re":
                        if let regex = makeRegexPattern(rawValue) {
                            parsed.regexResult.append(regex)
                        }
                    default:
                        if let fallback = makeSearchTerm(token) {
                            parsed.free.append(fallback)
                        }
                    }
                    continue
                }
            }

            if token.count >= 2 && token.hasPrefix("/") && token.hasSuffix("/") {
                let start = token.index(after: token.startIndex)
                let end = token.index(before: token.endIndex)
                let rawPattern = String(token[start..<end])
                if let regex = makeRegexPattern(rawPattern) {
                    parsed.regexAny.append(regex)
                    continue
                }
            }

            if let term = makeSearchTerm(token) {
                parsed.free.append(term)
            }
        }

        if parsed.free.isEmpty,
           parsed.jobID.isEmpty,
           parsed.sessionID.isEmpty,
           parsed.status.isEmpty,
           parsed.action.isEmpty,
           parsed.path.isEmpty,
           parsed.error.isEmpty,
           parsed.result.isEmpty,
           !parsed.hasRegex,
           let fallback = makeSearchTerm(query) {
            parsed.free = [fallback]
        }

        return parsed
    }

    private func tokenizeHistoryQuery(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?

        for char in query {
            if let quote = activeQuote {
                if char == quote {
                    activeQuote = nil
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "\"" || char == "'" {
                activeQuote = char
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func makeSearchTerm(_ raw: String) -> HistorySearchTerm? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        var fuzzy = false
        if trimmed.hasSuffix("~") {
            fuzzy = true
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !trimmed.isEmpty else { return nil }
        return HistorySearchTerm(value: trimmed, isFuzzy: fuzzy)
    }

    private func makeRegexPattern(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func mergeTerms(
        _ primary: [HistorySearchTerm],
        fallback: [HistorySearchTerm],
        limit: Int = 6
    ) -> [HistorySearchTerm] {
        var merged: [HistorySearchTerm] = []
        var seen: Set<HistorySearchTerm> = []

        for term in primary + fallback {
            if seen.contains(term) { continue }
            merged.append(term)
            seen.insert(term)
            if merged.count >= limit {
                break
            }
        }

        return merged
    }

    private func buildLikePattern(for term: HistorySearchTerm) -> String {
        if term.isFuzzy {
            let joined = term.value.map(String.init).joined(separator: "%")
            return "%\(joined)%"
        }
        return likePattern(term.value)
    }

    private func ftsQuery(from terms: [HistorySearchTerm]) -> String? {
        let plainTerms = terms
            .filter { !$0.isFuzzy }
            .map(\.value)

        guard !plainTerms.isEmpty else { return nil }
        return ftsMatchExpression(plainTerms.joined(separator: " "))
    }

    private func compileRegexQuery(from parsed: ParsedHistoryQuery) -> CompiledHistoryRegexQuery {
        var compiled = CompiledHistoryRegexQuery()
        compiled.any = compileRegexPatterns(
            parsed.regexAny,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        compiled.jobID = compileRegexPatterns(
            parsed.regexJobID,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        compiled.sessionID = compileRegexPatterns(
            parsed.regexSessionID,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        compiled.status = compileRegexPatterns(
            parsed.regexStatus,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        compiled.action = compileRegexPatterns(
            parsed.regexAction,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        compiled.path = compileRegexPatterns(
            parsed.regexPath,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        compiled.error = compileRegexPatterns(
            parsed.regexError,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        compiled.result = compileRegexPatterns(
            parsed.regexResult,
            caseSensitive: parsed.regexCaseSensitive,
            dotMatchesNewline: parsed.regexDotMatchesNewline
        )
        return compiled
    }

    private func rankingWeights(for profile: HistoryRankingProfile) -> HistoryRankingWeights {
        switch profile {
        case .balanced:
            return .balanced
        case .recency:
            let base = HistoryRankingWeights.balanced
            return HistoryRankingWeights(
                jobIDExact: base.jobIDExact,
                jobIDLike: base.jobIDLike,
                sessionLike: base.sessionLike,
                actionExact: base.actionExact,
                actionLike: base.actionLike,
                statusExact: base.statusExact,
                statusLike: base.statusLike,
                pathLike: base.pathLike,
                errorLike: base.errorLike,
                ftsHit: base.ftsHit,
                jobRecency1d: 48,
                jobRecency7d: 28,
                jobRecency30d: 10,
                resultExact: base.resultExact,
                resultLike: base.resultLike,
                resultActionExact: base.resultActionExact,
                resultActionLike: base.resultActionLike,
                resultPathLike: base.resultPathLike,
                resultErrorLike: base.resultErrorLike,
                resultFtsHit: base.resultFtsHit,
                resultRecency1d: 32,
                resultRecency7d: 18,
                resultRecency30d: 7,
                regexJobID: base.regexJobID,
                regexSessionID: base.regexSessionID,
                regexStatus: base.regexStatus,
                regexAction: base.regexAction,
                regexPath: base.regexPath,
                regexError: base.regexError,
                regexResult: base.regexResult,
                regexAnyRow: base.regexAnyRow,
                regexAnyJob: base.regexAnyJob
            )
        case .path:
            let base = HistoryRankingWeights.balanced
            return HistoryRankingWeights(
                jobIDExact: base.jobIDExact,
                jobIDLike: base.jobIDLike,
                sessionLike: base.sessionLike,
                actionExact: base.actionExact,
                actionLike: base.actionLike,
                statusExact: base.statusExact,
                statusLike: base.statusLike,
                pathLike: 120,
                errorLike: base.errorLike,
                ftsHit: 130,
                jobRecency1d: base.jobRecency1d,
                jobRecency7d: base.jobRecency7d,
                jobRecency30d: base.jobRecency30d,
                resultExact: base.resultExact,
                resultLike: base.resultLike,
                resultActionExact: base.resultActionExact,
                resultActionLike: base.resultActionLike,
                resultPathLike: 130,
                resultErrorLike: base.resultErrorLike,
                resultFtsHit: 135,
                resultRecency1d: base.resultRecency1d,
                resultRecency7d: base.resultRecency7d,
                resultRecency30d: base.resultRecency30d,
                regexJobID: base.regexJobID,
                regexSessionID: base.regexSessionID,
                regexStatus: base.regexStatus,
                regexAction: base.regexAction,
                regexPath: 120,
                regexError: base.regexError,
                regexResult: base.regexResult,
                regexAnyRow: 120,
                regexAnyJob: 100
            )
        }
    }

    private func compileRegexPatterns(
        _ patterns: [String],
        caseSensitive: Bool,
        dotMatchesNewline: Bool
    ) -> [NSRegularExpression] {
        var options: NSRegularExpression.Options = []
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }
        if dotMatchesNewline {
            options.insert(.dotMatchesLineSeparators)
        }

        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: options)
        }
    }

    private func parseBoolean(_ raw: String) -> Bool? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func regexMatchCount(_ patterns: [NSRegularExpression], text: String) -> Int {
        guard !patterns.isEmpty else { return 0 }
        let range = NSRange(location: 0, length: text.utf16.count)
        var count = 0
        for regex in patterns {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                count += 1
            }
        }
        return count
    }

    private func fetchCleanupResultSearchRows(jobID: CleanupJobID) throws -> [CleanupResultSearchRow] {
        let sql = """
        SELECT file_path, COALESCE(error_message, ''), action, result
        FROM cleanup_result
        WHERE job_id = ?;
        """
        guard let statement = try prepare(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, jobID.uuidString, -1, transientDestructor)

        var rows: [CleanupResultSearchRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                CleanupResultSearchRow(
                    filePath: stringValue(statement, at: 0) ?? "",
                    errorMessage: stringValue(statement, at: 1) ?? "",
                    action: stringValue(statement, at: 2) ?? "",
                    result: stringValue(statement, at: 3) ?? ""
                )
            )
        }
        return rows
    }

    private func scoreJobRegex(
        job: CleanupJobRecord,
        rows: [CleanupResultSearchRow],
        regex: CompiledHistoryRegexQuery,
        weights: HistoryRankingWeights
    ) -> Int {
        var score = 0

        score += regexMatchCount(regex.jobID, text: job.jobID.uuidString.lowercased()) * weights.regexJobID
        score += regexMatchCount(regex.sessionID, text: job.sessionID.uuidString.lowercased()) * weights.regexSessionID
        score += regexMatchCount(regex.status, text: job.status.rawValue.lowercased()) * weights.regexStatus
        score += regexMatchCount(regex.action, text: job.action.rawValue.lowercased()) * weights.regexAction

        var rowPathHits = 0
        var rowErrorHits = 0
        var rowActionHits = 0
        var rowResultHits = 0
        var rowAnyHits = 0
        for row in rows {
            rowPathHits += regexMatchCount(regex.path, text: row.filePath.lowercased())
            rowErrorHits += regexMatchCount(regex.error, text: row.errorMessage.lowercased())
            rowActionHits += regexMatchCount(regex.action, text: row.action.lowercased())
            rowResultHits += regexMatchCount(regex.result, text: row.result.lowercased())

            if !regex.any.isEmpty {
                let combined = "\(row.filePath) \(row.errorMessage) \(row.action) \(row.result)".lowercased()
                rowAnyHits += regexMatchCount(regex.any, text: combined)
            }
        }

        score += rowPathHits * weights.regexPath
        score += rowErrorHits * weights.regexError
        score += rowActionHits * weights.regexAction
        score += rowResultHits * weights.regexResult
        score += rowAnyHits * weights.regexAnyRow

        if !regex.any.isEmpty {
            let jobAnyText = "\(job.jobID.uuidString) \(job.sessionID.uuidString) \(job.action.rawValue) \(job.status.rawValue)".lowercased()
            score += regexMatchCount(regex.any, text: jobAnyText) * weights.regexAnyJob
        }

        return score
    }

    private func scoreResultRegex(
        result: CleanupResultRecord,
        regex: CompiledHistoryRegexQuery,
        weights: HistoryRankingWeights
    ) -> Int {
        var score = 0
        let path = result.filePath.lowercased()
        let error = (result.errorMessage ?? "").lowercased()
        let action = result.action.rawValue.lowercased()
        let status = result.result.rawValue.lowercased()

        score += regexMatchCount(regex.path, text: path) * weights.regexPath
        score += regexMatchCount(regex.error, text: error) * weights.regexError
        score += regexMatchCount(regex.action, text: action) * weights.resultActionExact
        score += regexMatchCount(regex.result, text: status) * weights.resultExact

        if !regex.any.isEmpty {
            let combined = "\(path) \(error) \(action) \(status)"
            score += regexMatchCount(regex.any, text: combined) * weights.regexAnyRow
        }

        return score
    }

    private func ftsMatchExpression(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let separators = CharacterSet.alphanumerics.inverted
        let rawChunks = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var clauses: [String] = []

        for chunk in rawChunks {
            let words = chunk
                .components(separatedBy: separators)
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }

            guard !words.isEmpty else { continue }
            let hasPunctuation = chunk.rangeOfCharacter(from: separators) != nil
            if hasPunctuation || words.count > 1 {
                clauses.append("\"\(words.joined(separator: " "))\"")
            } else {
                clauses.append("\(words[0])*")
            }
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " AND ")
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
