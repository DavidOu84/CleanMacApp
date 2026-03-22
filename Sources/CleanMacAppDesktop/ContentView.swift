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
            sidebar
        } detail: {
            detailWorkspace
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1360, minHeight: 860)
        .onAppear {
            viewModel.onAppear()
        }
        .onChange(of: viewModel.useFullDiskScan) { isFullDisk in
            if isFullDisk {
                viewModel.refreshFullDiskAccessStatus()
            }
        }
        .sheet(isPresented: $showingHistoryQueryHelp) {
            historyQueryHelpSheet
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                appIdentityCard
                scanControlsCard
                statusCard
                summaryCard
            }
            .padding(16)
        }
        .background(sidebarBackground)
        .navigationTitle("CleanMacApp")
    }

    private var detailWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            overviewStrip

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
        }
        .padding(16)
        .background(detailBackground)
    }

    private var appIdentityCard: some View {
        card(title: "Storage Workspace", icon: "externaldrive.badge.icloud") {
            Text("Scan, assess safety, and clean large/cache/duplicate files with reversible trash-first actions.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            Text("Build: \(AppBuildInfo.label)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 8) {
                statusBadge(
                    text: isBusy ? "Processing" : "Ready",
                    color: isBusy ? .orange : .green
                )
                statusBadge(
                    text: activeScanModeLabel,
                    color: .blue
                )
            }
        }
    }

    private var scanControlsCard: some View {
        card(title: "Scan Setup", icon: "waveform.path.ecg") {
            Picker("Mode", selection: scanModeBinding) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if scanModeBinding.wrappedValue == .fullDisk {
                Label(
                    "Full disk scan may be slow and may require Full Disk Access in macOS Privacy settings.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.orange)

                HStack(spacing: 8) {
                    statusBadge(
                        text: viewModel.hasFullDiskAccess ? "Full Disk Access: Granted" : "Full Disk Access: Missing",
                        color: viewModel.hasFullDiskAccess ? .green : .orange
                    )

                    Spacer(minLength: 6)

                    Button("Open Settings") {
                        viewModel.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isScanning || viewModel.isCleaning)

                    Button("Check Again") {
                        viewModel.refreshFullDiskAccessStatus()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isScanning || viewModel.isCleaning)
                }
            }

            if scanModeBinding.wrappedValue == .custom {
                Text("Custom paths (one per line or comma-separated)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                TextEditor(text: $viewModel.customPathsText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(height: 100)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.startScan()
                } label: {
                    Label("Start Scan", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isScanning)

                Spacer(minLength: 8)

                Button {
                    viewModel.refreshRecommendations()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.latestSessionID == nil || viewModel.isLoadingRecommendations)
            }
        }
    }

    private var statusCard: some View {
        card(title: "Scan Status", icon: "speedometer") {
            Text(viewModel.statusText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            if viewModel.isScanning {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Preview recommendations auto-refresh during scanning. Duplicate analysis runs after scan completion to keep memory usage lower.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            statRow(label: "Scanned files", value: "\(viewModel.scannedCount)")
            statRow(label: "Scanned size", value: ByteFormatting.string(from: viewModel.scannedBytes))

            if !viewModel.currentPath.isEmpty {
                statRow(label: "Current path", value: viewModel.currentPath, secondary: true)
            }
            if let sessionID = viewModel.latestSessionID {
                statRow(label: "Session", value: sessionID.uuidString, secondary: true)
            }
            if let jobID = viewModel.latestCleanupJobID {
                statRow(label: "Last cleanup", value: jobID.uuidString, secondary: true)
            }
            if !viewModel.lastExportedReportPath.isEmpty {
                statRow(label: "Last report", value: viewModel.lastExportedReportPath, secondary: true)
            }
        }
    }

    private var summaryCard: some View {
        card(title: "Recommendation Summary", icon: "chart.bar.xaxis") {
            ForEach(CandidateType.displayTypes, id: \.self) { type in
                let summary = viewModel.candidateSummaries[type] ?? CandidateSummary(type: type, count: 0, totalBytes: 0)
                let selected = viewModel.selectedCount(for: type)

                HStack(spacing: 8) {
                    Circle()
                        .fill(type.tint.opacity(0.85))
                        .frame(width: 8, height: 8)
                    Text(type.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(summary.count) files")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("selected \(selected)")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(ByteFormatting.string(from: summary.totalBytes))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var overviewStrip: some View {
        HStack(spacing: 10) {
            metricTile(
                title: "Scanned Size",
                value: ByteFormatting.string(from: viewModel.scannedBytes),
                subtitle: "\(viewModel.scannedCount) files"
            )
            metricTile(
                title: "Selected Files",
                value: "\(viewModel.totalSelectedCount())",
                subtitle: "ready for cleanup"
            )
            metricTile(
                title: "Last Cleanup",
                value: viewModel.latestCleanupJobID?.uuidString.prefix(8).description ?? "N/A",
                subtitle: "job id"
            )
            metricTile(
                title: "Mode",
                value: activeScanModeLabel,
                subtitle: isBusy ? "working" : "idle"
            )
        }
    }

    private var candidatesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            candidateControlsCard

            VSplitView {
                candidateListCard
                topDirectoryCard
                    .frame(minHeight: 160, idealHeight: 220, maxHeight: 280)
            }
        }
    }

    private var candidateControlsCard: some View {
        card(title: "Candidate Controls", icon: "slider.horizontal.3") {
            HStack(spacing: 10) {
                Picker("Candidate Type", selection: $viewModel.selectedCandidateType) {
                    ForEach(CandidateType.displayTypes, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                Spacer()

                statusBadge(
                    text: "Selected \(viewModel.selectedCount(for: viewModel.selectedCandidateType))",
                    color: .accentColor
                )
            }

            HStack(spacing: 10) {
                TextField("Filter by path or reason", text: $viewModel.candidateSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)

                Picker("Sort", selection: $viewModel.candidateSortOption) {
                    ForEach(CandidateSortOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                Stepper(
                    "Min size: \(Int(viewModel.minCandidateSizeMB)) MB",
                    value: $viewModel.minCandidateSizeMB,
                    in: 0...20_000,
                    step: 50
                )
                .frame(minWidth: 220)

                Spacer()
            }

            HStack(spacing: 8) {
                Menu {
                    Button("Select Recommended") { viewModel.selectDefaultCurrentType() }
                    Button("Select All Filtered") { viewModel.selectAllCurrentType() }
                    Button("Clear Selection") { viewModel.clearSelectionCurrentType() }
                } label: {
                    Label("Selection", systemImage: "checklist.checked")
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button {
                    viewModel.cleanupSelectedType()
                } label: {
                    Label("Cleanup Selected Type", systemImage: "trash.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedCount(for: viewModel.selectedCandidateType) == 0 || viewModel.isScanning || viewModel.isCleaning)

                Button {
                    viewModel.cleanupAllTypes()
                } label: {
                    Label("Cleanup All Selected", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.totalSelectedCount() == 0 || viewModel.isScanning || viewModel.isCleaning)
            }
        }
    }

    private var candidateListCard: some View {
        card(title: "Candidates", icon: "doc.text.magnifyingglass") {
            let items = viewModel.filteredCandidatesForSelectedType()

            if items.isEmpty {
                placeholderCardText(
                    title: "No candidates for current filters",
                    subtitle: "Adjust candidate type, search query, or min size."
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                List(items, id: \.id) { item in
                    candidateRow(item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func candidateRow(_ item: CleanupCandidate) -> some View {
        let hint = viewModel.deletionHint(for: item)
        let isSelected = viewModel.isCandidateSelected(item)

        return HStack(alignment: .top, spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.isCandidateSelected(item) },
                    set: { viewModel.setCandidateSelected(item, selected: $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(ByteFormatting.string(from: item.estimatedBytes))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))

                    Text(item.reason)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()
                }

                HStack(spacing: 6) {
                    Text(hint.level.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(hint.level.color.opacity(0.16))
                        .foregroundStyle(hint.level.color)
                        .clipShape(Capsule())

                    Text(hint.info)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(item.filePath)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)

                Text(hint.advice)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var topDirectoryCard: some View {
        card(title: "Top Directories", icon: "folder.badge.gearshape") {
            if viewModel.topDirectories.isEmpty {
                placeholderCardText(
                    title: "No directory usage data yet",
                    subtitle: "Run a scan to load directory hotspots."
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(Array(viewModel.topDirectories.enumerated()), id: \.element.parentPath) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("#\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.parentPath)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .lineLimit(1)
                            Text("\(item.fileCount) files")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteFormatting.string(from: item.bytes))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            historyControlsCard

            HSplitView {
                historyJobsCard
                    .frame(minWidth: 430)
                failedItemsCard
            }
        }
    }

    private var historyControlsCard: some View {
        card(title: "History Controls", icon: "clock.badge.checkmark") {
            HStack(spacing: 8) {
                TextField(
                    "Search: rank:recency status:failed path:cache",
                    text: $viewModel.historySearchQuery
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 300)

                Picker("Ranking", selection: $viewModel.historyRankingProfile) {
                    ForEach(HistoryRankingProfileOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)

                Button("Apply") { viewModel.applyHistorySearch() }
                    .buttonStyle(.bordered)
                Button("Clear") { viewModel.clearHistorySearch() }
                    .buttonStyle(.bordered)
                Button("Query Help") { showingHistoryQueryHelp = true }
                    .buttonStyle(.bordered)

                Spacer()
            }

            HStack(spacing: 8) {
                Button("Prev") { viewModel.previousHistoryPage() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.historyPageIndex == 0)

                Text("Page \(viewModel.historyPageIndex + 1)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Button("Next") { viewModel.nextHistoryPage() }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasNextHistoryPage)

                Button("Refresh") { viewModel.refreshHistory() }
                    .buttonStyle(.bordered)

                Spacer()

                Picker("Format", selection: $viewModel.reportExportFormat) {
                    ForEach(ReportFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Button("Export Report") { viewModel.exportSelectedJobReport() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.selectedHistoryJobID == nil)

                Button("Retry Failed (Job)") { viewModel.retryFailedForSelectedJob() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedHistoryJobID == nil || viewModel.failedItemsForSelectedJob.isEmpty || viewModel.isCleaning)
            }
        }
    }

    private var historyJobsCard: some View {
        card(title: "Cleanup Jobs", icon: "list.bullet.rectangle.portrait") {
            if viewModel.cleanupJobs.isEmpty {
                placeholderCardText(
                    title: "No cleanup jobs",
                    subtitle: "Run cleanup actions to populate job history."
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                List(viewModel.cleanupJobs, id: \.jobID) { job in
                    Button {
                        viewModel.selectHistoryJob(job.jobID)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                statusBadge(text: job.status.displayName, color: job.status.color)
                                Spacer()
                                Text(ByteFormatting.string(from: job.reclaimedBytes))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }

                            Text(job.jobID.uuidString)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text("succ=\(job.successCount) fail=\(job.failCount) | \(job.startedAt, formatter: Self.jobDateFormatter)")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(viewModel.selectedHistoryJobID == job.jobID ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }

    private var failedItemsCard: some View {
        card(title: "Failed Items", icon: "exclamationmark.triangle.fill") {
            HStack(spacing: 8) {
                statusBadge(text: "Selected \(viewModel.selectedFailedItemPaths.count)", color: .orange)
                Spacer()
                Button("Select All") { viewModel.selectAllFailedItems() }
                    .buttonStyle(.bordered)
                Button("Clear") { viewModel.clearFailedSelection() }
                    .buttonStyle(.bordered)
                Button("Retry Selected") { viewModel.retrySelectedFailedItemsForSelectedJob() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedHistoryJobID == nil || viewModel.selectedFailedItemPaths.isEmpty || viewModel.isCleaning)
            }

            if viewModel.failedItemsForSelectedJob.isEmpty {
                placeholderCardText(
                    title: "No failed items",
                    subtitle: "Selected job has no failed files."
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
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

                        VStack(alignment: .leading, spacing: 3) {
                            Text(ByteFormatting.string(from: item.estimatedBytes))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(item.filePath)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)

                            if let error = item.errorMessage, !error.isEmpty {
                                Text(error)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }

    private var historyQueryHelpSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("History Query Syntax")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Group {
                Text("Basic operators")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("`id:` `job:` `session:` `status:` `action:` `path:` `file:` `error:` `err:` `result:`")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)

                Text("Regex operators")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("`re:` `id_re:` `session_re:` `status_re:` `action_re:` `path_re:` `file_re:` `error_re:` `result_re:`")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                Text("`regex_case:sensitive|insensitive` `regex_dotall:true|false`")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)

                Text("Ranking")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("`rank:balanced|recency|path`")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)

                Text("Examples")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("`status:failed path:cache`")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                Text("`path_re:temp-.*-a\\\\.log`")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Close") {
                    showingHistoryQueryHelp = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 700, height: 460)
    }

    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func metricTile(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func statRow(label: String, value: String, secondary: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: secondary ? .monospaced : .rounded))
                .foregroundStyle(secondary ? .secondary : .primary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func placeholderCardText(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    private var sidebarBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var detailBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor).opacity(0.95),
                Color(nsColor: .controlBackgroundColor).opacity(0.65)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var scanModeBinding: Binding<ScanMode> {
        Binding {
            if viewModel.useFullDiskScan {
                return .fullDisk
            }
            if viewModel.useQuickScan {
                return .quick
            }
            return .custom
        } set: { mode in
            switch mode {
            case .quick:
                viewModel.useQuickScan = true
                viewModel.useFullDiskScan = false
            case .fullDisk:
                viewModel.useFullDiskScan = true
                viewModel.useQuickScan = false
            case .custom:
                viewModel.useQuickScan = false
                viewModel.useFullDiskScan = false
            }
        }
    }

    private var isBusy: Bool {
        viewModel.isScanning || viewModel.isCleaning || viewModel.isLoadingRecommendations
    }

    private var activeScanModeLabel: String {
        if viewModel.useFullDiskScan {
            return "Full Disk"
        }
        if viewModel.useQuickScan {
            return "Quick"
        }
        return "Custom"
    }

    private static let jobDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum ScanMode: String, CaseIterable, Identifiable {
    case quick
    case fullDisk
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick:
            return "Quick"
        case .fullDisk:
            return "Full Disk"
        case .custom:
            return "Custom"
        }
    }
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

    var tint: Color {
        switch self {
        case .cache:
            return .blue
        case .duplicate:
            return .green
        case .largeFile:
            return .orange
        case .oldDownload:
            return .purple
        case .installerPackage:
            return .mint
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

extension DeletionSafetyLevel {
    var color: Color {
        switch self {
        case .safe:
            return .green
        case .caution:
            return .orange
        case .review:
            return .red
        }
    }
}
