#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_BIN="$ROOT_DIR/.build/debug/cleanmacapp-cli"
DATASET_DIR="${1:-$HOME/Downloads/CleanMacBenchmarkData}"
REPORT_DIR="${2:-$ROOT_DIR/reports}"

FILE_COUNT="${FILE_COUNT:-6000}"
FILE_SIZE_KB="${FILE_SIZE_KB:-32}"
MODIFY_COUNT="${MODIFY_COUNT:-300}"
DELETE_COUNT="${DELETE_COUNT:-200}"
ADD_COUNT="${ADD_COUNT:-250}"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift command not found" >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"

echo "[1/6] Building project..."
(
  cd "$ROOT_DIR"
  swift build >/dev/null
)

if [[ ! -x "$CLI_BIN" ]]; then
  echo "CLI binary not found: $CLI_BIN" >&2
  exit 1
fi

run_swift_code() {
  local code="$1"
  swift -e "$code"
}

generate_dataset() {
  echo "[2/6] Generating dataset in $DATASET_DIR"
  run_swift_code "
import Foundation
let fm = FileManager.default
let root = URL(fileURLWithPath: \"$DATASET_DIR\", isDirectory: true)
try? fm.removeItem(at: root)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let fileCount = $FILE_COUNT
let chunkSize = $FILE_SIZE_KB * 1024
for i in 0..<fileCount {
    let folder = root.appendingPathComponent(String(format: \"bucket-%03d\", i % 40), isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(String(format: \"file-%05d.dat\", i))
    let byte = UInt8(i % 251)
    let data = Data(repeating: byte, count: chunkSize)
    try data.write(to: file)
}
"
}

mutate_dataset() {
  echo "[4/6] Mutating dataset (modify=$MODIFY_COUNT delete=$DELETE_COUNT add=$ADD_COUNT)"
  run_swift_code "
import Foundation
let fm = FileManager.default
let root = URL(fileURLWithPath: \"$DATASET_DIR\", isDirectory: true)
let modifyCount = $MODIFY_COUNT
let deleteCount = $DELETE_COUNT
let addCount = $ADD_COUNT

var files: [URL] = []
if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: nil) {
    for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files.append(url)
        }
    }
}
files.sort { \$0.path < \$1.path }

for file in files.prefix(deleteCount) {
    try? fm.removeItem(at: file)
}

let modifier = Data(repeating: 0xAB, count: 512)
for file in files.dropFirst(deleteCount).prefix(modifyCount) {
    if let handle = try? FileHandle(forWritingTo: file) {
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: modifier)
        try? handle.close()
    }
}

let start = files.count
for i in 0..<addCount {
    let folder = root.appendingPathComponent(String(format: \"bucket-new-%02d\", i % 10), isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(String(format: \"new-%05d.dat\", start + i))
    let data = Data(repeating: UInt8((i + 17) % 253), count: 16 * 1024)
    try? data.write(to: file)
}
"
}

run_scan_timed() {
  local label="$1"
  local out_file time_file
  out_file="$(mktemp)"
  time_file="$(mktemp)"

  {
    /usr/bin/time -p "$CLI_BIN" "$DATASET_DIR" >"$out_file"
  } 2>"$time_file"

  local real
  real="$(awk '/^real /{print $2}' "$time_file")"
  local scan_line
  scan_line="$(awk '/^Scan completed:/{print; exit}' "$out_file")"

  local files bytes
  if [[ -n "$scan_line" ]]; then
    files="$(echo "$scan_line" | sed -E 's/.*Scan completed: ([0-9]+) files.*/\1/')"
    bytes="$(echo "$scan_line" | sed -E 's/.*files, (.*)$/\1/')"
  else
    files="0"
    bytes="Unknown"
  fi

  echo "$label|$real|$files|$bytes"
}

pct_drop() {
  local base="$1"
  local target="$2"
  awk -v a="$base" -v b="$target" 'BEGIN { if (a <= 0) { print "0.00" } else { printf "%.2f", ((a-b)/a)*100 } }'
}

write_report() {
  local full_real="$1"
  local inc_real="$2"
  local steady_real="$3"
  local full_files="$4"
  local inc_files="$5"
  local steady_files="$6"
  local full_human="$7"
  local inc_human="$8"
  local steady_human="$9"

  local ts report_file
  ts="$(date +%Y%m%d-%H%M%S)"
  report_file="$REPORT_DIR/benchmark-scan-$ts.md"

  local improve_inc improve_steady
  improve_inc="$(pct_drop "$full_real" "$inc_real")"
  improve_steady="$(pct_drop "$full_real" "$steady_real")"

  cat >"$report_file" <<MARKDOWN
# CleanMacApp Scan Benchmark

## Dataset

- Path: $DATASET_DIR
- Initial file count: $FILE_COUNT
- Initial file size: ${FILE_SIZE_KB} KB

## Mutation

- Modified files: $MODIFY_COUNT
- Deleted files: $DELETE_COUNT
- Added files: $ADD_COUNT

## Results

| Run | Time (s) | Files | Scanned Size |
|---|---:|---:|---|
| Full scan (baseline) | $full_real | $full_files | $full_human |
| Incremental scan (after mutation) | $inc_real | $inc_files | $inc_human |
| Incremental scan (steady state) | $steady_real | $steady_files | $steady_human |

## Deltas

- Incremental vs full: $improve_inc% faster
- Steady vs full: $improve_steady% faster

## Notes

- Timings include scan + recommendation generation in CLI.
- Results vary with disk speed, cache state, and background load.
MARKDOWN

  echo "$report_file"
}

generate_dataset

echo "[3/6] Running baseline full scan..."
full_raw="$(run_scan_timed "full")"
IFS='|' read -r _ full_real full_files full_human <<<"$full_raw"

mutate_dataset

echo "[5/6] Running incremental scans..."
inc_raw="$(run_scan_timed "incremental")"
steady_raw="$(run_scan_timed "steady")"
IFS='|' read -r _ inc_real inc_files inc_human <<<"$inc_raw"
IFS='|' read -r _ steady_real steady_files steady_human <<<"$steady_raw"

echo "[6/6] Writing report..."
report_path="$(write_report "$full_real" "$inc_real" "$steady_real" "$full_files" "$inc_files" "$steady_files" "$full_human" "$inc_human" "$steady_human")"

echo "Benchmark report generated: $report_path"
