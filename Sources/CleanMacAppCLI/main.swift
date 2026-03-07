import CleanMacCore
import Foundation

private struct CLIOptions {
    let scanPaths: [String]
    let useQuickScope: Bool
    let cleanupTypes: Set<CandidateType>
    let exportJobID: CleanupJobID?
    let exportFormat: ReportFormat
    let historySearchQuery: String?
    let historySearchLimit: Int
}

@main
struct CleanMacAppCLI {
    static func main() async {
        do {
            let options = parseOptions(CommandLine.arguments)
            let databaseURL = try makeDatabaseURL()
            let store = try SQLiteStore(databaseURL: databaseURL)
            let fileSystem = LocalFileSystemAdapter()
            let scanUseCase = DefaultScanUseCase(fileSystem: fileSystem, store: store)
            let dashboardUseCase = DefaultDashboardUseCase(store: store)
            let recommendationUseCase = DefaultRecommendationUseCase(fileSystem: fileSystem, store: store)
            let cleanupUseCase = DefaultCleanupUseCase(fileSystem: fileSystem, store: store)
            let historyUseCase = DefaultHistoryUseCase(store: store)

            if let exportJobID = options.exportJobID {
                let reportURL = try await historyUseCase.exportJobReport(
                    jobID: exportJobID,
                    directory: nil,
                    format: options.exportFormat
                )
                print("Exported report: \(reportURL.path)")
                return
            }

            if let historyQuery = options.historySearchQuery {
                try await runHistorySearch(query: historyQuery, limit: options.historySearchLimit, historyUseCase: historyUseCase)
                return
            }

            let scope = buildScope(from: options)
            if scope.roots.isEmpty {
                print("No valid scan roots found. Exiting.")
                return
            }

            print("Starting scan on \(scope.roots.count) root(s)...")
            for root in scope.roots {
                print("- \(root.path)")
            }

            let sessionID = try await scanUseCase.start(scope: scope)
            print("Session: \(sessionID.uuidString)")

            let progressTask = Task {
                let stream = await scanUseCase.progressStream(sessionID: sessionID)
                for await progress in stream {
                    let bytes = ByteFormatting.string(from: progress.totalBytes)
                    let pathSuffix = String(progress.currentPath.suffix(70))
                    print("scanned=\(progress.scannedCount) bytes=\(bytes) file=...\(pathSuffix)")
                }
            }

            while true {
                try await Task.sleep(for: .milliseconds(500))
                guard let snapshot = try await dashboardUseCase.fetchSession(sessionID: sessionID) else {
                    continue
                }

                switch snapshot.status {
                case .running, .idle:
                    continue
                case .finished:
                    progressTask.cancel()
                    print("Scan completed: \(snapshot.scannedCount) files, \(ByteFormatting.string(from: snapshot.scannedBytes))")
                    try await printTopDirectories(for: sessionID, dashboardUseCase: dashboardUseCase)
                    try await recommendationUseCase.build(sessionID: sessionID, rules: .default)
                    try await printCandidateSummary(for: sessionID, recommendationUseCase: recommendationUseCase)
                    try await runCleanupIfNeeded(
                        options: options,
                        sessionID: sessionID,
                        recommendationUseCase: recommendationUseCase,
                        cleanupUseCase: cleanupUseCase
                    )
                    return
                case let .failed(message):
                    progressTask.cancel()
                    print("Scan failed: \(message)")
                    return
                case .cancelled:
                    progressTask.cancel()
                    print("Scan cancelled")
                    return
                }
            }
        } catch {
            print("Fatal error: \(error)")
        }
    }

    private static func runCleanupIfNeeded(
        options: CLIOptions,
        sessionID: ScanSessionID,
        recommendationUseCase: DefaultRecommendationUseCase,
        cleanupUseCase: DefaultCleanupUseCase
    ) async throws {
        guard !options.cleanupTypes.isEmpty else {
            return
        }

        let dedupedCandidateIDs = try await collectCleanupCandidateIDs(
            sessionID: sessionID,
            recommendationUseCase: recommendationUseCase,
            cleanupTypes: options.cleanupTypes
        )

        if dedupedCandidateIDs.isEmpty {
            print("\nCleanup skipped: no matching candidates.")
            return
        }

        let summary = try await cleanupUseCase.execute(
            sessionID: sessionID,
            candidateIDs: dedupedCandidateIDs,
            action: .moveToTrash
        )

        print("\nCleanup result:")
        print("- job: \(summary.jobID.uuidString)")
        print("- success: \(summary.successCount)")
        print("- failed: \(summary.failCount)")
        print("- reclaimed: \(ByteFormatting.string(from: summary.reclaimedBytes))")
    }

    private static func collectCleanupCandidateIDs(
        sessionID: ScanSessionID,
        recommendationUseCase: DefaultRecommendationUseCase,
        cleanupTypes: Set<CandidateType>
    ) async throws -> [CandidateID] {
        let orderedTypes: [CandidateType] = [.cache, .duplicate, .largeFile]
        var pathToID: [String: CandidateID] = [:]

        for type in orderedTypes where cleanupTypes.contains(type) {
            let candidates = try await recommendationUseCase.list(sessionID: sessionID, type: type, limit: 100_000)
            for candidate in candidates {
                if pathToID[candidate.filePath] == nil {
                    pathToID[candidate.filePath] = candidate.id
                }
            }
        }

        return Array(pathToID.values)
    }

    private static func printTopDirectories(for sessionID: ScanSessionID, dashboardUseCase: DefaultDashboardUseCase) async throws {
        let top = try await dashboardUseCase.topDirectories(sessionID: sessionID, limit: 10)
        if top.isEmpty {
            print("No directory stats available yet.")
            return
        }

        print("\nTop directories by size:")
        for (index, item) in top.enumerated() {
            let size = ByteFormatting.string(from: item.bytes)
            print("\(index + 1). \(size) | \(item.fileCount) files | \(item.parentPath)")
        }
    }

    private static func printCandidateSummary(
        for sessionID: ScanSessionID,
        recommendationUseCase: DefaultRecommendationUseCase
    ) async throws {
        let largeSummary = try await recommendationUseCase.summary(sessionID: sessionID, type: .largeFile)
        let cacheSummary = try await recommendationUseCase.summary(sessionID: sessionID, type: .cache)
        let duplicateSummary = try await recommendationUseCase.summary(sessionID: sessionID, type: .duplicate)

        print("\nRecommendation summary:")
        print("- large files: \(largeSummary.count) items, \(ByteFormatting.string(from: largeSummary.totalBytes)) reclaimable")
        print("- cache files: \(cacheSummary.count) items, \(ByteFormatting.string(from: cacheSummary.totalBytes)) reclaimable")
        print("- duplicate files: \(duplicateSummary.count) items, \(ByteFormatting.string(from: duplicateSummary.totalBytes)) reclaimable")

        let largeTop = try await recommendationUseCase.list(sessionID: sessionID, type: .largeFile, limit: 5)
        if !largeTop.isEmpty {
            print("\nTop large files:")
            for (index, item) in largeTop.enumerated() {
                print("\(index + 1). \(ByteFormatting.string(from: item.estimatedBytes)) | \(item.filePath)")
            }
        }

        let cacheTop = try await recommendationUseCase.list(sessionID: sessionID, type: .cache, limit: 5)
        if !cacheTop.isEmpty {
            print("\nTop cache files:")
            for (index, item) in cacheTop.enumerated() {
                print("\(index + 1). \(ByteFormatting.string(from: item.estimatedBytes)) | \(item.filePath)")
            }
        }

        let duplicateTop = try await recommendationUseCase.list(sessionID: sessionID, type: .duplicate, limit: 5)
        if !duplicateTop.isEmpty {
            print("\nTop duplicate files:")
            for (index, item) in duplicateTop.enumerated() {
                print("\(index + 1). \(ByteFormatting.string(from: item.estimatedBytes)) | \(item.filePath)")
            }
        }
    }

    private static func makeDatabaseURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbFolder = home.appendingPathComponent(".cleanmacapp", isDirectory: true)
        try FileManager.default.createDirectory(at: dbFolder, withIntermediateDirectories: true)
        return dbFolder.appendingPathComponent("cleanmacapp.sqlite", isDirectory: false)
    }

    private static func buildScope(from options: CLIOptions) -> ScanScope {
        if options.useQuickScope {
            return QuickScanScopeBuilder.build()
        }

        let urls = options.scanPaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        }
        return ScanScope(roots: urls, isQuickMode: false)
    }

    private static func parseOptions(_ arguments: [String]) -> CLIOptions {
        var scanPaths: [String] = []
        var cleanupTypes: Set<CandidateType> = []
        var exportJobID: CleanupJobID?
        var exportFormat: ReportFormat = .markdown
        var historySearchQuery: String?
        var historySearchLimit = 20

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--cleanup-cache":
                cleanupTypes.insert(.cache)
            case "--cleanup-large":
                cleanupTypes.insert(.largeFile)
            case "--cleanup-all":
                cleanupTypes.insert(.cache)
                cleanupTypes.insert(.largeFile)
                cleanupTypes.insert(.duplicate)
            case "--cleanup-duplicate":
                cleanupTypes.insert(.duplicate)
            case "--export-job":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    print("Missing value for --export-job")
                    Foundation.exit(2)
                }
                let raw = arguments[valueIndex]
                guard let parsed = UUID(uuidString: raw) else {
                    print("Invalid job id: \(raw)")
                    Foundation.exit(2)
                }
                exportJobID = parsed
                index += 1
            case "--export-format":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    print("Missing value for --export-format")
                    Foundation.exit(2)
                }
                let raw = arguments[valueIndex].lowercased()
                guard let parsed = ReportFormat(rawValue: raw) else {
                    print("Invalid export format: \(raw). Use markdown|json|csv")
                    Foundation.exit(2)
                }
                exportFormat = parsed
                index += 1
            case "--history-search":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    print("Missing value for --history-search")
                    Foundation.exit(2)
                }
                historySearchQuery = arguments[valueIndex]
                index += 1
            case "--history-limit":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    print("Missing value for --history-limit")
                    Foundation.exit(2)
                }
                guard let parsed = Int(arguments[valueIndex]), parsed > 0 else {
                    print("Invalid history limit: \(arguments[valueIndex])")
                    Foundation.exit(2)
                }
                historySearchLimit = parsed
                index += 1
            case "--help", "-h":
                printUsageAndExit()
            default:
                scanPaths.append(argument)
            }
            index += 1
        }

        return CLIOptions(
            scanPaths: scanPaths,
            useQuickScope: scanPaths.isEmpty,
            cleanupTypes: cleanupTypes,
            exportJobID: exportJobID,
            exportFormat: exportFormat,
            historySearchQuery: historySearchQuery,
            historySearchLimit: historySearchLimit
        )
    }

    private static func runHistorySearch(
        query: String,
        limit: Int,
        historyUseCase: DefaultHistoryUseCase
    ) async throws {
        let jobs = try await historyUseCase.recentJobs(limit: limit, offset: 0, query: query)
        print("History search query: \(query)")
        print("Matched jobs: \(jobs.count)")

        if jobs.isEmpty {
            return
        }

        for (index, job) in jobs.enumerated() {
            print("\(index + 1). job=\(job.jobID.uuidString) status=\(job.status.rawValue) action=\(job.action.rawValue) success=\(job.successCount) fail=\(job.failCount) started=\(job.startedAt)")
            let matchedResults = try await historyUseCase.cleanupResults(jobID: job.jobID, query: query)
            if !matchedResults.isEmpty {
                print("   matched results: \(matchedResults.count)")
                for item in matchedResults.prefix(2) {
                    let status = item.result.rawValue
                    print("   - [\(status)] \(item.filePath)")
                }
            }
        }
    }

    private static func printUsageAndExit() -> Never {
        print("""
        Usage:
          cleanmacapp-cli [scan_path ...] [--cleanup-cache] [--cleanup-large] [--cleanup-duplicate] [--cleanup-all]
          cleanmacapp-cli --export-job <JOB_ID> [--export-format markdown|json|csv]
          cleanmacapp-cli --history-search <QUERY> [--history-limit N]

        Examples:
          cleanmacapp-cli
          cleanmacapp-cli ~/Downloads
          cleanmacapp-cli ~/Library/Caches --cleanup-cache
          cleanmacapp-cli ~/Downloads --cleanup-duplicate
          cleanmacapp-cli ~/Desktop --cleanup-all
          cleanmacapp-cli --export-job 20AE68C4-277C-4ACE-B34E-EE10AAAABA5F
          cleanmacapp-cli --export-job 20AE68C4-277C-4ACE-B34E-EE10AAAABA5F --export-format json
          cleanmacapp-cli --history-search "status:failed path:cache"
          cleanmacapp-cli --history-search "path:tmpflea~"
          cleanmacapp-cli --history-search "path_re:temp-.*-a\\.log"
          cleanmacapp-cli --history-search "rank:recency status:finished path:cache"
          cleanmacapp-cli --history-search "regex_case:sensitive path_re:Cache.*\\.bin"
        """)
        Foundation.exit(0)
    }
}
