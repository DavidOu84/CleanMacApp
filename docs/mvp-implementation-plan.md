# CleanMacApp 下一步实施方案（个人自用版）

## 1. 范围说明
- 目标：基于现有 PRD/架构文档，输出可直接开工的工程结构、核心接口和首批开发任务。
- 约束：先不考虑分发渠道（App Store/官网签名流程），以“本机可运行验证效果”为第一优先级。
- 平台：macOS 13+，Xcode 16+，Swift 5.10+。

## 2. 自用版技术策略（与分发版差异）
1. 先做非沙箱本机调试能力，优先保证扫描和清理效果。
2. 先依赖用户手动授权“Full Disk Access”（系统设置）做完整扫描验证。
3. 清理能力保持保守：MVP 只支持“Move to Trash”。
4. 遥测、账号系统、在线配置全部不做。

## 3. 建议工程目录结构
```text
CleanMacApp/
  App/
    CleanMacAppApp.swift
    AppBootstrap.swift
  Features/
    Dashboard/
      DashboardView.swift
      DashboardViewModel.swift
    Scan/
      ScanView.swift
      ScanViewModel.swift
    Candidates/
      CandidatesView.swift
      CandidatesViewModel.swift
    Cleanup/
      CleanupConfirmView.swift
      CleanupViewModel.swift
    History/
      HistoryView.swift
      HistoryViewModel.swift
    Settings/
      SettingsView.swift
      SettingsViewModel.swift
  Domain/
    Models/
      FileItem.swift
      ScanSession.swift
      CleanupCandidate.swift
      CleanupJob.swift
      AppSetting.swift
    Services/
      ScanEngine.swift
      DuplicateDetector.swift
      RecommendationService.swift
      CleanupService.swift
      AuditService.swift
    Rules/
      RuleSet.swift
      CategoryRule.swift
      RiskRule.swift
  Application/
    UseCases/
      StartScanUseCase.swift
      BuildCandidatesUseCase.swift
      ExecuteCleanupUseCase.swift
      LoadDashboardUseCase.swift
    DTOs/
      ScanProgressDTO.swift
      CleanupSummaryDTO.swift
    Mappers/
      ErrorMapper.swift
  Infrastructure/
    Persistence/
      SQLite/
        Database.swift
        Migrations.swift
        Repositories/
          FileIndexRepository.swift
          CandidateRepository.swift
          HistoryRepository.swift
          SettingsRepository.swift
    FileSystem/
      FileSystemAdapter.swift
      BookmarkStore.swift
    Security/
      PermissionManager.swift
    Concurrency/
      TaskScheduler.swift
  Shared/
    Components/
    Extensions/
    Utils/
      Logger.swift
      ByteFormatter.swift
      DateFormatterPool.swift
  Tests/
    Unit/
    Integration/
    Performance/
  docs/
    mac-storage-cleaner-prd.md
    mac-storage-cleaner-architecture.md
    mvp-implementation-plan.md
```

## 4. 依赖方向（必须遵守）
1. `Features` 只依赖 `Application` 和 `Domain.Models`。
2. `Application` 依赖 `Domain` 抽象协议，不直接依赖 `SQLite`/`FileManager`。
3. `Infrastructure` 实现 `Domain/Application` 定义的协议。
4. `Domain` 不依赖 UI 和具体基础设施。

## 5. 核心协议接口（第一版）
下面接口建议先落地成协议，再由 `Infrastructure` 提供实现。

```swift
import Foundation

public typealias ScanSessionID = UUID
public typealias CandidateID = UUID
public typealias CleanupJobID = UUID

public struct ScanScope: Sendable {
    public let roots: [URL]
    public let isQuickMode: Bool
}

public enum ScanStatus: Sendable {
    case idle
    case running
    case finished
    case failed(String)
    case cancelled
}

public struct ScanProgress: Sendable {
    public let sessionID: ScanSessionID
    public let scannedCount: Int
    public let totalBytes: Int64
    public let currentPath: String
    public let percent: Double
}

public protocol ScanUseCase {
    func start(scope: ScanScope) async throws -> ScanSessionID
    func cancel(sessionID: ScanSessionID) async
    func progressStream(sessionID: ScanSessionID) -> AsyncStream<ScanProgress>
}

public enum CandidateType: String, Sendable {
    case largeFile
    case duplicate
    case cache
    case oldDownload
    case installerPackage
}

public enum RiskLevel: String, Sendable {
    case low
    case medium
    case high
}

public struct CleanupCandidate: Identifiable, Sendable {
    public let id: CandidateID
    public let filePath: String
    public let estimatedBytes: Int64
    public let type: CandidateType
    public let reason: String
    public let risk: RiskLevel
    public let selectedByDefault: Bool
}

public protocol RecommendationUseCase {
    func build(sessionID: ScanSessionID) async throws
    func list(sessionID: ScanSessionID, type: CandidateType) async throws -> [CleanupCandidate]
}

public enum CleanupAction: String, Sendable {
    case moveToTrash
}

public struct CleanupSummary: Sendable {
    public let jobID: CleanupJobID
    public let successCount: Int
    public let failCount: Int
    public let reclaimedBytes: Int64
}

public protocol CleanupUseCase {
    func execute(
        sessionID: ScanSessionID,
        candidateIDs: [CandidateID],
        action: CleanupAction
    ) async throws -> CleanupSummary

    func retryFailed(jobID: CleanupJobID) async throws -> CleanupSummary
}
```

```swift
import Foundation

public struct FileMetadata: Sendable {
    public let path: String
    public let size: Int64
    public let modifiedAt: Date
    public let accessedAt: Date?
    public let isDirectory: Bool
    public let fileExtension: String
    public let inode: UInt64?
}

public protocol FileSystemAdapter {
    func enumerate(at roots: [URL]) -> AsyncThrowingStream<FileMetadata, Error>
    func computeQuickHash(of path: String) async throws -> String
    func computeFullHash(of path: String) async throws -> String
    func moveToTrash(paths: [String]) async -> [String: Error]
    func fileExists(_ path: String) -> Bool
}

public protocol PermissionManager {
    func requestAccessIfNeeded(for roots: [URL]) async -> Bool
    func hasAccess(to path: String) -> Bool
}
```

## 6. 数据库最小落地（MVP 必要表）
1. `scan_session`
2. `file_index`
3. `cleanup_candidate`
4. `cleanup_job`
5. `cleanup_result`
6. `app_setting`

说明：`duplicate_group/duplicate_item` 可以在第 2 周引入，第一周先把大文件与缓存链路打通。

## 7. 4 周首批任务拆解（可执行）
## 第 1 周：骨架与扫描闭环
1. 建立工程目录、模块分组、基础日志组件。
2. 实现 `ScanUseCase` + `FileSystemAdapter.enumerate`。
3. 完成 `scan_session`、`file_index` 建表和写入。
4. UI 显示扫描进度（路径、百分比、文件数）。
5. 验收：可扫描快速目录并在 UI 显示 Top 占用目录。

## 第 2 周：候选生成（大文件 + 缓存）
1. 实现 `RecommendationUseCase.build/list`。
2. 落地大文件阈值规则和缓存目录规则。
3. 候选列表支持筛选、排序、勾选状态持久化。
4. 实现清理确认弹窗（预计释放空间、风险提示）。
5. 验收：可稳定生成候选并完成手动勾选。

## 第 3 周：清理执行与历史
1. 实现 `CleanupUseCase.execute/retryFailed`。
2. 接入 `moveToTrash`，记录 `cleanup_job/cleanup_result`。
3. 历史页展示每次释放空间、失败项原因。
4. 处理典型失败：权限不足、文件占用、已删除。
5. 验收：完成扫描 -> 建议 -> 清理 -> 历史闭环。

## 第 4 周：重复文件与性能优化
1. 实现两阶段重复检测（size bucket -> hash confirm）。
2. 增加增量扫描（按 mtime/size/inode 变化过滤）。
3. 引入批量写库和并发限流，优化耗时。
4. 加入性能与稳定性测试脚本。
5. 验收：快速扫描 <2 分钟；重复检测可在常见用户目录完成。

## 8. 每周交付物定义
1. 可运行版本（本机直接打开运行）。
2. 对应数据库迁移脚本和回滚说明。
3. 最少 5 个单元测试 + 1 个集成测试。
4. 已知问题清单（风险、复现步骤、临时规避方案）。

## 9. 开工顺序建议（今天就能做）
1. 先建空壳工程和模块目录。
2. 先做扫描与索引，不等待完整 UI。
3. 扫描可跑通后再接候选和清理页面。
4. 每个 UseCase 都先写协议和 Mock，再接真实实现。

## 10. 本轮需你确认的两个参数
1. 大文件默认阈值是否定为 `500MB`（PRD 默认值）。
2. 快速扫描目录是否定为：`Desktop/Documents/Downloads/Library/Caches`。
