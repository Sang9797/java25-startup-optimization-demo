#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

COMPARE_TYPE="cold"
MODES="baseline,native"
SKIP_BUILD="false"
SKIP_NATIVE_BUILD="false"
START_MONITORING="true"
COMPARE_LOG_DIR=""
NATIVE_BUILD_MODE="${NATIVE_BUILD_MODE:-default}"
NATIVE_PGO_PROFILE="${NATIVE_PGO_PROFILE:-${ROOT_DIR}/build/native/default.iprof}"
NATIVE_PRESERVE_VALUE="${NATIVE_PRESERVE:-}"
NATIVE_SBOM_VALUE="${NATIVE_ENABLE_SBOM:-}"
NATIVE_ENABLE_OBFUSCATION_VALUE="${NATIVE_ENABLE_OBFUSCATION:-false}"
NATIVE_EXTRA_ARGS_VALUE="${NATIVE_EXTRA_ARGS:-}"
NATIVE_TRAINING_PORT="${NATIVE_TRAINING_PORT:-8095}"
NATIVE_TRAINING_VUS="${NATIVE_TRAINING_VUS:-4}"
NATIVE_TRAINING_DURATION="${NATIVE_TRAINING_DURATION:-20s}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/compare.sh [options]

Options:
  --modes MODE[,MODE...]       Modes to compare. Valid modes: baseline,cds,appcds,leyden-aot,crac,native
                               Modes run in the order given. Single-mode runs are supported.
                               Default: baseline,native
  --type cold|long|grafana     cold: startup + warm request + short k6 benchmark for selected modes
                               long: sequential long-run comparison
                               grafana: live side-by-side comparison with Grafana
                               Default: cold
  --iterations N               Benchmark iterations. Default: cold=3, long=1
  --skip-build                 Reuse existing jar/artifacts where possible.
  --skip-native-build          Reuse existing native executable.
  --native-build-mode MODE     Native build mode: default, pgo-instrument, pgo-optimize, pgo-auto
  --native-preserve VALUE      Pass through -H:Preserve selector(s) to native-image.
  --native-sbom VALUE          Pass through --enable-sbom value to native-image.
  --native-obfuscation         Enable advanced native-image obfuscation when supported.
  --native-extra-args VALUE    Extra native-image args, quoted as one shell value.
  --no-monitoring              Do not start Prometheus/Grafana before cold or long comparisons.
  --help                       Show this help.
                               Leyden AOT cache generation respects LEYDEN_AOT_TRAINING_DURATION
                               and LEYDEN_AOT_TRAINING_VUS when set in the environment.
                               Logs are written under logs/<type>-<mode-list>/<mode>/.

Examples:
  scripts/compare.sh --modes baseline,native --type cold --iterations 3
  scripts/compare.sh --modes baseline,native --type cold --native-build-mode pgo-auto
  scripts/compare.sh --modes native --type cold --iterations 3
  scripts/compare.sh --modes baseline,cds,appcds,leyden-aot,native --type cold
  scripts/compare.sh --modes native --type long --native-build-mode pgo-optimize --skip-native-build
  LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 scripts/compare.sh --modes native,leyden-aot --type long
  LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 scripts/compare.sh --modes baseline,leyden-aot,native --type long
  LEYDEN_AOT_TRAINING_DURATION=3m LEYDEN_AOT_TRAINING_VUS=4 scripts/compare.sh --modes baseline,leyden-aot,native --type long
  LONG_DURATION=30m LONG_K6_VUS=8 scripts/compare.sh --modes native,baseline --type grafana
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
    --native-build-mode)
      NATIVE_BUILD_MODE="${2:?--native-build-mode requires default, pgo-instrument, pgo-optimize, or pgo-auto}"
      shift 2
      ;;
    --native-preserve)
      NATIVE_PRESERVE_VALUE="${2:?--native-preserve requires a value}"
      shift 2
      ;;
    --native-sbom)
      NATIVE_SBOM_VALUE="${2:?--native-sbom requires a value}"
      shift 2
      ;;
    --native-obfuscation)
      NATIVE_ENABLE_OBFUSCATION_VALUE="true"
      shift
      ;;
    --native-extra-args)
      NATIVE_EXTRA_ARGS_VALUE="${2:?--native-extra-args requires a value}"
      shift 2
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
  if [[ "${#SELECTED_MODES[@]}" -eq 0 ]]; then
    echo "--modes requires at least one mode" >&2
    exit 1
  fi

  local mode
  local seen_modes=","
  for mode in "${SELECTED_MODES[@]}"; do
    case "${mode}" in
      baseline|cds|appcds|leyden-aot|crac|native) ;;
      *)
        echo "Invalid mode: ${mode}" >&2
        echo "Valid modes: baseline,cds,appcds,leyden-aot,crac,native" >&2
        exit 1
        ;;
    esac
    if [[ "${seen_modes}" == *",${mode},"* ]]; then
      echo "Duplicate mode: ${mode}" >&2
      echo "Each mode can be selected once per comparison." >&2
      exit 1
    fi
    seen_modes="${seen_modes}${mode},"
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

validate_native_build_mode() {
  case "${NATIVE_BUILD_MODE}" in
    default|pgo-instrument|pgo-optimize|pgo-auto) ;;
    *)
      echo "Invalid native build mode: ${NATIVE_BUILD_MODE}" >&2
      echo "Valid native build modes: default,pgo-instrument,pgo-optimize,pgo-auto" >&2
      exit 1
      ;;
  esac

  if [[ "${SKIP_NATIVE_BUILD}" == "true" && "${NATIVE_BUILD_MODE}" == "pgo-auto" ]]; then
    echo "--skip-native-build cannot be combined with --native-build-mode pgo-auto." >&2
    echo "pgo-auto needs to build an instrumented image, train it, and rebuild the optimized image." >&2
    exit 1
  fi
}

native_variant_slug() {
  if ! mode_selected native; then
    printf '%s\n' ""
    return 0
  fi

  local suffix=""
  if [[ "${NATIVE_BUILD_MODE}" != "default" ]]; then
    suffix="${suffix}-native-${NATIVE_BUILD_MODE}"
  fi
  if [[ -n "${NATIVE_PRESERVE_VALUE}" ]]; then
    suffix="${suffix}-preserve"
  fi
  if [[ -n "${NATIVE_SBOM_VALUE}" ]]; then
    suffix="${suffix}-sbom"
  fi
  if [[ "${NATIVE_ENABLE_OBFUSCATION_VALUE}" == "true" ]]; then
    suffix="${suffix}-obf"
  fi
  printf '%s\n' "${suffix}"
}

build_required_artifacts() {
  if [[ "${SKIP_BUILD}" != "true" ]]; then
    echo "Building application jar..."
    run_script_with_log_dir "${COMPARE_LOG_DIR}/build" "${ROOT_DIR}/scripts/01-build.sh"
  else
    require_built_app
  fi

  ensure_dependency_services

  if mode_selected native; then
    if [[ "${SKIP_NATIVE_BUILD}" == "true" ]]; then
      require_native_app
    else
      build_native_artifacts
    fi
  fi

  if mode_selected cds; then
    echo "Generating CDS archive..."
    run_script_with_log_dir "$(mode_log_dir cds)" "${ROOT_DIR}/scripts/03-generate-cds-archive.sh"
  fi

  if mode_selected appcds; then
    echo "Generating AppCDS class list and archive..."
    run_script_with_log_dir "$(mode_log_dir appcds)" "${ROOT_DIR}/scripts/05-generate-appcds-classlist.sh"
    run_script_with_log_dir "$(mode_log_dir appcds)" "${ROOT_DIR}/scripts/06-generate-appcds-archive.sh"
  fi

  if mode_selected leyden-aot; then
    echo "Generating Leyden AOT cache..."
    run_script_with_log_dir "$(mode_log_dir leyden-aot)" "${ROOT_DIR}/scripts/11-generate-leyden-aot-cache.sh"
  fi

  if mode_selected crac; then
    if ! java -XX:CRaCCheckpointTo=/tmp/crac-probe -version >/dev/null 2>&1; then
      echo "Requested crac, but the current JDK does not support CRaC flags." >&2
      exit 1
    fi
    echo "Generating CRaC checkpoint..."
    run_script_with_log_dir "$(mode_log_dir crac)" "${ROOT_DIR}/scripts/08-crac-checkpoint.sh"
  fi
}

selected_modes_slug() {
  local slug="${MODES//,/-}"
  slug="${slug//[^a-zA-Z0-9._-]/-}"
  slug="${slug}$(native_variant_slug)"
  printf '%s\n' "${slug}"
}

compare_log_dir() {
  local type="$1"
  local slug
  slug="$(selected_modes_slug)"
  printf '%s/%s-%s\n' "${LOG_DIR}" "${type}" "${slug}"
}

mode_log_dir() {
  local mode="$1"
  printf '%s/%s\n' "${COMPARE_LOG_DIR}" "${mode}"
}

run_script_with_log_dir() {
  local log_dir="$1"
  shift
  mkdir -p "${log_dir}"
  LOG_DIR="${log_dir}" "$@"
}

run_native_build_script() {
  local log_dir="$1"
  local script_path="$2"
  mkdir -p "${log_dir}"
  LOG_DIR="${log_dir}" \
    NATIVE_PGO_PROFILE="${NATIVE_PGO_PROFILE}" \
    NATIVE_PRESERVE="${NATIVE_PRESERVE_VALUE}" \
    NATIVE_ENABLE_SBOM="${NATIVE_SBOM_VALUE}" \
    NATIVE_ENABLE_OBFUSCATION="${NATIVE_ENABLE_OBFUSCATION_VALUE}" \
    NATIVE_EXTRA_ARGS="${NATIVE_EXTRA_ARGS_VALUE}" \
    "${script_path}"
}

train_instrumented_native_profile() {
  local log_dir="$1"
  local port="${NATIVE_TRAINING_PORT}"
  local log_file="${log_dir}/native-pgo-training.log"
  local pid

  require_command curl
  ensure_dependency_services
  free_port_if_occupied "${port}"
  : > "${log_file}"

  env APP_RUNTIME_MODE=native APP_JDK=25 APP_NAME=gateway-demo SERVER_PORT="${port}" \
    "$(native_executable)" > "${log_file}" 2>&1 &
  pid="$!"

  if ! wait_for_health "${port}" 160; then
    echo "Instrumented native app did not become healthy for PGO training. See ${log_file}" >&2
    stop_pid "${pid}"
    exit 1
  fi

  warm_gateway_endpoints "${port}" >> "${log_file}" 2>&1 || true
  if command -v k6 >/dev/null 2>&1; then
    K6_BASE_URL="http://127.0.0.1:${port}" k6 run \
      --vus "${NATIVE_TRAINING_VUS}" \
      --duration "${NATIVE_TRAINING_DURATION}" \
      "${ROOT_DIR}/load-tests/k6-gateway.js" >> "${log_file}" 2>&1 || true
  else
    for _ in $(seq 1 40); do
      warm_gateway_endpoints "${port}" >> "${log_file}" 2>&1 || true
    done
  fi

  stop_pid "${pid}"

  if [[ ! -f "${NATIVE_PGO_PROFILE}" ]]; then
    echo "PGO training completed, but no profile was written: ${NATIVE_PGO_PROFILE}" >&2
    exit 1
  fi
}

build_native_artifacts() {
  local native_log_dir
  native_log_dir="$(mode_log_dir native)"
  mkdir -p "${native_log_dir}"

  case "${NATIVE_BUILD_MODE}" in
    default)
      echo "Building native executable..."
      run_native_build_script "${native_log_dir}" "${ROOT_DIR}/scripts/native/01-build-native.sh"
      ;;
    pgo-instrument)
      echo "Building instrumented native executable..."
      run_native_build_script "${native_log_dir}" "${ROOT_DIR}/scripts/native/04-build-native-pgo-instrumented.sh"
      ;;
    pgo-optimize)
      echo "Building PGO-optimized native executable..."
      run_native_build_script "${native_log_dir}" "${ROOT_DIR}/scripts/native/05-build-native-pgo-optimized.sh"
      ;;
    pgo-auto)
      echo "Building instrumented native executable for PGO training..."
      run_native_build_script "${native_log_dir}" "${ROOT_DIR}/scripts/native/04-build-native-pgo-instrumented.sh"
      echo "Training native PGO profile with representative gateway traffic..."
      train_instrumented_native_profile "${native_log_dir}"
      echo "Rebuilding native executable with collected PGO profile..."
      run_native_build_script "${native_log_dir}" "${ROOT_DIR}/scripts/native/05-build-native-pgo-optimized.sh"
      ;;
  esac
}

start_compare_mode() {
  local mode="$1"
  local port="$2"
  local log_file="$3"

  case "${mode}" in
    baseline|cds|appcds|leyden-aot)
      start_standard_mode "${mode}" "${port}" "${log_file}" >/dev/null
      ;;
    crac)
      rm -rf "${ARTIFACT_DIR}/crac-checkpoint-monitoring"
      CRAC_MONITORING_LOG_DIR="$(dirname "${log_file}")" create_crac_checkpoint_for_monitoring "${port}" >/dev/null
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
    local mode_dir
    local log_file
    local pid
    local rss_startup_kb
    local first_latency_ms
    local warm_latency_ms
    local load_metrics
    local http_reqs_per_sec
    local http_req_p95_ms
    local rss_warmup_kb
    mode_dir="$(mode_log_dir "${mode}")"
    mkdir -p "${mode_dir}"
    log_file="${mode_dir}/compare-${mode}-${iteration}.log"

    start_compare_mode "${mode}" "${port}" "${log_file}"

    pid="$(cat "${PID_DIR}/${mode}.pid")"
    rss_startup_kb="$(rss_kb_for_pid "${pid}")"
    first_latency_ms="$(first_request_latency_ms "${port}")"
    warm_gateway_endpoints "${port}"
    sleep 1
    warm_latency_ms="$(request_latency_ms "${port}" "/api/products/789")"
    load_metrics="$(K6_LOG_DIR="${mode_dir}" run_k6_load "${mode}" "${port}" "${iteration}")"
    http_reqs_per_sec="${load_metrics%%,*}"
    http_req_p95_ms="${load_metrics#*,}"
    rss_warmup_kb="$(rss_kb_for_pid "${pid}")"
    append_benchmark_row "${mode}" "${iteration}" "${port}" "${pid}" "${log_file}" "${first_latency_ms}" "${rss_startup_kb}" "${rss_warmup_kb}" "${warm_latency_ms}" "${http_reqs_per_sec}" "${http_req_p95_ms}"
    stop_mode_if_running "${mode}"
    echo "${mode} iteration ${iteration}/${ITERATIONS:-3} complete"
  done
}

write_cold_summary() {
  local summary_file="${COMPARE_LOG_DIR}/compare-summary.md"
  mkdir -p "${COMPARE_LOG_DIR}"
  {
    echo "# Selected Mode Comparison"
    echo
    echo "- modes: ${MODES}"
    echo "- type: cold"
    echo "- iterations: ${ITERATIONS:-3}"
    if mode_selected native; then
      echo "- native build mode: ${NATIVE_BUILD_MODE}"
      if [[ -n "${NATIVE_PRESERVE_VALUE}" ]]; then
        echo "- native preserve: ${NATIVE_PRESERVE_VALUE}"
      fi
      if [[ -n "${NATIVE_SBOM_VALUE}" ]]; then
        echo "- native sbom: ${NATIVE_SBOM_VALUE}"
      fi
      echo "- native obfuscation: ${NATIVE_ENABLE_OBFUSCATION_VALUE}"
    fi
    echo
    echo "| Mode | Avg startup ms | Avg first request ms | Avg warm request ms | Avg RSS warmup KB | Avg dependency startup ms | Avg throughput rps | Avg HTTP p95 ms |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|"
    awk -F, -v modes="${MODES}" '
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
        ordered_count = split(modes, ordered_modes, ",")
        for (i = 1; i <= ordered_count; i++) {
          mode = ordered_modes[i]
          if (!(mode in count)) {
            continue
          }
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
  COMPARE_LOG_DIR="$(compare_log_dir "cold")"
  mkdir -p "${COMPARE_LOG_DIR}"
  build_required_artifacts
  free_selected_mode_ports
  start_monitoring_if_needed
  ITERATIONS="${ITERATIONS:-3}"
  MONITORING_RESULTS="${COMPARE_LOG_DIR}/benchmark-monitoring-results.txt"
  MONITORING_CSV="${COMPARE_LOG_DIR}/benchmark-monitoring-results.csv"
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

csv_metric_value() {
  local value="${1:-}"
  if [[ -z "${value}" ]]; then
    printf '0'
  else
    printf '%s' "${value}"
  fi
}

json_metric() {
  local summary_file="$1"
  local jq_expr="$2"
  local sed_expr="$3"
  if command -v jq >/dev/null 2>&1 && [[ -s "${summary_file}" ]]; then
    jq -r "${jq_expr} // 0" "${summary_file}"
  elif [[ -s "${summary_file}" ]]; then
    sed -n "${sed_expr}" "${summary_file}" | head -1
  else
    printf '0\n'
  fi
}

sample_long_mode_metrics() {
  local mode="$1"
  local port="$2"
  local pid="$3"
  local phase="$4"
  local started_epoch="$5"
  local iteration="$6"
  local samples_csv="$7"
  local elapsed_s="$(( $(date +%s) - started_epoch ))"
  local rss_kb heap_used nonheap_used cpu_usage threads_live gc_pause_count gc_pause_sum http_count

  rss_kb="$(rss_kb_for_pid "${pid}")"
  heap_used="$(metric_value "${port}" "jvm_memory_used_bytes" 'area="heap"')"
  nonheap_used="$(metric_value "${port}" "jvm_memory_used_bytes" 'area="nonheap"')"
  cpu_usage="$(metric_value "${port}" "process_cpu_usage")"
  threads_live="$(metric_value "${port}" "jvm_threads_live_threads")"
  gc_pause_count="$(metric_value "${port}" "jvm_gc_pause_seconds_count")"
  gc_pause_sum="$(metric_value "${port}" "jvm_gc_pause_seconds_sum")"
  http_count="$(metric_value "${port}" "http_server_requests_seconds_count")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${mode}" "${iteration}" "${phase}" "${elapsed_s}" \
    "$(csv_metric_value "${rss_kb}")" \
    "$(csv_metric_value "${heap_used}")" \
    "$(csv_metric_value "${nonheap_used}")" \
    "$(csv_metric_value "${cpu_usage}")" \
    "$(csv_metric_value "${threads_live}")" \
    "$(csv_metric_value "${gc_pause_count}")" \
    "$(csv_metric_value "${gc_pause_sum}")" \
    "$(csv_metric_value "${http_count}")" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${samples_csv}"
}

run_long_k6_phase() {
  local port="$1"
  local duration="$2"
  local summary_file="$3"
  local k6_log_file="$4"

  K6_BASE_URL="http://127.0.0.1:${port}" k6 run \
    --vus "${LONG_K6_VUS}" \
    --duration "${duration}" \
    --summary-export "${summary_file}" \
    "${ROOT_DIR}/load-tests/k6-gateway.js" \
    > "${k6_log_file}" 2>&1 &
  K6_PHASE_PID="$!"
}

monitor_long_k6_phase() {
  local mode="$1"
  local port="$2"
  local pid="$3"
  local phase="$4"
  local k6_pid="$5"
  local iteration="$6"
  local samples_csv="$7"
  local started_epoch
  started_epoch="$(date +%s)"

  while kill -0 "${k6_pid}" >/dev/null 2>&1; do
    sample_long_mode_metrics "${mode}" "${port}" "${pid}" "${phase}" "${started_epoch}" "${iteration}" "${samples_csv}"
    sleep "${LONG_SAMPLE_INTERVAL_SECONDS}"
  done
  wait "${k6_pid}"
  sample_long_mode_metrics "${mode}" "${port}" "${pid}" "${phase}" "${started_epoch}" "${iteration}" "${samples_csv}"
}

append_long_mode_summary() {
  local mode="$1"
  local startup_log="$2"
  local summary_file="$3"
  local iteration="$4"
  local samples_csv="$5"
  local summary_csv="$6"
  local process_startup_ms spring_boot_startup_ms throughput avg_ms p95_ms p99_ms max_ms failed_rate checks_rate image_size

  process_startup_ms="$(extract_startup_ms "${startup_log}")"
  spring_boot_startup_ms="$(extract_spring_startup_ms "${startup_log}")"
  throughput="$(json_metric "${summary_file}" '.metrics.http_reqs.rate' 's/.*"http_reqs".*"rate":\([0-9.]*\).*/\1/p')"
  avg_ms="$(json_metric "${summary_file}" '.metrics.http_req_duration.avg' 's/.*"http_req_duration".*"avg":\([0-9.]*\).*/\1/p')"
  p95_ms="$(json_metric "${summary_file}" '.metrics.http_req_duration."p(95)"' 's/.*"p(95)":\([0-9.]*\).*/\1/p')"
  p99_ms="$(json_metric "${summary_file}" '.metrics.http_req_duration."p(99)"' 's/.*"p(99)":\([0-9.]*\).*/\1/p')"
  max_ms="$(json_metric "${summary_file}" '.metrics.http_req_duration.max' 's/.*"max":\([0-9.]*\).*/\1/p')"
  failed_rate="$(json_metric "${summary_file}" '.metrics.http_req_failed.rate' 's/.*"http_req_failed".*"rate":\([0-9.]*\).*/\1/p')"
  checks_rate="$(json_metric "${summary_file}" '.metrics.checks.rate' 's/.*"checks".*"rate":\([0-9.]*\).*/\1/p')"
  image_size="$(image_size_bytes_for_mode "${mode}")"

  awk -F, -v mode="${mode}" -v iteration="${iteration}" '
    NR > 1 && $1 == mode && $2 == iteration && $3 == "measured" {
      count++
      rss += $5
      if ($5 > rss_max) rss_max = $5
      cpu += $8
      if ($8 > cpu_max) cpu_max = $8
      heap += $6
      if ($6 > heap_max) heap_max = $6
    }
    END {
      if (count == 0) {
        printf "0,0,0,0,0,0\n"
      } else {
        printf "%.3f,%.3f,%.6f,%.6f,%.3f,%.3f\n", rss / count, rss_max, cpu / count, cpu_max, heap / count, heap_max
      }
    }
  ' "${samples_csv}" | {
    IFS=, read -r avg_rss max_rss avg_cpu max_cpu avg_heap max_heap
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${mode}" "${iteration}" "${process_startup_ms:-0}" "${spring_boot_startup_ms:-0}" \
      "${throughput}" "${avg_ms}" "${p95_ms}" "${p99_ms}" "${max_ms}" \
      "${failed_rate}" "${checks_rate}" "${avg_rss}" "${max_rss}" \
      "${avg_cpu}" "${max_cpu}" "${avg_heap}" "${image_size:-0}" >> "${summary_csv}"
  }
}

run_one_long_mode() {
  local mode="$1"
  local iteration="$2"
  local results_dir="$3"
  local samples_csv="$4"
  local summary_csv="$5"
  local port pid startup_log warmup_summary warmup_log measured_summary measured_log

  local mode_dir
  mode_dir="${results_dir}/${mode}"
  mkdir -p "${mode_dir}"
  startup_log="${mode_dir}/${mode}-${iteration}-startup.log"
  warmup_summary="${mode_dir}/${mode}-${iteration}-warmup-k6.json"
  warmup_log="${mode_dir}/${mode}-${iteration}-warmup-k6.log"
  measured_summary="${mode_dir}/${mode}-${iteration}-measured-k6.json"
  measured_log="${mode_dir}/${mode}-${iteration}-measured-k6.log"
  port="$(port_for_mode "${mode}")"

  start_compare_mode "${mode}" "${port}" "${startup_log}"
  pid="$(cat "${PID_DIR}/${mode}.pid")"
  warm_gateway_endpoints "${port}"

  echo "${mode}: iteration ${iteration}/${ITERATIONS} warmup ${LONG_WARMUP_DURATION} with ${LONG_K6_VUS} VUs"
  run_long_k6_phase "${port}" "${LONG_WARMUP_DURATION}" "${warmup_summary}" "${warmup_log}"
  monitor_long_k6_phase "${mode}" "${port}" "${pid}" "warmup" "${K6_PHASE_PID}" "${iteration}" "${samples_csv}"

  echo "${mode}: iteration ${iteration}/${ITERATIONS} measured run ${LONG_DURATION} with ${LONG_K6_VUS} VUs"
  run_long_k6_phase "${port}" "${LONG_DURATION}" "${measured_summary}" "${measured_log}"
  monitor_long_k6_phase "${mode}" "${port}" "${pid}" "measured" "${K6_PHASE_PID}" "${iteration}" "${samples_csv}"

  append_long_mode_summary "${mode}" "${startup_log}" "${measured_summary}" "${iteration}" "${samples_csv}" "${summary_csv}"
  stop_mode_if_running "${mode}"
}

write_generic_long_summary() {
  local summary_csv="$1"
  local summary_md="$2"
  {
    echo "# Long Run Selected Modes"
    echo
    echo "- modes: ${MODES}"
    if mode_selected native; then
      echo "- native build mode: ${NATIVE_BUILD_MODE}"
    fi
    echo "- warmup: ${LONG_WARMUP_DURATION}"
    echo "- measured duration: ${LONG_DURATION}"
    echo "- iterations: ${ITERATIONS}"
    echo "- k6 VUs: ${LONG_K6_VUS}"
    echo "- sample interval seconds: ${LONG_SAMPLE_INTERVAL_SECONDS}"
    echo
    echo "| Mode | Iteration | Startup ms | Throughput rps | Avg ms | p95 ms | p99 ms | Failed rate | Avg RSS KB | Max RSS KB | Avg CPU | Image bytes |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    awk -F, 'NR > 1 {
      printf "| %s | %s | %.0f | %.2f | %.2f | %.2f | %.2f | %.5f | %.2f | %.2f | %.6f | %s |\n",
        $1, $2, $3, $5, $6, $7, $8, $10, $12, $13, $14, $17
    }' "${summary_csv}"
    echo
    echo "Averages:"
    echo
    echo "| Mode | Avg startup ms | Avg throughput rps | Avg p95 ms | Avg p99 ms | Avg RSS KB | Avg CPU |"
    echo "|---|---:|---:|---:|---:|---:|---:|"
    awk -F, 'NR > 1 {
      count[$1]++
      startup[$1]+=$3
      throughput[$1]+=$5
      p95[$1]+=$7
      p99[$1]+=$8
      rss[$1]+=$12
      cpu[$1]+=$14
    } END {
      ordered_count = split("'"${MODES}"'", ordered_modes, ",")
      for (i = 1; i <= ordered_count; i++) {
        mode = ordered_modes[i]
        if (!(mode in count)) {
          continue
        }
        printf "| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.6f |\n",
          mode, startup[mode]/count[mode], throughput[mode]/count[mode],
          p95[mode]/count[mode], p99[mode]/count[mode],
          rss[mode]/count[mode], cpu[mode]/count[mode]
      }
    }' "${summary_csv}"
  } > "${summary_md}"
}

run_generic_long_comparison() {
  LONG_WARMUP_DURATION="${LONG_WARMUP_DURATION:-60s}"
  LONG_DURATION="${LONG_DURATION:-10m}"
  LONG_K6_VUS="${LONG_K6_VUS:-8}"
  LONG_SAMPLE_INTERVAL_SECONDS="${LONG_SAMPLE_INTERVAL_SECONDS:-10}"

  local slug results_dir samples_csv summary_csv summary_md iteration mode
  slug="$(selected_modes_slug)"
  results_dir="${COMPARE_LOG_DIR}"
  samples_csv="${results_dir}/${slug}-samples.csv"
  summary_csv="${results_dir}/${slug}-summary.csv"
  summary_md="${results_dir}/${slug}-summary.md"
  mkdir -p "${results_dir}"

  : > "${samples_csv}"
  echo "mode,iteration,phase,elapsed_s,rss_kb,heap_used_bytes,nonheap_used_bytes,process_cpu_usage,threads_live,gc_pause_count,gc_pause_sum_seconds,http_request_count,observed_at" >> "${samples_csv}"
  : > "${summary_csv}"
  echo "mode,iteration,process_startup_ms,spring_boot_startup_ms,throughput_rps,http_avg_ms,http_p95_ms,http_p99_ms,http_max_ms,http_failed_rate,checks_rate,avg_rss_kb,max_rss_kb,avg_cpu,max_cpu,avg_heap_bytes,image_size_bytes" >> "${summary_csv}"

  for iteration in $(seq 1 "${ITERATIONS}"); do
    for mode in "${SELECTED_MODES[@]}"; do
      run_one_long_mode "${mode}" "${iteration}" "${results_dir}" "${samples_csv}" "${summary_csv}"
    done
  done

  write_generic_long_summary "${summary_csv}" "${summary_md}"
  cat <<MSG
Long-run selected-mode benchmark complete.

Summary: ${summary_md}
CSV:     ${summary_csv}
Samples: ${samples_csv}
MSG
}

run_generic_grafana_comparison() {
  LONG_DURATION="${LONG_DURATION:-30m}"
  LONG_K6_VUS="${LONG_K6_VUS:-8}"

  local slug results_dir mode port log_file summary_file k6_log_file pid_var k6_pids
  slug="$(selected_modes_slug)"
  results_dir="${COMPARE_LOG_DIR}"
  mkdir -p "${results_dir}"

  docker compose -f "${ROOT_DIR}/docker-compose.monitoring.yml" up -d prometheus grafana >/dev/null
  curl -fsS -X POST "http://localhost:9090/-/reload" >/dev/null || true

  echo "Starting selected modes for Grafana in requested order."
  for mode in "${SELECTED_MODES[@]}"; do
    port="$(port_for_mode "${mode}")"
    local mode_dir
    mode_dir="${results_dir}/${mode}"
    mkdir -p "${mode_dir}"
    log_file="${mode_dir}/${mode}-startup.log"
    start_compare_mode "${mode}" "${port}" "${log_file}"
    warm_gateway_endpoints "${port}"
    echo "${mode}: http://localhost:${port}"
  done

  echo "Running concurrent long workload for Grafana."
  echo "duration: ${LONG_DURATION}"
  echo "VUs per mode: ${LONG_K6_VUS}"

  k6_pids=""
  for mode in "${SELECTED_MODES[@]}"; do
    port="$(port_for_mode "${mode}")"
    local mode_dir
    mode_dir="${results_dir}/${mode}"
    mkdir -p "${mode_dir}"
    summary_file="${mode_dir}/${mode}-k6.json"
    k6_log_file="${mode_dir}/${mode}-k6.log"
    K6_BASE_URL="http://127.0.0.1:${port}" k6 run \
      --vus "${LONG_K6_VUS}" \
      --duration "${LONG_DURATION}" \
      --summary-export "${summary_file}" \
      "${ROOT_DIR}/load-tests/k6-gateway.js" \
      > "${k6_log_file}" 2>&1 &
    pid_var="$!"
    k6_pids="${k6_pids} ${pid_var}"
  done

  for pid_var in ${k6_pids}; do
    wait "${pid_var}"
  done

  cat <<MSG
Grafana long-run workload complete. Apps are still running for inspection.

Dashboard:
  http://localhost:3000

Grafana login:
  admin / admin

k6 summaries:
  ${results_dir}

Stop apps and containers:
  scripts/monitoring/02-stop-monitoring.sh
MSG
}

run_long_comparison() {
  require_command curl
  require_command k6
  COMPARE_LOG_DIR="$(compare_log_dir "long-run")"
  mkdir -p "${COMPARE_LOG_DIR}"
  build_required_artifacts
  free_selected_mode_ports
  start_monitoring_if_needed
  ITERATIONS="${ITERATIONS:-1}"
  run_generic_long_comparison
  if [[ "${START_MONITORING}" == "true" ]]; then
    cat <<MSG

Grafana:
  http://localhost:3000
MSG
  fi
}

run_grafana_comparison() {
  require_command curl
  require_command docker
  require_command k6
  COMPARE_LOG_DIR="$(compare_log_dir "long-run-grafana")"
  mkdir -p "${COMPARE_LOG_DIR}"
  build_required_artifacts
  free_selected_mode_ports
  run_generic_grafana_comparison
}

validate_type
validate_modes
validate_native_build_mode

case "${COMPARE_TYPE}" in
  cold) run_cold_comparison ;;
  long) run_long_comparison ;;
  grafana) run_grafana_comparison ;;
esac
