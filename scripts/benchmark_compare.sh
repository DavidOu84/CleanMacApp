#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <baseline_matrix_csv> <candidate_matrix_csv> [output_dir]" >&2
  exit 1
fi

BASELINE_CSV="$1"
CANDIDATE_CSV="$2"
OUTPUT_DIR="${3:-$(dirname "$CANDIDATE_CSV")}"

if [[ ! -f "$BASELINE_CSV" ]]; then
  echo "Baseline CSV not found: $BASELINE_CSV" >&2
  exit 2
fi

if [[ ! -f "$CANDIDATE_CSV" ]]; then
  echo "Candidate CSV not found: $CANDIDATE_CSV" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"

timestamp="$(date +%Y%m%d-%H%M%S)"
out_csv="$OUTPUT_DIR/benchmark-compare-$timestamp.csv"
out_md="$OUTPUT_DIR/benchmark-compare-$timestamp.md"

echo "file_count,baseline_full_s,candidate_full_s,full_delta_s,full_delta_pct,baseline_incremental_s,candidate_incremental_s,incremental_delta_s,incremental_delta_pct,baseline_steady_s,candidate_steady_s,steady_delta_s,steady_delta_pct" >"$out_csv"

awk -F',' '
function pct(delta, base) {
  if (base == 0) return 0
  return (delta / base) * 100
}
NR == FNR {
  if (FNR == 1) next
  if ($1 == "" || $2 == "" || $3 == "" || $4 == "") next
  b_full[$1] = $2 + 0
  b_inc[$1] = $3 + 0
  b_steady[$1] = $4 + 0
  have[$1] = 1
  next
}
FNR == 1 { next }
{
  if ($1 == "" || $2 == "" || $3 == "" || $4 == "") next
  c = $1
  if (!(c in have)) {
    missing += 1
    next
  }

  c_full = $2 + 0
  c_inc = $3 + 0
  c_steady = $4 + 0

  d_full = c_full - b_full[c]
  d_inc = c_inc - b_inc[c]
  d_steady = c_steady - b_steady[c]

  printf "%s,%.4f,%.4f,%.4f,%.2f,%.4f,%.4f,%.4f,%.2f,%.4f,%.4f,%.4f,%.2f\n",
    c,
    b_full[c], c_full, d_full, pct(d_full, b_full[c]),
    b_inc[c], c_inc, d_inc, pct(d_inc, b_inc[c]),
    b_steady[c], c_steady, d_steady, pct(d_steady, b_steady[c])
}
END {
  if (missing > 0) {
    printf "Warning: skipped %d candidate rows without matching baseline file_count.\n", missing > "/dev/stderr"
  }
}
' "$BASELINE_CSV" "$CANDIDATE_CSV" >>"$out_csv"

row_count="$(awk -F',' 'NR > 1 {count += 1} END {print count + 0}' "$out_csv")"
if [[ "$row_count" -eq 0 ]]; then
  echo "No comparable rows found between baseline and candidate CSV." >&2
  exit 3
fi

better_full="$(awk -F',' 'NR > 1 && $4 < 0 {count += 1} END {print count + 0}' "$out_csv")"
better_inc="$(awk -F',' 'NR > 1 && $8 < 0 {count += 1} END {print count + 0}' "$out_csv")"
better_steady="$(awk -F',' 'NR > 1 && $12 < 0 {count += 1} END {print count + 0}' "$out_csv")"

cat >"$out_md" <<MARKDOWN
# Benchmark Comparison Report

- Baseline: $BASELINE_CSV
- Candidate: $CANDIDATE_CSV
- Generated at: $timestamp
- Comparable rows: $row_count

## Summary

- Full scan improved rows: $better_full / $row_count
- Incremental scan improved rows: $better_inc / $row_count
- Steady incremental scan improved rows: $better_steady / $row_count

## Details

| File Count | Full Delta (s) | Full Delta (%) | Incremental Delta (s) | Incremental Delta (%) | Steady Delta (s) | Steady Delta (%) |
|---:|---:|---:|---:|---:|---:|---:|
MARKDOWN

while IFS=',' read -r \
  file_count b_full c_full d_full p_full \
  b_inc c_inc d_inc p_inc \
  b_steady c_steady d_steady p_steady; do
  if [[ "$file_count" == "file_count" ]]; then
    continue
  fi
  echo "| $file_count | $d_full | $p_full | $d_inc | $p_inc | $d_steady | $p_steady |" >>"$out_md"
done <"$out_csv"

cat >>"$out_md" <<MARKDOWN

## Artifacts

- Compare CSV: $out_csv
- Compare Markdown: $out_md
MARKDOWN

echo "Comparison CSV generated: $out_csv"
echo "Comparison Markdown generated: $out_md"
