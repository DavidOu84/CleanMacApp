import Foundation

public struct DefaultRecommendationUseCase: RecommendationUseCase {
    private let fileSystem: FileSystemAdapter
    private let store: ScanSessionStore

    public init(fileSystem: FileSystemAdapter, store: ScanSessionStore) {
        self.fileSystem = fileSystem
        self.store = store
    }

    public func build(sessionID: ScanSessionID, rules: RecommendationRules) async throws {
        try await buildLargeFileCandidates(sessionID: sessionID, rules: rules)
        try await buildCacheCandidates(sessionID: sessionID, rules: rules)
        try await buildDuplicateCandidates(sessionID: sessionID, rules: rules)
    }

    public func list(sessionID: ScanSessionID, type: CandidateType, limit: Int) async throws -> [CleanupCandidate] {
        try await store.fetchCandidates(sessionID: sessionID, type: type, limit: limit)
    }

    public func summary(sessionID: ScanSessionID, type: CandidateType) async throws -> CandidateSummary {
        try await store.fetchCandidateSummary(sessionID: sessionID, type: type)
    }

    private func buildLargeFileCandidates(sessionID: ScanSessionID, rules: RecommendationRules) async throws {
        let largeFiles = try await store.fetchLargeFileRecords(
            sessionID: sessionID,
            minSizeBytes: rules.largeFileThresholdBytes,
            limit: rules.maxCandidatesPerType
        )

        let candidates = largeFiles.map { file in
            CleanupCandidate(
                sessionID: sessionID,
                filePath: file.path,
                estimatedBytes: file.sizeBytes,
                type: .largeFile,
                reason: "File size >= \(ByteFormatting.string(from: rules.largeFileThresholdBytes))",
                risk: .medium,
                selectedByDefault: false
            )
        }

        try await store.replaceCandidates(sessionID: sessionID, type: .largeFile, candidates: candidates)
    }

    private func buildCacheCandidates(sessionID: ScanSessionID, rules: RecommendationRules) async throws {
        let cacheFiles = try await store.fetchCacheFileRecords(
            sessionID: sessionID,
            limit: rules.maxCandidatesPerType
        )

        let candidates = cacheFiles.map { file in
            CleanupCandidate(
                sessionID: sessionID,
                filePath: file.path,
                estimatedBytes: file.sizeBytes,
                type: .cache,
                reason: "Located under Library/Caches",
                risk: .low,
                selectedByDefault: true
            )
        }

        try await store.replaceCandidates(sessionID: sessionID, type: .cache, candidates: candidates)
    }

    private func buildDuplicateCandidates(sessionID: ScanSessionID, rules: RecommendationRules) async throws {
        let buckets = try await store.fetchDuplicateSizeBuckets(
            sessionID: sessionID,
            minSizeBytes: rules.duplicateMinSizeBytes,
            limit: rules.maxDuplicateBuckets
        )

        var candidates: [CleanupCandidate] = []
        var addedPaths = Set<String>()

        for bucket in buckets {
            if candidates.count >= rules.maxCandidatesPerType {
                break
            }

            let records = try await store.fetchFileRecords(
                sessionID: sessionID,
                exactSizeBytes: bucket.sizeBytes,
                limit: rules.maxFilesPerDuplicateBucket
            )
            if records.count < 2 {
                continue
            }

            var quickHashGroups: [String: [IndexedFileRecord]] = [:]
            for record in records {
                if candidates.count >= rules.maxCandidatesPerType {
                    break
                }
                if !fileSystem.fileExists(record.path) {
                    continue
                }

                let quickHash: String
                do {
                    quickHash = try await fileSystem.computeQuickHash(of: record.path)
                } catch {
                    continue
                }
                quickHashGroups[quickHash, default: []].append(record)
            }

            for quickGroup in quickHashGroups.values where quickGroup.count >= 2 {
                if candidates.count >= rules.maxCandidatesPerType {
                    break
                }

                var fullHashGroups: [String: [IndexedFileRecord]] = [:]
                for record in quickGroup {
                    if !fileSystem.fileExists(record.path) {
                        continue
                    }

                    let fullHash: String
                    do {
                        fullHash = try await fileSystem.computeFullHash(of: record.path)
                    } catch {
                        continue
                    }
                    fullHashGroups[fullHash, default: []].append(record)
                }

                for fullGroup in fullHashGroups.values where fullGroup.count >= 2 {
                    if candidates.count >= rules.maxCandidatesPerType {
                        break
                    }

                    let sorted = fullGroup.sorted { lhs, rhs in
                        lhs.modifiedAt > rhs.modifiedAt
                    }

                    guard let keep = sorted.first else {
                        continue
                    }

                    if !addedPaths.contains(keep.path), candidates.count < rules.maxCandidatesPerType {
                        addedPaths.insert(keep.path)
                        candidates.append(
                            CleanupCandidate(
                                sessionID: sessionID,
                                filePath: keep.path,
                                estimatedBytes: keep.sizeBytes,
                                type: .duplicate,
                                reason: "Keep copy (recommended) for duplicate group",
                                risk: .high,
                                selectedByDefault: false
                            )
                        )
                    }

                    for duplicate in sorted.dropFirst() {
                        if candidates.count >= rules.maxCandidatesPerType {
                            break
                        }
                        if addedPaths.contains(duplicate.path) {
                            continue
                        }

                        addedPaths.insert(duplicate.path)
                        candidates.append(
                            CleanupCandidate(
                                sessionID: sessionID,
                                filePath: duplicate.path,
                                estimatedBytes: duplicate.sizeBytes,
                                type: .duplicate,
                                reason: "Duplicate of \(keep.path)",
                                risk: .low,
                                selectedByDefault: true
                            )
                        )
                    }
                }
            }
        }

        try await store.replaceCandidates(sessionID: sessionID, type: .duplicate, candidates: candidates)
    }
}
