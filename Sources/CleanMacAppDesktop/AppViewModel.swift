import CleanMacCore
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var useQuickScan = true {
        didSet {
            if useQuickScan {
                useFullDiskScan = false
            }
        }
    }
    @Published var useFullDiskScan = false {
        didSet {
            if useFullDiskScan {
                useQuickScan = false
            }
        }
    }
    @Published var customPathsText = ""
    @Published var isScanning = false
    @Published var isLoadingRecommendations = false
    @Published var isCleaning = false

    @Published var scannedCount = 0
    @Published var scannedBytes: Int64 = 0
    @Published var currentPath = ""
    @Published var statusText = "Ready"

    @Published var topDirectories: [DirectoryUsage] = []
    @Published var selectedCandidateType: CandidateType = .cache {
        didSet {
            if selectedCandidateType != oldValue {
                persistPreset(for: oldValue)
                applyPreset(for: selectedCandidateType)
            }
        }
    }
    @Published var candidateSearchQuery = "" {
        didSet { persistPresetForCurrentType() }
    }
    @Published var minCandidateSizeMB: Double = 0 {
        didSet { persistPresetForCurrentType() }
    }
    @Published var candidateSortOption: CandidateSortOption = .sizeDesc {
        didSet { persistPresetForCurrentType() }
    }

    @Published var candidateSummaries: [CandidateType: CandidateSummary] = [:]
    @Published var candidatesByType: [CandidateType: [CleanupCandidate]] = [:]
    @Published var selectedCandidateIDsByType: [CandidateType: Set<CandidateID>] = [:]

    @Published var historySearchQuery = ""
    @Published var historyRankingProfile: HistoryRankingProfileOption = .balanced {
        didSet {
            guard historyRankingProfile != oldValue else { return }
            defaults.set(historyRankingProfile.rawValue, forKey: historyRankingProfileKey)
            Task {
                await loadCleanupHistory(pageIndex: 0)
            }
        }
    }
    @Published var reportExportFormat: ReportFormat = .markdown
    @Published var cleanupJobs: [CleanupJobRecord] = []
    @Published var selectedHistoryJobID: CleanupJobID?
    @Published var failedItemsForSelectedJob: [FailedCleanupItem] = []
    @Published var selectedFailedItemPaths: Set<String> = []
    @Published var historyPageIndex = 0
    @Published var hasNextHistoryPage = false
    let historyPageSize = 20

    @Published var latestSessionID: ScanSessionID?
    @Published var latestCleanupJobID: CleanupJobID?
    @Published var lastExportedReportPath = ""

    private let env: AppEnvironment
    private var progressTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var lastAutoPreviewAt: Date = .distantPast
    private var lastAutoPreviewScannedCount = 0
    private let autoPreviewInterval: TimeInterval = 15
    private let autoPreviewScannedDelta = 120_000

    private let defaults = UserDefaults.standard
    private let presetsKey = "cleanmacapp.candidate-filter-presets.v1"
    private let historyRankingProfileKey = "cleanmacapp.history-ranking-profile.v1"
    private var candidateFilterPresets: [CandidateType: CandidateFilterPreset] = [:]
    private var isApplyingPreset = false

    init(env: AppEnvironment) {
        self.env = env
        if let raw = defaults.string(forKey: historyRankingProfileKey),
           let profile = HistoryRankingProfileOption(rawValue: raw) {
            historyRankingProfile = profile
        }
        loadPresetsFromDefaults()
        applyPreset(for: selectedCandidateType)
    }

    deinit {
        progressTask?.cancel()
        monitorTask?.cancel()
    }

    func onAppear() {
        Task {
            await loadCleanupHistory(pageIndex: 0)
        }
    }

    func startScan() {
        guard !isScanning else { return }

        let scope = buildScope()
        guard !scope.roots.isEmpty else {
            statusText = "No valid scan roots."
            return
        }

        clearResultsForNewScan()
        statusText = "Starting scan..."

        Task {
            do {
                let sessionID = try await env.scanUseCase.start(scope: scope)
                latestSessionID = sessionID
                isScanning = true
                statusText = "Scanning..."
                lastAutoPreviewAt = .distantPast
                lastAutoPreviewScannedCount = 0

                startProgressStream(sessionID: sessionID)
                startMonitor(sessionID: sessionID)
            } catch {
                statusText = "Failed to start scan: \(error.localizedDescription)"
            }
        }
    }

    func cancelScan() {
        guard let sessionID = latestSessionID else { return }
        Task {
            await env.scanUseCase.cancel(sessionID: sessionID)
            statusText = "Cancelling..."
        }
    }

    func refreshRecommendations() {
        guard let sessionID = latestSessionID else {
            statusText = "No scan session available."
            return
        }
        Task {
            if isScanning {
                statusText = "Building partial recommendations from current scan progress..."
            }
            await rebuildAndLoadRecommendations(sessionID: sessionID, previewOnly: isScanning)
        }
    }

    func applyHistorySearch() {
        Task {
            await loadCleanupHistory(pageIndex: 0)
        }
    }

    func clearHistorySearch() {
        historySearchQuery = ""
        Task {
            await loadCleanupHistory(pageIndex: 0)
        }
    }

    func refreshHistory() {
        Task {
            await loadCleanupHistory(pageIndex: historyPageIndex)
        }
    }

    func nextHistoryPage() {
        guard hasNextHistoryPage else { return }
        Task {
            await loadCleanupHistory(pageIndex: historyPageIndex + 1)
        }
    }

    func previousHistoryPage() {
        guard historyPageIndex > 0 else { return }
        Task {
            await loadCleanupHistory(pageIndex: historyPageIndex - 1)
        }
    }

    func cleanupSelectedType() {
        cleanup(types: [selectedCandidateType])
    }

    func cleanupAllTypes() {
        cleanup(types: CandidateType.displayTypes)
    }

    func retryFailedForSelectedJob() {
        guard let jobID = selectedHistoryJobID else {
            statusText = "No cleanup job selected."
            return
        }

        guard !isCleaning else { return }

        Task {
            do {
                isCleaning = true
                statusText = "Retrying failed items for job..."

                let summary = try await env.cleanupUseCase.retryFailed(jobID: jobID)
                latestCleanupJobID = summary.jobID

                isCleaning = false
                statusText = "Retry finished: success=\(summary.successCount), fail=\(summary.failCount), moved=\(ByteFormatting.string(from: summary.reclaimedBytes)). Items are in Trash; empty Trash to free disk."

                await loadCleanupHistory(pageIndex: 0, selectJobID: summary.jobID)
                if let sessionID = latestSessionID {
                    await rebuildAndLoadRecommendations(sessionID: sessionID, previewOnly: false)
                }
            } catch {
                isCleaning = false
                statusText = "Retry failed: \(error.localizedDescription)"
            }
        }
    }

    func exportSelectedJobReport() {
        guard let jobID = selectedHistoryJobID else {
            statusText = "No cleanup job selected."
            return
        }

        Task {
            do {
                let fileURL = try await env.historyUseCase.exportJobReport(
                    jobID: jobID,
                    directory: nil,
                    format: reportExportFormat
                )
                lastExportedReportPath = fileURL.path
                statusText = "Report exported: \(fileURL.path)"
            } catch {
                statusText = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func retrySelectedFailedItemsForSelectedJob() {
        guard let jobID = selectedHistoryJobID else {
            statusText = "No cleanup job selected."
            return
        }

        let paths = Array(selectedFailedItemPaths)
        guard !paths.isEmpty else {
            statusText = "No failed items selected."
            return
        }

        guard !isCleaning else { return }

        Task {
            do {
                isCleaning = true
                statusText = "Retrying selected failed items..."

                let summary = try await env.cleanupUseCase.retryFailed(jobID: jobID, filePaths: paths)
                latestCleanupJobID = summary.jobID

                isCleaning = false
                statusText = "Retry selected finished: success=\(summary.successCount), fail=\(summary.failCount), moved=\(ByteFormatting.string(from: summary.reclaimedBytes)). Items are in Trash; empty Trash to free disk."

                await loadCleanupHistory(pageIndex: 0, selectJobID: summary.jobID)
                if let sessionID = latestSessionID {
                    await rebuildAndLoadRecommendations(sessionID: sessionID, previewOnly: false)
                }
            } catch {
                isCleaning = false
                statusText = "Retry selected failed: \(error.localizedDescription)"
            }
        }
    }

    func hasCandidates(for type: CandidateType) -> Bool {
        !(candidatesByType[type]?.isEmpty ?? true)
    }

    func selectedCount(for type: CandidateType) -> Int {
        selectedCandidateIDsByType[type]?.count ?? 0
    }

    func totalSelectedCount() -> Int {
        selectedCandidateIDsByType.values.reduce(0) { partial, ids in
            partial + ids.count
        }
    }

    func filteredCandidatesForSelectedType() -> [CleanupCandidate] {
        filteredCandidates(for: selectedCandidateType)
    }

    func deletionHint(for candidate: CleanupCandidate) -> CandidateDeletionHint {
        let lowerPath = candidate.filePath.lowercased()
        let fileURL = URL(fileURLWithPath: candidate.filePath)
        let ext = fileURL.pathExtension.lowercased()
        let folderName = fileURL.deletingLastPathComponent().lastPathComponent

        let location: String
        if lowerPath.contains("/library/caches/") {
            location = "Library/Caches"
        } else if lowerPath.contains("/downloads/") {
            location = "Downloads"
        } else if lowerPath.contains("/desktop/") {
            location = "Desktop"
        } else if lowerPath.contains("/documents/") {
            location = "Documents"
        } else {
            location = folderName.isEmpty ? "Unknown" : folderName
        }

        let extText = ext.isEmpty ? "none" : ext
        let info = "Type: \(candidate.type.displayName) | Ext: .\(extText) | Location: \(location)"

        switch candidate.type {
        case .cache:
            if lowerPath.contains("/library/caches/") || lowerPath.contains("/var/folders/") || lowerPath.contains("/tmp/") {
                return CandidateDeletionHint(
                    level: .safe,
                    info: info,
                    advice: "Usually safe to delete. App cache will be rebuilt automatically."
                )
            }
            return CandidateDeletionHint(
                level: .caution,
                info: info,
                advice: "Likely cache-related. Delete when app is closed, then verify app behavior."
            )

        case .duplicate:
            if candidate.reason.hasPrefix("Keep copy (recommended)") {
                return CandidateDeletionHint(
                    level: .review,
                    info: info,
                    advice: "Retained copy for this duplicate group. Keep this one and delete the other duplicates."
                )
            }

            if lowerPath.contains("/library/caches/") {
                return CandidateDeletionHint(
                    level: .safe,
                    info: info,
                    advice: "Duplicate cache file. Usually safe to remove, but keep at least one copy."
                )
            }
            return CandidateDeletionHint(
                level: .safe,
                info: info,
                advice: "Extra duplicate copy. Safe to delete as long as the retained copy stays."
            )

        case .largeFile:
            let saferExtensions: Set<String> = ["zip", "rar", "7z", "dmg", "pkg", "iso", "tar", "gz", "xz", "bz2", "log", "tmp", "bak"]
            let personalExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "mov", "mp4", "m4v", "mp3", "wav", "aiff", "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "pages", "numbers", "key", "psd", "ai"]

            if saferExtensions.contains(ext), lowerPath.contains("/downloads/") {
                return CandidateDeletionHint(
                    level: .safe,
                    info: info,
                    advice: "Looks like a downloaded package/archive. Usually safe after confirming it is no longer needed."
                )
            }

            if personalExtensions.contains(ext) {
                return CandidateDeletionHint(
                    level: .review,
                    info: info,
                    advice: "Potential personal/work file. Review content first, or move to external storage."
                )
            }

            switch candidate.risk {
            case .low:
                return CandidateDeletionHint(
                    level: .safe,
                    info: info,
                    advice: "Low-risk large file candidate. Verify once, then delete if not needed."
                )
            case .medium:
                return CandidateDeletionHint(
                    level: .caution,
                    info: info,
                    advice: "May still be useful. Confirm last usage before deleting."
                )
            case .high:
                return CandidateDeletionHint(
                    level: .review,
                    info: info,
                    advice: "High-risk large file. Recommended to keep or back up before deletion."
                )
            }

        case .oldDownload, .installerPackage:
            return CandidateDeletionHint(
                level: .caution,
                info: info,
                advice: "Review once before deletion."
            )
        }
    }

    func isCandidateSelected(_ candidate: CleanupCandidate) -> Bool {
        selectedCandidateIDsByType[candidate.type]?.contains(candidate.id) ?? false
    }

    func setCandidateSelected(_ candidate: CleanupCandidate, selected: Bool) {
        var set = selectedCandidateIDsByType[candidate.type] ?? Set<CandidateID>()
        if selected {
            set.insert(candidate.id)
        } else {
            set.remove(candidate.id)
        }
        selectedCandidateIDsByType[candidate.type] = set
    }

    func selectAllCurrentType() {
        let type = selectedCandidateType
        let ids = Set(filteredCandidates(for: type).map(\.id))
        selectedCandidateIDsByType[type] = ids
    }

    func clearSelectionCurrentType() {
        selectedCandidateIDsByType[selectedCandidateType] = []
    }

    func selectDefaultCurrentType() {
        let type = selectedCandidateType
        let ids = Set(filteredCandidates(for: type).filter { $0.selectedByDefault }.map(\.id))
        selectedCandidateIDsByType[type] = ids
    }

    func selectHistoryJob(_ jobID: CleanupJobID) {
        selectedHistoryJobID = jobID
        Task {
            await loadFailedItems(jobID: jobID)
        }
    }

    func isFailedItemSelected(_ item: FailedCleanupItem) -> Bool {
        selectedFailedItemPaths.contains(item.filePath)
    }

    func setFailedItemSelected(_ item: FailedCleanupItem, selected: Bool) {
        if selected {
            selectedFailedItemPaths.insert(item.filePath)
        } else {
            selectedFailedItemPaths.remove(item.filePath)
        }
    }

    func selectAllFailedItems() {
        selectedFailedItemPaths = Set(failedItemsForSelectedJob.map(\.filePath))
    }

    func clearFailedSelection() {
        selectedFailedItemPaths = []
    }

    private func filteredCandidates(for type: CandidateType) -> [CleanupCandidate] {
        let items = candidatesByType[type] ?? []
        let query = candidateSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minBytes = Int64(minCandidateSizeMB * 1024 * 1024)

        let filtered = items.filter { item in
            if item.estimatedBytes < minBytes {
                return false
            }

            if query.isEmpty {
                return true
            }

            return item.filePath.lowercased().contains(query) || item.reason.lowercased().contains(query)
        }

        switch candidateSortOption {
        case .sizeDesc:
            return filtered.sorted { $0.estimatedBytes > $1.estimatedBytes }
        case .sizeAsc:
            return filtered.sorted { $0.estimatedBytes < $1.estimatedBytes }
        case .pathAsc:
            return filtered.sorted { $0.filePath.localizedStandardCompare($1.filePath) == .orderedAscending }
        case .pathDesc:
            return filtered.sorted { $0.filePath.localizedStandardCompare($1.filePath) == .orderedDescending }
        }
    }

    private func cleanup(types: [CandidateType]) {
        guard let sessionID = latestSessionID else {
            statusText = "No scan session available."
            return
        }

        guard !isCleaning else { return }

        Task {
            do {
                let candidateIDs = collectSelectedCandidateIDs(for: types)
                guard !candidateIDs.isEmpty else {
                    statusText = "No selected candidates to clean."
                    return
                }

                isCleaning = true
                statusText = "Cleaning..."

                let summary = try await env.cleanupUseCase.execute(
                    sessionID: sessionID,
                    candidateIDs: candidateIDs,
                    action: .moveToTrash
                )

                latestCleanupJobID = summary.jobID
                statusText = "Cleanup finished: success=\(summary.successCount), fail=\(summary.failCount), moved=\(ByteFormatting.string(from: summary.reclaimedBytes)). Items are in Trash; empty Trash to free disk."
                isCleaning = false

                await loadCleanupHistory(pageIndex: 0, selectJobID: summary.jobID)
                await rebuildAndLoadRecommendations(sessionID: sessionID, previewOnly: false, announceStatus: false)
            } catch {
                isCleaning = false
                statusText = "Cleanup failed: \(error.localizedDescription)"
            }
        }
    }

    private func collectSelectedCandidateIDs(for types: [CandidateType]) -> [CandidateID] {
        var pathToID: [String: CandidateID] = [:]

        for type in types {
            let selectedIDs = selectedCandidateIDsByType[type] ?? []
            let candidates = candidatesByType[type] ?? []

            for candidate in candidates where selectedIDs.contains(candidate.id) {
                if pathToID[candidate.filePath] == nil {
                    pathToID[candidate.filePath] = candidate.id
                }
            }
        }

        return Array(pathToID.values)
    }

    private func clearResultsForNewScan() {
        scannedCount = 0
        scannedBytes = 0
        currentPath = ""
        topDirectories = []
        candidateSummaries = [:]
        candidatesByType = [:]
        selectedCandidateIDsByType = [:]
        latestCleanupJobID = nil
    }

    private func buildScope() -> ScanScope {
        if useFullDiskScan {
            return ScanScope(
                roots: [URL(fileURLWithPath: "/", isDirectory: true)],
                isQuickMode: false
            )
        }

        if useQuickScan {
            return QuickScanScopeBuilder.build()
        }

        let rawItems = customPathsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let roots = rawItems.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        }

        return ScanScope(roots: roots, isQuickMode: false)
    }

    private func startProgressStream(sessionID: ScanSessionID) {
        progressTask?.cancel()
        progressTask = Task {
            let stream = await env.scanUseCase.progressStream(sessionID: sessionID)
            for await progress in stream {
                if Task.isCancelled { break }
                scannedCount = progress.scannedCount
                scannedBytes = progress.totalBytes
                currentPath = progress.currentPath
            }
        }
    }

    private func startMonitor(sessionID: ScanSessionID) {
        monitorTask?.cancel()
        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))

                guard let snapshot = try? await env.dashboardUseCase.fetchSession(sessionID: sessionID) else {
                    continue
                }

                switch snapshot.status {
                case .idle, .running:
                    if shouldAutoRefreshPreview(scannedCount: snapshot.scannedCount) {
                        await rebuildAndLoadRecommendations(sessionID: sessionID, previewOnly: true)
                    }
                    continue
                case .finished:
                    isScanning = false
                    scannedCount = snapshot.scannedCount
                    scannedBytes = snapshot.scannedBytes
                    statusText = "Scan finished: \(snapshot.scannedCount) files, \(ByteFormatting.string(from: snapshot.scannedBytes))"
                    progressTask?.cancel()

                    await loadTopDirectories(sessionID: sessionID)
                    await rebuildAndLoadRecommendations(sessionID: sessionID, previewOnly: false)
                    return
                case .cancelled:
                    isScanning = false
                    progressTask?.cancel()
                    statusText = "Scan cancelled. Building partial recommendations from scanned files..."
                    await loadTopDirectories(sessionID: sessionID)
                    await rebuildAndLoadRecommendations(sessionID: sessionID, previewOnly: true)
                    return
                case let .failed(message):
                    isScanning = false
                    progressTask?.cancel()
                    statusText = "Scan failed: \(message)"
                    return
                }
            }
        }
    }

    private func loadTopDirectories(sessionID: ScanSessionID) async {
        do {
            topDirectories = try await env.dashboardUseCase.topDirectories(sessionID: sessionID, limit: 20)
        } catch {
            statusText = "Failed loading directories: \(error.localizedDescription)"
        }
    }

    private func rebuildAndLoadRecommendations(
        sessionID: ScanSessionID,
        previewOnly: Bool,
        announceStatus: Bool = true
    ) async {
        guard !isLoadingRecommendations else { return }

        do {
            isLoadingRecommendations = true
            if announceStatus {
                statusText = previewOnly ? "Building lightweight recommendations..." : "Building recommendations..."
            }

            if previewOnly {
                try await env.recommendationUseCase.buildPreview(sessionID: sessionID, rules: .default)
            } else {
                try await env.recommendationUseCase.build(sessionID: sessionID, rules: .default)
            }

            var summaries: [CandidateType: CandidateSummary] = [:]
            var items: [CandidateType: [CleanupCandidate]] = [:]
            var selected: [CandidateType: Set<CandidateID>] = [:]

            for type in CandidateType.displayTypes {
                let summary = try await env.recommendationUseCase.summary(sessionID: sessionID, type: type)
                let list = try await env.recommendationUseCase.list(sessionID: sessionID, type: type, limit: 2000)
                let oldSelected = selectedCandidateIDsByType[type] ?? []
                let retainedSelection = Set(list.filter { oldSelected.contains($0.id) }.map(\.id))
                let defaultSelection = Set(list.filter { $0.selectedByDefault }.map(\.id))

                summaries[type] = summary
                items[type] = list
                selected[type] = retainedSelection.isEmpty ? defaultSelection : retainedSelection
            }

            candidateSummaries = summaries
            candidatesByType = items
            selectedCandidateIDsByType = selected
            if announceStatus {
                statusText = previewOnly ? "Preview recommendations updated." : "Recommendations ready."
            }
            if previewOnly {
                lastAutoPreviewAt = Date()
                lastAutoPreviewScannedCount = scannedCount
            }
            isLoadingRecommendations = false
        } catch {
            isLoadingRecommendations = false
            statusText = "Failed building recommendations: \(error.localizedDescription)"
        }
    }

    private func shouldAutoRefreshPreview(scannedCount: Int) -> Bool {
        guard isScanning else { return false }
        guard !isLoadingRecommendations else { return false }

        let now = Date()
        guard now.timeIntervalSince(lastAutoPreviewAt) >= autoPreviewInterval else { return false }
        guard scannedCount >= lastAutoPreviewScannedCount + autoPreviewScannedDelta else { return false }

        return true
    }

    private func loadCleanupHistory(pageIndex: Int? = nil, selectJobID: CleanupJobID? = nil) async {
        do {
            let targetPage = max(0, pageIndex ?? historyPageIndex)
            let offset = targetPage * historyPageSize
            let query = normalizedHistoryQuery()
            cleanupJobs = try await env.historyUseCase.recentJobs(limit: historyPageSize, offset: offset, query: query)
            historyPageIndex = targetPage
            hasNextHistoryPage = cleanupJobs.count == historyPageSize

            if let selectJobID, cleanupJobs.contains(where: { $0.jobID == selectJobID }) {
                selectedHistoryJobID = selectJobID
            } else if let current = selectedHistoryJobID,
                      cleanupJobs.contains(where: { $0.jobID == current }) {
                selectedHistoryJobID = current
            } else {
                selectedHistoryJobID = cleanupJobs.first?.jobID
            }

            if let jobID = selectedHistoryJobID {
                await loadFailedItems(jobID: jobID)
            } else {
                failedItemsForSelectedJob = []
                selectedFailedItemPaths = []
            }
        } catch {
            statusText = "Failed loading cleanup history: \(error.localizedDescription)"
        }
    }

    private func loadFailedItems(jobID: CleanupJobID) async {
        do {
            failedItemsForSelectedJob = try await env.historyUseCase.failedItems(jobID: jobID)
            selectedFailedItemPaths = Set(failedItemsForSelectedJob.map(\.filePath))
        } catch {
            failedItemsForSelectedJob = []
            selectedFailedItemPaths = []
            statusText = "Failed loading failed items: \(error.localizedDescription)"
        }
    }

    private func normalizedHistoryQuery() -> String? {
        let trimmed = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let rankPrefix = "rank:\(historyRankingProfile.rawValue)"
        if trimmed.isEmpty {
            return rankPrefix
        }
        return "\(rankPrefix) \(trimmed)"
    }

    private func persistPresetForCurrentType() {
        persistPreset(for: selectedCandidateType)
    }

    private func persistPreset(for type: CandidateType) {
        guard !isApplyingPreset else { return }

        candidateFilterPresets[type] = CandidateFilterPreset(
            query: candidateSearchQuery,
            minSizeMB: minCandidateSizeMB,
            sortRawValue: candidateSortOption.rawValue
        )
        savePresetsToDefaults()
    }

    private func applyPreset(for type: CandidateType) {
        isApplyingPreset = true
        let preset = candidateFilterPresets[type] ?? CandidateFilterPreset.default
        candidateSearchQuery = preset.query
        minCandidateSizeMB = preset.minSizeMB
        candidateSortOption = CandidateSortOption(rawValue: preset.sortRawValue) ?? .sizeDesc
        isApplyingPreset = false
    }

    private func loadPresetsFromDefaults() {
        guard let data = defaults.data(forKey: presetsKey) else {
            candidateFilterPresets = [:]
            return
        }

        guard let decoded = try? JSONDecoder().decode([String: CandidateFilterPreset].self, from: data) else {
            candidateFilterPresets = [:]
            return
        }

        var presets: [CandidateType: CandidateFilterPreset] = [:]
        for (rawKey, preset) in decoded {
            if let type = CandidateType(rawValue: rawKey) {
                presets[type] = preset
            }
        }
        candidateFilterPresets = presets
    }

    private func savePresetsToDefaults() {
        var encoded: [String: CandidateFilterPreset] = [:]
        for (type, preset) in candidateFilterPresets {
            encoded[type.rawValue] = preset
        }

        guard let data = try? JSONEncoder().encode(encoded) else {
            return
        }
        defaults.set(data, forKey: presetsKey)
    }
}

enum CandidateSortOption: String, CaseIterable, Identifiable {
    case sizeDesc
    case sizeAsc
    case pathAsc
    case pathDesc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sizeDesc:
            return "Size ↓"
        case .sizeAsc:
            return "Size ↑"
        case .pathAsc:
            return "Path A-Z"
        case .pathDesc:
            return "Path Z-A"
        }
    }
}

enum HistoryRankingProfileOption: String, CaseIterable, Identifiable {
    case balanced
    case recency
    case path

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .recency:
            return "Recency"
        case .path:
            return "Path Priority"
        }
    }
}

private struct CandidateFilterPreset: Codable {
    let query: String
    let minSizeMB: Double
    let sortRawValue: String

    static let `default` = CandidateFilterPreset(query: "", minSizeMB: 0, sortRawValue: CandidateSortOption.sizeDesc.rawValue)
}

struct CandidateDeletionHint {
    let level: DeletionSafetyLevel
    let info: String
    let advice: String
}

enum DeletionSafetyLevel {
    case safe
    case caution
    case review

    var displayName: String {
        switch self {
        case .safe:
            return "Safe"
        case .caution:
            return "Caution"
        case .review:
            return "Review First"
        }
    }
}
