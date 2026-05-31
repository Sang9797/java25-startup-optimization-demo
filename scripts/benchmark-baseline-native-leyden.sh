#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMPARE_TYPE="cold"
ITERATIONS="3"
SKIP_BUILD="false"
SKIP_NATIVE_BUILD="false"
LONG_WARMUP_DURATION="${LONG_WARMUP_DURATION:-60s}"
LONG_DURATION="${LONG_DURATION:-10m}"
LONG_K6_VUS="${LONG_K6_VUS:-8}"
LONG_SAMPLE_INTERVAL_SECONDS="${LONG_SAMPLE_INTERVAL_SECONDS:-10}"
START_MONITORING="true"

usage() {
  cat <<'USAGE'
Usage:
  scripts/benchmark-baseline-native-leyden.sh [options]

Modes are fixed to baseline, leyden-aot, and native.

Options:
  --type cold|grafana          cold: sequential benchmark with monitoring stack
                               grafana: live side-by-side Grafana run
                               Default: cold
  --iterations N               Cold benchmark iterations. Default: 3
  --skip-build                 Reuse existing jar/artifacts where possible.
  --skip-native-build          Reuse existing native executable.
  --no-monitoring              Do not start Prometheus/Grafana for cold runs.
  --help                       Show this help.

Examples:
  scripts/benchmark-baseline-native-leyden.sh
  scripts/benchmark-baseline-native-leyden.sh --type grafana
  LONG_DURATION=30m LONG_K6_VUS=8 scripts/benchmark-baseline-native-leyden.sh --type grafana
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      COMPARE_TYPE="${2:?--type requires cold or grafana}"
      shift 2
      ;;
    --iterations)
      ITERATIONS="${2:?--iterations requires a number}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD="true"
      shift
      ;;
    --skip-native-build)
      SKIP_NATIVE_BUILD="true"
      shift
      ;;
    --no-monitoring)
      START_MONITORING="false"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${COMPARE_TYPE}" in
  cold|grafana) ;;
  *)
    echo "Invalid type: ${COMPARE_TYPE}" >&2
    echo "Valid types: cold,grafana" >&2
    exit 1
    ;;
esac

args=(
  --modes baseline,leyden-aot,native
  --type "${COMPARE_TYPE}"
  --iterations "${ITERATIONS}"
)

if [[ "${SKIP_BUILD}" == "true" ]]; then
  args+=(--skip-build)
fi

if [[ "${SKIP_NATIVE_BUILD}" == "true" ]]; then
  args+=(--skip-native-build)
fi

if [[ "${START_MONITORING}" == "false" ]]; then
  args+=(--no-monitoring)
fi

exec "${ROOT_DIR}/scripts/compare.sh" "${args[@]}"
