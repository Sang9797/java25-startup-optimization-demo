#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

COMPARE_TYPE="cold"
MODES="baseline,native"
SKIP_BUILD="false"
SKIP_NATIVE_BUILD="false"
START_MONITORING="true"

usage() {
  cat <<'USAGE'
Usage:
  scripts/compare.sh [options]

Options:
  --modes MODE[,MODE...]       Modes to compare. Valid modes: baseline,cds,appcds,leyden-aot,crac,native
                               Default: baseline,native
  --type cold|long|grafana     cold: startup + warm request + short k6 benchmark for selected modes
                               long: sequential long-run comparison
                               grafana: live side-by-side comparison with Grafana
                               Default: cold
  --iterations N               Benchmark iterations. Default: cold=3, long=1
  --skip-build                 Reuse existing jar/artifacts where possible.
  --skip-native-build          Reuse existing native executable.
  --no-monitoring              Do not start Prometheus/Grafana for cold comparisons.
  --help                       Show this help.
                               Leyden AOT cache generation respects LEYDEN_AOT_TRAINING_DURATION
                               and LEYDEN_AOT_TRAINING_VUS when set in the environment.

Examples:
  scripts/compare.sh --modes baseline,native --type cold --iterations 3
  scripts/compare.sh --modes baseline,cds,appcds,leyden-aot,native --type cold
  LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 scripts/compare.sh --modes leyden-aot,native --type long
  LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 scripts/compare.sh --modes baseline,leyden-aot,native --type long
  LEYDEN_AOT_TRAINING_DURATION=3m LEYDEN_AOT_TRAINING_VUS=4 scripts/compare.sh --modes baseline,leyden-aot,native --type long
  LONG_DURATION=30m LONG_K6_VUS=8 scripts/compare.sh --modes baseline,leyden-aot,native --type grafana
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modes)
      MODES="${2:?--modes requires a comma-separated value}"
      shift 2
      ;;
    --type)
      COMPARE_TYPE="${2:?--type requires cold, long, or grafana}"
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

IFS=, read -r -a SELECTED_MODES <<< "${MODES}"

mode_selected() {
  local expected="$1"
  local mode
  for mode in "${SELECTED_MODES[@]}"; do
    [[ "${mode}" == "${expected}" ]] && return 0
  done
  return 1
}

validate_modes() {
  local mode
  for mode in "${SELECTED_MODES[@]}"; do
    case "${mode}" in
      baseline|cds|appcds|leyden-aot|crac|native) ;;
      *)
        echo "Invalid mode: ${mode}" >&2
        echo "Valid modes: baseline,cds,appcds,leyden-aot,crac,native" >&2
        exit 1
        ;;
    esac
  done
}

validate_type() {
  case "${COMPARE_TYPE}" in
    cold|long|grafana) ;;
    *)
      echo "Invalid comparison type: ${COMPARE_TYPE}" >&2
      echo "Valid types: cold,long,grafana" >&2
      exit 1
      ;;
  esac
}

require_baseline_native_only() {
  if [[ "${#SELECTED_MODES[@]}" -ne 2 ]] || ! mode_selected baseline || ! mode_selected native; then
    echo "--type ${COMPARE_TYPE} currently supports exactly: --modes baseline,native" >&2
    exit 1
  fi
}

require_supported_long_modes() {
  if [[ "${#SELECTED_MODES[@]}" -eq 2 ]]; then
    if mode_selected baseline && mode_selected native; then
      return 0
    fi
    if mode_selected leyden-aot && mode_selected native; then
      return 0
    fi
  elif [[ "${#SELECTED_MODES[@]}" -eq 3 ]]; then
    if mode_selected baseline && mode_selected leyden-aot && mode_selected native; then
      return 0
    fi
  fi
  echo "--type ${COMPARE_TYPE} currently supports exactly one of: --modes baseline,native, --modes leyden-aot,native, or --modes baseline,leyden-aot,native" >&2
  exit 1
}

build_required_artifacts() {
  if [[ "${SKIP_BUILD}" != "true" ]]; then
    echo "Building application jar..."
    "${ROOT_DIR}/scripts/01-build.sh"
  else
    require_built_app
  fi

  ensure_dependency_services

  if mode_selected native; then
    if [[ "${SKIP_NATIVE_BUILD}" == "true" ]]; then
      require_native_app
    else
      echo "Building native executable..."
      "${ROOT_DIR}/scripts/native/01-build-native.sh"
    fi
  fi

  if mode_selected cds; then
    echo "Generating CDS archive..."
    "${ROOT_DIR}/scripts/03-generate-cds-archive.sh"
  fi

  if mode_selected appcds; then
    echo "Generating AppCDS class list and archive..."
    "${ROOT_DIR}/scripts/05-generate-appcds-classlist.sh"
    "${ROOT_DIR}/scripts/06-generate-appcds-archive.sh"
  fi

  if mode_selected leyden-aot; then
    echo "Generating Leyden AOT cache..."
    "${ROOT_DIR}/scripts/11-generate-leyden-aot-cache.sh"
  fi

  if mode_selected crac; then
    if ! java -XX:CRaCCheckpointTo=/tmp/crac-probe -version >/dev/null 2>&1; then
      echo "Requested crac, but the current JDK does not support CRaC flags." >&2
      exit 1
    fi
    echo "Generating CRaC checkpoint..."
    "${ROOT_DIR}/scripts/08-crac-checkpoint.sh"
  fi
}

start_monitoring_if_needed() {
  if [[ "${START_MONITORING}" == "true" ]]; then
    require_command docker
    docker compose -f "${ROOT_DIR}/docker-compose.monitoring.yml" up -d prometheus grafana >/dev/null
  fi
}

free_selected_mode_ports() {
  local mode
  local port
  local pids
  for mode in "${SELECTED_MODES[@]}"; do
    stop_mode_if_running "${mode}"
    port="$(port_for_mode "${mode}")"
    if command -v ss >/dev/null 2>&1; then
      pids="$(ss -ltnp "sport = :${port}" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)"
      if [[ -n "${pids}" ]]; then
        echo "Stopping stale process on port ${port}: ${pids}"
        kill ${pids} >/dev/null 2>&1 || true
        sleep 1
      fi
    fi
  done
}

benchmark_one_cold_mode() {
  local mode="$1"
  local port
  port="$(port_for_mode "${mode}")"

  for iteration in $(seq 1 "${ITERATIONS:-3}"); do
    local log_file="${LOG_DIR}/compare-${mode}-${iteration}.log"
    local pid
    local rss_startup_kb
    local first_latency_ms
    local warm_latency_ms
    local load_metrics
    local http_reqs_per_sec
    local http_req_p95_ms
    local rss_warmup_kb

    case "${mode}" in
      baseline|cds|appcds|leyden-aot)
        start_standard_mode "${mode}" "${port}" "${log_file}" >/dev/null
        ;;
      crac)
        rm -rf "${ARTIFACT_DIR}/crac-checkpoint-monitoring"
        create_crac_checkpoint_for_monitoring "${port}" >/dev/null
        local restore_start_ns
        local restore_end_ns
        restore_start_ns="$(date +%s%N)"
        start_crac_restore_mode "${port}" "${log_file}" >/dev/null
        restore_end_ns="$(date +%s%N)"
        echo "{\"event\":\"crac restore measured\",\"startupTimeMillis\":$(((restore_end_ns - restore_start_ns) / 1000000)),\"springBootStartupTimeMillis\":-1}" >> "${log_file}"
        ;;
      native)
        start_native_mode "${port}" "${log_file}" >/dev/null
        ;;
    esac

    pid="$(cat "${PID_DIR}/${mode}.pid")"
    rss_startup_kb="$(rss_kb_for_pid "${pid}")"
    first_latency_ms="$(first_request_latency_ms "${port}")"
    warm_gateway_endpoints "${port}"
    sleep 1
    warm_latency_ms="$(request_latency_ms "${port}" "/api/products/789")"
    load_metrics="$(run_k6_load "${mode}" "${port}" "${iteration}")"
    http_reqs_per_sec="${load_metrics%%,*}"
    http_req_p95_ms="${load_metrics#*,}"
    rss_warmup_kb="$(rss_kb_for_pid "${pid}")"
    append_benchmark_row "${mode}" "${iteration}" "${port}" "${pid}" "${log_file}" "${first_latency_ms}" "${rss_startup_kb}" "${rss_warmup_kb}" "${warm_latency_ms}" "${http_reqs_per_sec}" "${http_req_p95_ms}"
    stop_mode_if_running "${mode}"
    echo "${mode} iteration ${iteration}/${ITERATIONS:-3} complete"
  done
}

write_cold_summary() {
  local summary_file="${LOG_DIR}/compare-summary.md"
  {
    echo "# Selected Mode Comparison"
    echo
    echo "- modes: ${MODES}"
    echo "- type: cold"
    echo "- iterations: ${ITERATIONS:-3}"
    echo
    echo "| Mode | Avg startup ms | Avg first request ms | Avg warm request ms | Avg RSS warmup KB | Avg dependency startup ms | Avg throughput rps | Avg HTTP p95 ms |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|"
    awk -F, '
      NR == 1 { next }
      {
        mode=$1
        count[mode]++
        startup[mode]+=$3
        first[mode]+=$5
        warm[mode]+=$6
        rss[mode]+=$8
        dep[mode]+=$19
        throughput[mode]+=$20
        p95[mode]+=$21
      }
      END {
        for (mode in count) {
          printf "| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |\n",
            mode, startup[mode]/count[mode], first[mode]/count[mode],
            warm[mode]/count[mode], rss[mode]/count[mode], dep[mode]/count[mode],
            throughput[mode]/count[mode], p95[mode]/count[mode]
        }
      }
    ' "${MONITORING_CSV}"
  } > "${summary_file}"

  echo "Summary: ${summary_file}"
  echo "CSV:     ${MONITORING_CSV}"
  echo "Text:    ${MONITORING_RESULTS}"
}

run_cold_comparison() {
  require_command curl
  build_required_artifacts
  free_selected_mode_ports
  start_monitoring_if_needed
  ITERATIONS="${ITERATIONS:-3}"
  append_benchmark_header

  local mode
  for mode in "${SELECTED_MODES[@]}"; do
    benchmark_one_cold_mode "${mode}"
  done

  write_cold_summary

  if [[ "${START_MONITORING}" == "true" ]]; then
    cat <<MSG

Grafana:
  http://localhost:3000

Useful dashboards:
  /d/jvm-startup-optimization-comparison/jvm-startup-optimization-comparison
  /d/long-run-baseline-vs-native/long-run-baseline-vs-native
  /d/long-run-native-vs-leyden-aot/long-run-native-vs-leyden-aot
MSG
  fi
}

run_long_comparison() {
  require_supported_long_modes
  build_required_artifacts
  free_selected_mode_ports
  start_monitoring_if_needed
  if mode_selected baseline && mode_selected leyden-aot && mode_selected native; then
    ITERATIONS="${ITERATIONS:-1}" "${ROOT_DIR}/scripts/native/10-long-run-baseline-native-leyden-aot.sh" --type long
  elif mode_selected leyden-aot; then
    ITERATIONS="${ITERATIONS:-1}" "${ROOT_DIR}/scripts/native/08-long-run-native-vs-leyden-aot.sh"
  else
    ITERATIONS="${ITERATIONS:-1}" "${ROOT_DIR}/scripts/native/06-long-run-baseline-vs-native.sh"
  fi
  if [[ "${START_MONITORING}" == "true" ]]; then
    local dashboard_path="/d/long-run-baseline-vs-native/long-run-baseline-vs-native"
    if mode_selected baseline && mode_selected leyden-aot && mode_selected native; then
      dashboard_path="/d/long-run-baseline-native-leyden-aot/long-run-baseline-native-leyden-aot"
    elif mode_selected leyden-aot; then
      dashboard_path="/d/long-run-native-vs-leyden-aot/long-run-native-vs-leyden-aot"
    fi
    cat <<MSG

Grafana:
  http://localhost:3000${dashboard_path}
MSG
  fi
}

run_grafana_comparison() {
  require_supported_long_modes
  build_required_artifacts
  free_selected_mode_ports
  if mode_selected baseline && mode_selected leyden-aot && mode_selected native; then
    "${ROOT_DIR}/scripts/native/10-long-run-baseline-native-leyden-aot.sh" --type grafana
  elif mode_selected leyden-aot; then
    "${ROOT_DIR}/scripts/native/09-grafana-long-run-native-vs-leyden-aot.sh"
  else
    "${ROOT_DIR}/scripts/native/07-grafana-long-run-baseline-vs-native.sh"
  fi
}

validate_type
validate_modes

case "${COMPARE_TYPE}" in
  cold) run_cold_comparison ;;
  long) run_long_comparison ;;
  grafana) run_grafana_comparison ;;
esac
