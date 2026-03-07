# CleanMacApp (MVP Coding Start)

This repository now contains the first runnable implementation slice for the mac storage cleaner:

- Swift Package project
- Core scan/index pipeline
- SQLite-based session and file index storage
- Recommendation generation (large files + cache files + duplicate files)
- CLI prototype for local validation
- SwiftUI desktop shell (scan + candidate checkbox selection + cleanup history)

## What is implemented

- Quick scan scope defaults to:
  - `~/Desktop`
  - `~/Documents`
  - `~/Downloads`
  - `~/Library/Caches`
- Scan session lifecycle:
  - create session
  - incremental baseline reuse (clone last finished scope + update changed files + remove deleted files)
  - stream progress
  - persist file metadata
  - mark session finished/failed/cancelled
- Directory usage aggregation (`Top N` by total file size)
- Recommendation candidates:
  - large files (`>= 500MB`)
  - cache files (`.../Library/Caches/...`)
  - duplicate files (size bucket + quick hash + full hash)
- Candidate summary and Top N candidate listing in CLI
- Cleanup execution:
  - move selected candidates to Trash
  - persist cleanup jobs and per-file cleanup results
- Desktop UI features:
  - candidate filtering (query + min size) and sorting
  - per-type filter presets persisted in `UserDefaults`
  - cleanup history pagination + search (job fields + file path + error message, FTS indexed + relevance/recency ranking + ranking profile picker)
  - retry failed items by whole job or selected file paths
  - export cleanup job report in markdown/json/csv
- Local SQLite DB in `~/.cleanmacapp/cleanmacapp.sqlite`

## Build

```bash
swift build
```

## Run

Quick mode (default):

```bash
.build/debug/cleanmacapp-cli
```

Custom path mode:

```bash
.build/debug/cleanmacapp-cli /path/to/scan
```

Scan + cleanup cache candidates:

```bash
.build/debug/cleanmacapp-cli ~/Library/Caches --cleanup-cache
```

Scan + cleanup large-file and cache candidates:

```bash
.build/debug/cleanmacapp-cli ~/Downloads --cleanup-all
```

Scan + cleanup duplicate candidates:

```bash
.build/debug/cleanmacapp-cli ~/Downloads --cleanup-duplicate
```

Desktop app shell:

```bash
.build/debug/cleanmacapp-desktop
```

Export a cleanup report by job id:

```bash
.build/debug/cleanmacapp-cli --export-job <JOB_ID>
```

Choose export format:

```bash
.build/debug/cleanmacapp-cli --export-job <JOB_ID> --export-format json
.build/debug/cleanmacapp-cli --export-job <JOB_ID> --export-format csv
```

Search cleanup history from CLI:

```bash
.build/debug/cleanmacapp-cli --history-search "status:failed path:cache"
.build/debug/cleanmacapp-cli --history-search "path:tmpflea~" --history-limit 30
.build/debug/cleanmacapp-cli --history-search "path_re:temp-.*-a\\.log"
.build/debug/cleanmacapp-cli --history-search "re:cache.*\\.bin"
.build/debug/cleanmacapp-cli --history-search "rank:recency status:finished path:cache"
.build/debug/cleanmacapp-cli --history-search "regex_case:sensitive path_re:Cache.*\\.bin"
```

History query syntax:
- operators: `id:`, `job:`, `session:`, `status:`, `action:`, `path:`, `file:`, `error:`, `err:`, `result:`
- regex operators: `re:`, `id_re:`, `session_re:`, `status_re:`, `action_re:`, `path_re:`, `file_re:`, `error_re:`, `result_re:`
- regex flags: `regex_case:sensitive|insensitive`, `regex_dotall:true|false`
- ranking operator: `rank:balanced|recency|path`
- quoted value: `path:"Library/Caches/app-cache"`
- fuzzy match: suffix `~`, e.g. `path:tmpflea~` (translated to wildcard-like fuzzy matching)
- regex value: `path_re:temp-.*-a\\.log` or global `re:cache.*\\.bin`
- mixed query: `action:movetotrash status:finished path:cache`

Run scan performance benchmark:

```bash
./scripts/benchmark_scan.sh
```

Run large-dataset benchmark matrix + trend tracking:

```bash
./scripts/benchmark_matrix.sh
```

Compare candidate matrix against baseline:

```bash
./scripts/benchmark_compare.sh <baseline_matrix_csv> <candidate_matrix_csv>
```

Run one-command release baseline comparison:

```bash
./scripts/benchmark_release_compare.sh <baseline_matrix_csv>
```

Benchmark details:
- `docs/performance-benchmark.md`

## Current limitations

- SwiftUI shell currently lacks per-file preview pane and richer filtering operators (regex, extension include/exclude).
- History search regex currently supports case and dotall flags, but does not expose full inline regex flag syntax.
- Automated tests are temporarily not wired because this machine currently has Command Line Tools only (no full Xcode test frameworks available).

## Next coding step

- Add full inline regex flag syntax (e.g. `/pattern/im`) for history search.
- Re-enable automated test suites once full Xcode testing runtime is available.
