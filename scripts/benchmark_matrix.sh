#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_SCRIPT="$ROOT_DIR/scripts/benchmark_scan.sh"
REPORT_DIR="${1:-$ROOT_DIR/reports}"
DATASET_ROOT="${2:-$HOME/Downloads/CleanMacBenchmarkMatrix}"
PROFILE="${PROFILE:-balanced}"
LEVELS="${LEVELS:-}"
FILE_SIZE_KB="${FILE_SIZE_KB:-}"
MODIFY_RATIO_PERCENT="${MODIFY_RATIO_PERCENT:-}"
DELETE_RATIO_PERCENT="${DELETE_RATIO_PERCENT:-}"
ADD_RATIO_PERCENT="${ADD_RATIO_PERCENT:-}"

mkdir -p "$REPORT_DIR"
mkdir -p "$DATASET_ROOT"

if [[ ! -x "$BENCH_SCRIPT" ]]; then
  echo "benchmark script not executable: $BENCH_SCRIPT" >&2
  exit 1
fi

set_if_empty() {
  local variable_name="$1"
  local value="$2"
  if [[ -z "${!variable_name}" ]]; then
    printf -v "$variable_name" "%s" "$value"
  fi
}

case "$PROFILE" in
  quick-smoke)
    set_if_empty LEVELS "1000 3000"
    set_if_empty FILE_SIZE_KB "8"
    set_if_empty MODIFY_RATIO_PERCENT "8"
    set_if_empty DELETE_RATIO_PERCENT "6"
    set_if_empty ADD_RATIO_PERCENT "7"
    ;;
  balanced)
    set_if_empty LEVELS "10000 50000 100000"
    set_if_empty FILE_SIZE_KB "16"
    set_if_empty MODIFY_RATIO_PERCENT "5"
    set_if_empty DELETE_RATIO_PERCENT "3"
    set_if_empty ADD_RATIO_PERCENT "4"
    ;;
  stress)
    set_if_empty LEVELS "20000 80000 150000"
    set_if_empty FILE_SIZE_KB "32"
    set_if_empty MODIFY_RATIO_PERCENT "8"
    set_if_empty DELETE_RATIO_PERCENT "5"
    set_if_empty ADD_RATIO_PERCENT "6"
    ;;
  *)
    echo "Invalid PROFILE=$PROFILE. Use quick-smoke|balanced|stress." >&2
    exit 4
    ;;
esac

ts="$(date +%Y%m%d-%H%M%S)"
summary_md="$REPORT_DIR/benchmark-matrix-$ts.md"
summary_csv="$REPORT_DIR/benchmark-matrix-$ts.csv"
trend_csv="$REPORT_DIR/benchmark-trend.csv"

commit="nogit"
if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  commit="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
fi

machine="$(uname -m)-$(sw_vers -productVersion 2>/dev/null || echo unknown)"

echo "file_count,full_s,incremental_s,steady_s,inc_faster_pct,steady_faster_pct,report" >"$summary_csv"

extract_metric() {
  local report_file="$1"
  local run_name="$2"
  awk -F'|' -v n="$run_name" '
    index($0, "| " n " |") > 0 {
      gsub(/^ +| +$/, "", $3)
      print $3
    }
  ' "$report_file"
}

extract_delta_pct() {
  local report_file="$1"
  local key="$2"
  awk -F': ' -v k="$key" '$1 ~ k { gsub(/% faster/, "", $2); print $2 }' "$report_file"
}

if [[ ! -f "$trend_csv" ]]; then
  echo "timestamp,commit,machine,file_count,full_s,incremental_s,steady_s,inc_faster_pct,steady_faster_pct,report" >"$trend_csv"
fi

for count in $LEVELS; do
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    echo "Invalid file count in LEVELS: $count" >&2
    exit 2
  fi

  modify=$(( count * MODIFY_RATIO_PERCENT / 100 ))
  delete=$(( count * DELETE_RATIO_PERCENT / 100 ))
  add=$(( count * ADD_RATIO_PERCENT / 100 ))

  # Avoid zero operations for small benchmark sizes.
  if (( modify == 0 )); then modify=1; fi
  if (( delete == 0 )); then delete=1; fi
  if (( add == 0 )); then add=1; fi

  dataset_dir="$DATASET_ROOT/files-$count"

  echo "Running benchmark for file_count=$count (modify=$modify delete=$delete add=$add)..."

  output="$({
    FILE_COUNT="$count" \
    FILE_SIZE_KB="$FILE_SIZE_KB" \
    MODIFY_COUNT="$modify" \
    DELETE_COUNT="$delete" \
    ADD_COUNT="$add" \
    "$BENCH_SCRIPT" "$dataset_dir" "$REPORT_DIR"
  } 2>&1)"

  report_file="$(echo "$output" | awk -F': ' '/Benchmark report generated:/ {print $2}' | tail -n1)"
  if [[ -z "$report_file" || ! -f "$report_file" ]]; then
    echo "$output"
    echo "Failed to parse benchmark report path for file_count=$count" >&2
    exit 3
  fi

  full_s="$(extract_metric "$report_file" "Full scan (baseline)")"
  inc_s="$(extract_metric "$report_file" "Incremental scan (after mutation)")"
  steady_s="$(extract_metric "$report_file" "Incremental scan (steady state)")"
  inc_pct="$(extract_delta_pct "$report_file" "Incremental vs full")"
  steady_pct="$(extract_delta_pct "$report_file" "Steady vs full")"

  echo "$count,$full_s,$inc_s,$steady_s,$inc_pct,$steady_pct,$report_file" >>"$summary_csv"
  echo "$ts,$commit,$machine,$count,$full_s,$inc_s,$steady_s,$inc_pct,$steady_pct,$report_file" >>"$trend_csv"
done

cat >"$summary_md" <<MARKDOWN
# Benchmark Matrix

- Timestamp: $ts
- Commit: $commit
- Machine: $machine
- Profile: $PROFILE
- Levels: $LEVELS
- File size: ${FILE_SIZE_KB} KB
- Ratios: modify=${MODIFY_RATIO_PERCENT}% delete=${DELETE_RATIO_PERCENT}% add=${ADD_RATIO_PERCENT}%

## Results

| File Count | Full (s) | Incremental (s) | Steady (s) | Inc Faster % | Steady Faster % |
|---:|---:|---:|---:|---:|---:|
MARKDOWN

while IFS=',' read -r file_count full_s inc_s steady_s inc_pct steady_pct report_file; do
  if [[ "$file_count" == "file_count" ]]; then
    continue
  fi
  echo "| $file_count | $full_s | $inc_s | $steady_s | $inc_pct | $steady_pct |" >>"$summary_md"
done <"$summary_csv"

cat >>"$summary_md" <<MARKDOWN

## Artifacts

- Matrix CSV: $summary_csv
- Trend CSV: $trend_csv
MARKDOWN

echo "Matrix summary generated: $summary_md"
echo "Matrix csv generated: $summary_csv"
echo "Trend csv updated: $trend_csv"
