import Foundation

public struct DefaultHistoryUseCase: HistoryUseCase {
    private let store: ScanSessionStore

    public init(store: ScanSessionStore) {
        self.store = store
    }

    public func recentJobs(limit: Int, offset: Int, query: String?) async throws -> [CleanupJobRecord] {
        try await store.fetchRecentCleanupJobs(limit: limit, offset: offset, query: query)
    }

    public func failedItems(jobID: CleanupJobID) async throws -> [FailedCleanupItem] {
        try await store.fetchFailedCleanupItems(jobID: jobID)
    }

    public func cleanupResults(jobID: CleanupJobID, query: String?) async throws -> [CleanupResultRecord] {
        try await store.fetchCleanupResults(jobID: jobID, query: query)
    }

    public func exportJobReport(jobID: CleanupJobID, directory: URL?, format: ReportFormat) async throws -> URL {
        guard let job = try await store.fetchCleanupJobRecord(jobID: jobID) else {
            throw NSError(domain: "CleanMacApp", code: 404, userInfo: [NSLocalizedDescriptionKey: "Cleanup job not found"])
        }

        let results = try await store.fetchCleanupResults(jobID: jobID, query: nil)
        let reportContent = try renderReport(job: job, results: results, format: format)

        let outputDirectory = directory ?? defaultReportDirectory()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let fileURL = outputDirectory.appendingPathComponent(
            "cleanup-report-\(jobID.uuidString)-\(stamp).\(format.fileExtension)"
        )
        try reportContent.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func defaultReportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("CleanMacAppReports", isDirectory: true)
    }

    private func renderReport(job: CleanupJobRecord, results: [CleanupResultRecord], format: ReportFormat) throws -> String {
        switch format {
        case .markdown:
            return renderMarkdown(job: job, results: results)
        case .json:
            return try renderJSON(job: job, results: results)
        case .csv:
            return renderCSV(job: job, results: results)
        }
    }

    private func renderMarkdown(job: CleanupJobRecord, results: [CleanupResultRecord]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        var lines: [String] = []
        lines.append("# CleanMacApp Cleanup Report")
        lines.append("")
        lines.append("- Job ID: `\(job.jobID.uuidString)`")
        lines.append("- Session ID: `\(job.sessionID.uuidString)`")
        lines.append("- Action: `\(job.action.rawValue)`")
        lines.append("- Status: `\(job.status.rawValue)`")
        lines.append("- Started At: \(dateFormatter.string(from: job.startedAt))")
        if let finished = job.finishedAt {
            lines.append("- Finished At: \(dateFormatter.string(from: finished))")
        }
        lines.append("- Success Count: \(job.successCount)")
        lines.append("- Fail Count: \(job.failCount)")
        lines.append("- Reclaimed Bytes: \(job.reclaimedBytes)")
        lines.append("- Reclaimed Human: \(ByteFormatting.string(from: job.reclaimedBytes))")
        lines.append("")
        lines.append("## File Results")
        lines.append("")

        if results.isEmpty {
            lines.append("No per-file results available.")
            return lines.joined(separator: "\n")
        }

        lines.append("| Result | Size | Path | Error |")
        lines.append("|---|---:|---|---|")

        for item in results {
            let result = item.result.rawValue.uppercased()
            let size = ByteFormatting.string(from: item.estimatedBytes)
            let path = item.filePath.replacingOccurrences(of: "|", with: "\\|")
            let error = (item.errorMessage ?? "").replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(result) | \(size) | `\(path)` | \(error) |")
        }

        return lines.joined(separator: "\n")
    }

    private func renderJSON(job: CleanupJobRecord, results: [CleanupResultRecord]) throws -> String {
        let payload = ReportPayload(job: job, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "CleanMacApp", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed encoding JSON report"])
        }
        return text
    }

    private func renderCSV(job: CleanupJobRecord, results: [CleanupResultRecord]) -> String {
        var lines: [String] = []
        lines.append("job_id,session_id,action,status,started_at,finished_at,success_count,fail_count,reclaimed_bytes")
        lines.append([
            csvEscape(job.jobID.uuidString),
            csvEscape(job.sessionID.uuidString),
            csvEscape(job.action.rawValue),
            csvEscape(job.status.rawValue),
            csvEscape(isoDate(job.startedAt)),
            csvEscape(job.finishedAt.map(isoDate) ?? ""),
            "\(job.successCount)",
            "\(job.failCount)",
            "\(job.reclaimedBytes)"
        ].joined(separator: ","))
        lines.append("")
        lines.append("candidate_id,file_path,estimated_bytes,action,result,error_message,created_at")

        for item in results {
            lines.append([
                csvEscape(item.candidateID?.uuidString ?? ""),
                csvEscape(item.filePath),
                "\(item.estimatedBytes)",
                csvEscape(item.action.rawValue),
                csvEscape(item.result.rawValue),
                csvEscape(item.errorMessage ?? ""),
                csvEscape(isoDate(item.createdAt))
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private struct ReportPayload: Encodable {
    let job: ReportJobPayload
    let results: [ReportResultPayload]

    init(job: CleanupJobRecord, results: [CleanupResultRecord]) {
        self.job = ReportJobPayload(
            jobID: job.jobID.uuidString,
            sessionID: job.sessionID.uuidString,
            action: job.action.rawValue,
            status: job.status.rawValue,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            successCount: job.successCount,
            failCount: job.failCount,
            reclaimedBytes: job.reclaimedBytes
        )
        self.results = results.map {
            ReportResultPayload(
                candidateID: $0.candidateID?.uuidString,
                filePath: $0.filePath,
                estimatedBytes: $0.estimatedBytes,
                action: $0.action.rawValue,
                result: $0.result.rawValue,
                errorMessage: $0.errorMessage,
                createdAt: $0.createdAt
            )
        }
    }
}

private struct ReportJobPayload: Encodable {
    let jobID: String
    let sessionID: String
    let action: String
    let status: String
    let startedAt: Date
    let finishedAt: Date?
    let successCount: Int
    let failCount: Int
    let reclaimedBytes: Int64
}

private struct ReportResultPayload: Encodable {
    let candidateID: String?
    let filePath: String
    let estimatedBytes: Int64
    let action: String
    let result: String
    let errorMessage: String?
    let createdAt: Date
}
