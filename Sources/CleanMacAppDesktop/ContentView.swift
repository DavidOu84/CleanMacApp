import CleanMacCore
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: AppViewModel
    @State private var showingHistoryQueryHelp = false

    init(viewModel: AppViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                scanControls
                Divider()
                statusBlock
                Divider()
                summaryBlock
                Spacer()
            }
            .padding()
            .navigationTitle("CleanMacApp")
        } detail: {
            TabView {
                candidatesPane
                    .tabItem {
                        Label("Candidates", systemImage: "checklist")
                    }

                historyPane
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
            }
            .padding()
        }
        .frame(minWidth: 1220, minHeight: 760)
        .onAppear {
            viewModel.onAppear()
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan")
                .font(.headline)

            Toggle("Quick scan (Desktop/Documents/Downloads/Library/Caches)", isOn: $viewModel.useQuickScan)

            if !viewModel.useQuickScan {
                Text("Custom paths (one per line or comma-separated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.customPathsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }

            HStack(spacing: 8) {
                Button("Start Scan") { viewModel.startScan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button("Cancel") { viewModel.cancelScan() }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isScanning)

                Button("Refresh Recommendations") { viewModel.refreshRecommendations() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.latestSessionID == nil || viewModel.isScanning)
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status")
                .font(.headline)
            Text(viewModel.statusText)
                .font(.subheadline)

            Text("Scanned files: \(viewModel.scannedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Scanned size: \(ByteFormatting.string(from: viewModel.scannedBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.currentPath.isEmpty {
                Text(viewModel.currentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let sessionID = viewModel.latestSessionID {
                Text("Session: \(sessionID.uuidString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let jobID = viewModel.latestCleanupJobID {
                Text("Last cleanup job: \(jobID.uuidString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.lastExportedReportPath.isEmpty {
                Text("Last report: \(viewModel.lastExportedReportPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommendation Summary")
                .font(.headline)

            ForEach(CandidateType.displayTypes, id: \.self) { type in
                let summary = viewModel.candidateSummaries[type] ?? CandidateSummary(type: type, count: 0, totalBytes: 0)
                HStack {
                    Text(type.displayName)
                    Spacer()
                    Text("\(summary.count) files")
                        .foregroundStyle(.secondary)
                    Text("selected \(viewModel.selectedCount(for: type))")
                        .foregroundStyle(.secondary)
                    Text(ByteFormatting.string(from: summary.totalBytes))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            }
        }
    }

    private var candidatesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            candidateControls
            Divider()
            candidateList
            Divider()
            topDirectoryList
        }
    }

    private var candidateControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Candidate Type", selection: $viewModel.selectedCandidateType) {
                    ForEach(CandidateType.displayTypes, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                Spacer()

                Text("Selected: \(viewModel.selectedCount(for: viewModel.selectedCandidateType))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Filter path or reason", text: $viewModel.candidateSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)

                Picker("Sort", selection: $viewModel.candidateSortOption) {
                    ForEach(CandidateSortOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    "Min size: \(Int(viewModel.minCandidateSizeMB)) MB",
                    value: $viewModel.minCandidateSizeMB,
                    in: 0...20_000,
                    step: 50
                )
                .frame(maxWidth: 240)

                Spacer()
            }

            HStack(spacing: 8) {
                Button("Select Default") { viewModel.selectDefaultCurrentType() }
                    .buttonStyle(.bordered)
                Button("Select All (Filtered)") { viewModel.selectAllCurrentType() }
                    .buttonStyle(.bordered)
                Button("Clear") { viewModel.clearSelectionCurrentType() }
                    .buttonStyle(.bordered)

                Spacer()

                Button("Cleanup Selected Type") { viewModel.cleanupSelectedType() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedCount(for: viewModel.selectedCandidateType) == 0 || viewModel.isScanning || viewModel.isCleaning)

                Button("Cleanup All Selected") { viewModel.cleanupAllTypes() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.totalSelectedCount() == 0 || viewModel.isScanning || viewModel.isCleaning)
            }
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Candidates")
                .font(.headline)

            let items = viewModel.filteredCandidatesForSelectedType()

            List(items, id: \.id) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { viewModel.isCandidateSelected(item) },
                            set: { viewModel.setCandidateSelected(item, selected: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ByteFormatting.string(from: item.estimatedBytes))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(item.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.filePath)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No candidates for current filter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var topDirectoryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Directories")
                .font(.headline)

            List(viewModel.topDirectories, id: \.parentPath) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.parentPath)
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(item.fileCount) files")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteFormatting.string(from: item.bytes))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
            .frame(height: 180)
        }
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cleanup Jobs")
                    .font(.headline)
                Spacer()

                TextField("Search (e.g. rank:recency status:failed path:cache, path_re:temp-.*\\.log)", text: $viewModel.historySearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)

                Picker("Ranking", selection: $viewModel.historyRankingProfile) {
                    ForEach(HistoryRankingProfileOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)

                Button("Apply Search") { viewModel.applyHistorySearch() }
                    .buttonStyle(.bordered)

                Button("Clear Search") { viewModel.clearHistorySearch() }
                    .buttonStyle(.bordered)

                Button("Query Help") { showingHistoryQueryHelp = true }
                    .buttonStyle(.bordered)

                Button("Prev") { viewModel.previousHistoryPage() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.historyPageIndex == 0)

                Text("Page \(viewModel.historyPageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Next") { viewModel.nextHistoryPage() }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasNextHistoryPage)

                Button("Refresh") { viewModel.refreshHistory() }
                    .buttonStyle(.bordered)

                Picker("Format", selection: $viewModel.reportExportFormat) {
                    ForEach(ReportFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.menu)

                Button("Export Selected Job Report") { viewModel.exportSelectedJobReport() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.selectedHistoryJobID == nil)

                Button("Retry Failed In Selected Job") { viewModel.retryFailedForSelectedJob() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedHistoryJobID == nil || viewModel.failedItemsForSelectedJob.isEmpty || viewModel.isCleaning)
            }

            HStack(alignment: .top, spacing: 12) {
                List(viewModel.cleanupJobs, id: \.jobID) { job in
                    Button {
                        viewModel.selectHistoryJob(job.jobID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(job.status.displayName)
                                    .font(.caption)
                                    .foregroundStyle(job.status.color)
                                Spacer()
                                Text(ByteFormatting.string(from: job.reclaimedBytes))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                            }
                            Text(job.jobID.uuidString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("succ=\(job.successCount) fail=\(job.failCount) | \(job.startedAt, formatter: Self.jobDateFormatter)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(viewModel.selectedHistoryJobID == job.jobID ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .frame(minWidth: 420)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Failed Items")
                            .font(.headline)
                        Spacer()
                        Text("Selected: \(viewModel.selectedFailedItemPaths.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button("Select All") { viewModel.selectAllFailedItems() }
                            .buttonStyle(.bordered)
                        Button("Clear") { viewModel.clearFailedSelection() }
                            .buttonStyle(.bordered)
                        Button("Retry Selected Failed Items") { viewModel.retrySelectedFailedItemsForSelectedJob() }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.selectedHistoryJobID == nil || viewModel.selectedFailedItemPaths.isEmpty || viewModel.isCleaning)
                        Spacer()
                    }

                    List(viewModel.failedItemsForSelectedJob, id: \.filePath) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { viewModel.isFailedItemSelected(item) },
                                    set: { viewModel.setFailedItemSelected(item, selected: $0) }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(ByteFormatting.string(from: item.estimatedBytes))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text(item.filePath)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                if let error = item.errorMessage, !error.isEmpty {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .overlay {
                        if viewModel.failedItemsForSelectedJob.isEmpty {
                            Text("No failed items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingHistoryQueryHelp) {
            historyQueryHelpSheet
        }
    }

    private var historyQueryHelpSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History Query Syntax")
                .font(.title3)
                .fontWeight(.semibold)

            Group {
                Text("Basic operators")
                    .font(.headline)
                Text("`id:` `job:` `session:` `status:` `action:` `path:` `file:` `error:` `err:` `result:`")
                    .font(.caption)
                    .textSelection(.enabled)

                Text("Regex operators")
                    .font(.headline)
                Text("`re:` `id_re:` `session_re:` `status_re:` `action_re:` `path_re:` `file_re:` `error_re:` `result_re:`")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("`regex_case:sensitive|insensitive` `regex_dotall:true|false`")
                    .font(.caption)
                    .textSelection(.enabled)

                Text("Ranking")
                    .font(.headline)
                Text("`rank:balanced|recency|path`")
                    .font(.caption)
                    .textSelection(.enabled)

                Text("Examples")
                    .font(.headline)
                Text("`status:failed path:cache`")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("`path:tmpflea~`")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("`path_re:temp-.*-a\\\\.log`")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("`re:cache.*\\\\.bin`")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("`rank:recency status:finished path:cache`")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("`regex_case:sensitive path_re:Cache.*\\\\.bin`")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Close") { showingHistoryQueryHelp = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640, height: 420)
    }

    private static let jobDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

extension CandidateType {
    static let displayTypes: [CandidateType] = [.cache, .duplicate, .largeFile]

    var displayName: String {
        switch self {
        case .cache:
            return "Cache"
        case .duplicate:
            return "Duplicate"
        case .largeFile:
            return "Large"
        case .oldDownload:
            return "Old Download"
        case .installerPackage:
            return "Installer"
        }
    }
}

extension CleanupJobStatus {
    var displayName: String {
        switch self {
        case .running:
            return "RUNNING"
        case .finished:
            return "FINISHED"
        case .partial:
            return "PARTIAL"
        case .failed:
            return "FAILED"
        }
    }

    var color: Color {
        switch self {
        case .running:
            return .orange
        case .finished:
            return .green
        case .partial:
            return .yellow
        case .failed:
            return .red
        }
    }
}

extension ReportFormat {
    var displayName: String {
        switch self {
        case .markdown:
            return "Markdown"
        case .json:
            return "JSON"
        case .csv:
            return "CSV"
        }
    }
}
