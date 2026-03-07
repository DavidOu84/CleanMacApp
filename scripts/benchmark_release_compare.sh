#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 4 ]]; then
  echo "Usage: $0 <baseline_matrix_csv> [profile] [report_dir] [dataset_root]" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX_SCRIPT="$ROOT_DIR/scripts/benchmark_matrix.sh"
COMPARE_SCRIPT="$ROOT_DIR/scripts/benchmark_compare.sh"

BASELINE_CSV="$1"
PROFILE_NAME="${2:-balanced}"
REPORT_DIR="${3:-$ROOT_DIR/reports}"
DATASET_ROOT="${4:-$HOME/Downloads/CleanMacBenchmarkMatrix}"

if [[ ! -f "$BASELINE_CSV" ]]; then
  echo "Baseline CSV not found: $BASELINE_CSV" >&2
  exit 2
fi

if [[ ! -x "$MATRIX_SCRIPT" ]]; then
  echo "Missing executable matrix script: $MATRIX_SCRIPT" >&2
  exit 2
fi

if [[ ! -x "$COMPARE_SCRIPT" ]]; then
  echo "Missing executable compare script: $COMPARE_SCRIPT" >&2
  exit 2
fi

echo "Running candidate benchmark matrix with profile=$PROFILE_NAME ..."
matrix_output="$({
  PROFILE="$PROFILE_NAME" "$MATRIX_SCRIPT" "$REPORT_DIR" "$DATASET_ROOT"
} 2>&1)"
echo "$matrix_output"

candidate_csv="$(echo "$matrix_output" | awk -F': ' '/Matrix csv generated:/ {print $2}' | tail -n1)"
if [[ -z "$candidate_csv" || ! -f "$candidate_csv" ]]; then
  echo "Unable to resolve generated candidate matrix CSV." >&2
  exit 3
fi

echo "Comparing against baseline ..."
compare_output="$("$COMPARE_SCRIPT" "$BASELINE_CSV" "$candidate_csv" "$REPORT_DIR" 2>&1)"
echo "$compare_output"

compare_md="$(echo "$compare_output" | awk -F': ' '/Comparison Markdown generated:/ {print $2}' | tail -n1)"
compare_csv="$(echo "$compare_output" | awk -F': ' '/Comparison CSV generated:/ {print $2}' | tail -n1)"

echo "Release baseline compare complete."
echo "Baseline CSV: $BASELINE_CSV"
echo "Candidate CSV: $candidate_csv"
echo "Compare CSV: $compare_csv"
echo "Compare Markdown: $compare_md"
