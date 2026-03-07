# Scan Performance Benchmark

## Purpose
Measure and compare:
1. Baseline full scan time.
2. Incremental scan time after controlled file mutations.
3. Incremental steady-state scan time.

This benchmark uses the existing CLI pipeline (`scan + recommendation build`) so numbers reflect user-visible behavior.

## Script
- Path: `scripts/benchmark_scan.sh`
- Report output: `reports/benchmark-scan-<timestamp>.md`

## Usage
From repository root:

```bash
./scripts/benchmark_scan.sh
```

Optional arguments:

```bash
./scripts/benchmark_scan.sh <dataset_dir> <report_dir>
```

## Tunable Environment Variables
- `FILE_COUNT` default `6000`
- `FILE_SIZE_KB` default `32`
- `MODIFY_COUNT` default `300`
- `DELETE_COUNT` default `200`
- `ADD_COUNT` default `250`

Example small run:

```bash
FILE_COUNT=1000 FILE_SIZE_KB=16 MODIFY_COUNT=80 DELETE_COUNT=60 ADD_COUNT=90 ./scripts/benchmark_scan.sh
```

## Matrix/Trend Benchmark
- Path: `scripts/benchmark_matrix.sh`
- Matrix output:
  - `reports/benchmark-matrix-<timestamp>.md`
  - `reports/benchmark-matrix-<timestamp>.csv`
- Trend output:
  - `reports/benchmark-trend.csv` (append-only across runs)

Run default matrix profile (`balanced`, levels `10k/50k/100k`):

```bash
./scripts/benchmark_matrix.sh
```

Run quick smoke profile:

```bash
PROFILE=quick-smoke ./scripts/benchmark_matrix.sh
```

Run stress profile:

```bash
PROFILE=stress ./scripts/benchmark_matrix.sh
```

Run custom levels (overrides profile defaults):

```bash
LEVELS="1000 3000" FILE_SIZE_KB=16 ./scripts/benchmark_matrix.sh
```

Optional arguments:

```bash
./scripts/benchmark_matrix.sh <report_dir> <dataset_root>
```

Matrix environment variables:
- `PROFILE` default `balanced` (`quick-smoke|balanced|stress`)
- `LEVELS` default `10000 50000 100000`
- `FILE_SIZE_KB` default `16`
- `MODIFY_RATIO_PERCENT` default `5`
- `DELETE_RATIO_PERCENT` default `3`
- `ADD_RATIO_PERCENT` default `4`

## Baseline Comparison
- Path: `scripts/benchmark_compare.sh`
- Purpose: compare two matrix CSV files and generate delta report.

Usage:

```bash
./scripts/benchmark_compare.sh <baseline_matrix_csv> <candidate_matrix_csv>
```

Optional output directory:

```bash
./scripts/benchmark_compare.sh <baseline_matrix_csv> <candidate_matrix_csv> <output_dir>
```

Output:
- `benchmark-compare-<timestamp>.csv`
- `benchmark-compare-<timestamp>.md`

## One-Command Release Compare
- Path: `scripts/benchmark_release_compare.sh`
- Purpose: run candidate matrix benchmark and compare it against a baseline CSV in one command.

Usage:

```bash
./scripts/benchmark_release_compare.sh <baseline_matrix_csv>
```

Custom profile/report/data paths:

```bash
./scripts/benchmark_release_compare.sh <baseline_matrix_csv> stress ./reports "$HOME/Downloads/CleanMacBenchmarkMatrix"
```

## Output Fields
Report includes:
1. Three run times (`full`, `incremental`, `steady`).
2. Files and scanned size reported by CLI.
3. Relative speedup percentage against the full scan.

## Notes
1. Run benchmark with minimal background workload for stable numbers.
2. Running consecutive times on same machine can benefit from filesystem cache.
3. For release baselines, record machine model, SSD type, and free disk space.
4. Compare trend rows under the same machine and similar free-space conditions.
