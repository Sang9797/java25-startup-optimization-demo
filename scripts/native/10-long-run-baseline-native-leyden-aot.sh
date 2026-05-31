#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

COMPARE_TYPE="long"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      COMPARE_TYPE="${2:?--type requires long or grafana}"
      shift 2
      ;;
    --help|-h)
      cat <<'USAGE'
Usage:
  scripts/native/10-long-run-baseline-native-leyden-aot.sh [--type long|grafana]

Modes are fixed to baseline, leyden-aot, and native.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

case "${COMPARE_TYPE}" in
  long|grafana) ;;
  *)
    echo "Invalid type: ${COMPARE_TYPE}" >&2
    echo "Valid types: long,grafana" >&2
    exit 1
    ;;
esac

require_command curl
require_command k6
require_built_app
require_native_app
require_leyden_aot_support

if [[ ! -s "${LEYDEN_AOT_CACHE}" ]]; then
  echo "Leyden AOT cache not found. Generating it first..."
  "${ROOT_DIR}/scripts/11-generate-leyden-aot-cache.sh"
fi

LONG_WARMUP_DURATION="${LONG_WARMUP_DURATION:-60s}"
LONG_DURATION="${LONG_DURATION:-10m}"
LONG_K6_VUS="${LONG_K6_VUS:-8}"
LONG_SAMPLE_INTERVAL_SECONDS="${LONG_SAMPLE_INTERVAL_SECONDS:-10}"
LONG_ITERATIONS="${LONG_ITERATIONS:-${ITERATIONS:-1}}"

LONG_RESULTS_DIR="${LOG_DIR}/long-run"
LONG_SAMPLES_CSV="${LONG_RESULTS_DIR}/baseline-native-leyden-aot-samples.csv"
LONG_SUMMARY_CSV="${LONG_RESULTS_DIR}/baseline-native-leyden-aot-summary.csv"
LONG_SUMMARY_MD="${LONG_RESULTS_DIR}/baseline-native-leyden-aot-summary.md"

if [[ "${COMPARE_TYPE}" == "grafana" ]]; then
  LONG_RESULTS_DIR="${LOG_DIR}/long-run-grafana-baseline-native-leyden-aot"
  LONG_SUMMARY_MD="${LONG_RESULTS_DIR}/baseline-native-leyden-aot-grafana.md"
fi

mkdir -p "${LONG_RESULTS_DIR}"

csv_metric_value() {
  local value="${1:-}"
  if [[ -z "${value}" ]]; then
    printf '0'
  else
    printf '%s' "${value}"
  fi
}

sample_mode_metrics() {
  local mode="$1" port="$2" pid="$3" phase="$4" started_epoch="$5" iteration="$6"
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
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${LONG_SAMPLES_CSV}"
}

run_k6_phase() {
  local port="$1" duration="$2" summary_file="$3" k6_log_file="$4"
  K6_BASE_URL="http://127.0.0.1:${port}" k6 run \
    --vus "${LONG_K6_VUS}" \
    --duration "${duration}" \
    --summary-export "${summary_file}" \
    "${ROOT_DIR}/load-tests/k6-gateway.js" \
    > "${k6_log_file}" 2>&1 &
  K6_PHASE_PID="$!"
}

monitor_k6_phase() {
  local mode="$1" port="$2" pid="$3" phase="$4" k6_pid="$5" iteration="$6"
  local started_epoch
  started_epoch="$(date +%s)"
  while kill -0 "${k6_pid}" >/dev/null 2>&1; do
    sample_mode_metrics "${mode}" "${port}" "${pid}" "${phase}" "${started_epoch}" "${iteration}"
    sleep "${LONG_SAMPLE_INTERVAL_SECONDS}"
  done
  wait "${k6_pid}"
  sample_mode_metrics "${mode}" "${port}" "${pid}" "${phase}" "${started_epoch}" "${iteration}"
}

json_metric() {
  local summary_file="$1" jq_expr="$2" sed_expr="$3"
  if command -v jq >/dev/null 2>&1 && [[ -s "${summary_file}" ]]; then
    jq -r "${jq_expr} // 0" "${summary_file}"
  elif [[ -s "${summary_file}" ]]; then
    sed -n "${sed_expr}" "${summary_file}" | head -1
  else
    printf '0\n'
  fi
}

append_mode_summary() {
  local mode="$1" startup_log="$2" summary_file="$3" iteration="$4"
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
  ' "${LONG_SAMPLES_CSV}" | {
    IFS=, read -r avg_rss max_rss avg_cpu max_cpu avg_heap max_heap
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${mode}" "${iteration}" "${process_startup_ms:-0}" "${spring_boot_startup_ms:-0}" \
      "${throughput}" "${avg_ms}" "${p95_ms}" "${p99_ms}" "${max_ms}" \
      "${failed_rate}" "${checks_rate}" "${avg_rss}" "${max_rss}" \
      "${avg_cpu}" "${max_cpu}" "${avg_heap}" "${image_size:-0}" >> "${LONG_SUMMARY_CSV}"
  }
}

run_mode() {
  local mode="$1" iteration="$2" port pid startup_log warmup_summary warmup_log measured_summary measured_log
  startup_log="${LONG_RESULTS_DIR}/${mode}-${iteration}-startup.log"
  warmup_summary="${LONG_RESULTS_DIR}/${mode}-${iteration}-warmup-k6.json"
  warmup_log="${LONG_RESULTS_DIR}/${mode}-${iteration}-warmup-k6.log"
  measured_summary="${LONG_RESULTS_DIR}/${mode}-${iteration}-measured-k6.json"
  measured_log="${LONG_RESULTS_DIR}/${mode}-${iteration}-measured-k6.log"
  port="$(port_for_mode "${mode}")"

  case "${mode}" in
    baseline) start_standard_mode baseline "${port}" "${startup_log}" >/dev/null ;;
    leyden-aot) start_standard_mode leyden-aot "${port}" "${startup_log}" >/dev/null ;;
    native) start_native_mode "${port}" "${startup_log}" >/dev/null ;;
    *) echo "Unsupported long-run mode: ${mode}" >&2; exit 1 ;;
  esac

  pid="$(cat "${PID_DIR}/${mode}.pid")"
  warm_gateway_endpoints "${port}"
  echo "${mode}: iteration ${iteration}/${LONG_ITERATIONS} warmup ${LONG_WARMUP_DURATION} with ${LONG_K6_VUS} VUs"
  run_k6_phase "${port}" "${LONG_WARMUP_DURATION}" "${warmup_summary}" "${warmup_log}"
  monitor_k6_phase "${mode}" "${port}" "${pid}" "warmup" "${K6_PHASE_PID}" "${iteration}"
  echo "${mode}: iteration ${iteration}/${LONG_ITERATIONS} measured run ${LONG_DURATION} with ${LONG_K6_VUS} VUs"
  run_k6_phase "${port}" "${LONG_DURATION}" "${measured_summary}" "${measured_log}"
  monitor_k6_phase "${mode}" "${port}" "${pid}" "measured" "${K6_PHASE_PID}" "${iteration}"
  append_mode_summary "${mode}" "${startup_log}" "${measured_summary}" "${iteration}"
  stop_mode_if_running "${mode}"
}

write_markdown_summary() {
  {
    echo "# Long Run Baseline, Leyden AOT, and Native"
    echo
    echo "- warmup: ${LONG_WARMUP_DURATION}"
    echo "- measured duration: ${LONG_DURATION}"
    echo "- iterations: ${LONG_ITERATIONS}"
    echo "- k6 VUs: ${LONG_K6_VUS}"
    echo "- sample interval seconds: ${LONG_SAMPLE_INTERVAL_SECONDS}"
    echo
    echo "| Mode | Iteration | Startup ms | Throughput rps | Avg ms | p95 ms | p99 ms | Failed rate | Avg RSS KB | Max RSS KB | Avg CPU | Image bytes |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    awk -F, 'NR > 1 {
      printf "| %s | %s | %.0f | %.2f | %.2f | %.2f | %.2f | %.5f | %.2f | %.2f | %.6f | %s |\n",
        $1, $2, $3, $5, $6, $7, $8, $10, $12, $13, $14, $17
    }' "${LONG_SUMMARY_CSV}"
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
      for (mode in count) {
        printf "| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.6f |\n",
          mode, startup[mode]/count[mode], throughput[mode]/count[mode],
          p95[mode]/count[mode], p99[mode]/count[mode],
          rss[mode]/count[mode], cpu[mode]/count[mode]
      }
    }' "${LONG_SUMMARY_CSV}"
    echo
    awk -F, '
      NR > 1 {
        throughput[$1]+=$5
        p95[$1]+=$7
        rss[$1]+=$12
        count[$1]++
      }
      END {
        if (!("baseline" in count) || !("leyden-aot" in count) || !("native" in count)) {
          print "Verdict: incomplete data."
          exit
        }
        throughput["baseline"]=throughput["baseline"]/count["baseline"]
        throughput["leyden-aot"]=throughput["leyden-aot"]/count["leyden-aot"]
        throughput["native"]=throughput["native"]/count["native"]
        p95["baseline"]=p95["baseline"]/count["baseline"]
        p95["leyden-aot"]=p95["leyden-aot"]/count["leyden-aot"]
        p95["native"]=p95["native"]/count["native"]
        rss["baseline"]=rss["baseline"]/count["baseline"]
        rss["leyden-aot"]=rss["leyden-aot"]/count["leyden-aot"]
        rss["native"]=rss["native"]/count["native"]
        print "Verdict:"
        printf "- Native throughput is %.2f%% of baseline.\n", throughput["native"] / throughput["baseline"] * 100
        printf "- Native throughput is %.2f%% of Leyden AOT cache.\n", throughput["native"] / throughput["leyden-aot"] * 100
        printf "- Native p95 latency is %.2f%% of baseline.\n", p95["native"] / p95["baseline"] * 100
        printf "- Native p95 latency is %.2f%% of Leyden AOT cache.\n", p95["native"] / p95["leyden-aot"] * 100
        printf "- Native average RSS is %.2f%% of baseline.\n", rss["native"] / rss["baseline"] * 100
        printf "- Native average RSS is %.2f%% of Leyden AOT cache.\n", rss["native"] / rss["leyden-aot"] * 100
      }
    ' "${LONG_SUMMARY_CSV}"
  } > "${LONG_SUMMARY_MD}"
}

run_long_comparison() {
  : > "${LONG_SAMPLES_CSV}"
  echo "mode,iteration,phase,elapsed_s,rss_kb,heap_used_bytes,nonheap_used_bytes,process_cpu_usage,threads_live,gc_pause_count,gc_pause_sum_seconds,http_request_count,observed_at" >> "${LONG_SAMPLES_CSV}"
  : > "${LONG_SUMMARY_CSV}"
  echo "mode,iteration,process_startup_ms,spring_boot_startup_ms,throughput_rps,http_avg_ms,http_p95_ms,http_p99_ms,http_max_ms,http_failed_rate,checks_rate,avg_rss_kb,max_rss_kb,avg_cpu,max_cpu,avg_heap_bytes,image_size_bytes" >> "${LONG_SUMMARY_CSV}"

  for iteration in $(seq 1 "${LONG_ITERATIONS}"); do
    run_mode baseline "${iteration}"
    run_mode leyden-aot "${iteration}"
    run_mode native "${iteration}"
  done

  write_markdown_summary
  cat <<MSG
Long-run baseline, Leyden AOT, and native benchmark complete.

Summary: ${LONG_SUMMARY_MD}
CSV:     ${LONG_SUMMARY_CSV}
Samples: ${LONG_SAMPLES_CSV}
MSG
}

run_grafana_comparison() {
  require_command docker
  local grafana_dir="${LOG_DIR}/long-run-grafana-baseline-native-leyden-aot"
  mkdir -p "${grafana_dir}"

  local baseline_port leyden_port native_port baseline_log leyden_log native_log
  local baseline_k6_summary leyden_k6_summary native_k6_summary baseline_k6_log leyden_k6_log native_k6_log
  baseline_port="$(port_for_mode baseline)"
  leyden_port="$(port_for_mode leyden-aot)"
  native_port="$(port_for_mode native)"
  baseline_log="${grafana_dir}/baseline-startup.log"
  leyden_log="${grafana_dir}/leyden-aot-startup.log"
  native_log="${grafana_dir}/native-startup.log"
  baseline_k6_summary="${grafana_dir}/baseline-k6.json"
  leyden_k6_summary="${grafana_dir}/leyden-aot-k6.json"
  native_k6_summary="${grafana_dir}/native-k6.json"
  baseline_k6_log="${grafana_dir}/baseline-k6.log"
  leyden_k6_log="${grafana_dir}/leyden-aot-k6.log"
  native_k6_log="${grafana_dir}/native-k6.log"

  docker compose -f "${ROOT_DIR}/docker-compose.monitoring.yml" up -d prometheus grafana >/dev/null
  curl -fsS -X POST "http://localhost:9090/-/reload" >/dev/null || true

  start_standard_mode baseline "${baseline_port}" "${baseline_log}" >/dev/null
  start_standard_mode leyden-aot "${leyden_port}" "${leyden_log}" >/dev/null
  start_native_mode "${native_port}" "${native_log}" >/dev/null
  warm_gateway_endpoints "${baseline_port}"
  warm_gateway_endpoints "${leyden_port}"
  warm_gateway_endpoints "${native_port}"

  echo "Running concurrent long workload for Grafana."
  echo "baseline:   http://localhost:${baseline_port}"
  echo "leyden-aot: http://localhost:${leyden_port}"
  echo "native:     http://localhost:${native_port}"
  echo "duration: ${LONG_DURATION}"
  echo "VUs per mode: ${LONG_K6_VUS}"

  K6_BASE_URL="http://127.0.0.1:${baseline_port}" k6 run --vus "${LONG_K6_VUS}" --duration "${LONG_DURATION}" --summary-export "${baseline_k6_summary}" "${ROOT_DIR}/load-tests/k6-gateway.js" > "${baseline_k6_log}" 2>&1 &
  local baseline_pid="$!"
  K6_BASE_URL="http://127.0.0.1:${leyden_port}" k6 run --vus "${LONG_K6_VUS}" --duration "${LONG_DURATION}" --summary-export "${leyden_k6_summary}" "${ROOT_DIR}/load-tests/k6-gateway.js" > "${leyden_k6_log}" 2>&1 &
  local leyden_pid="$!"
  K6_BASE_URL="http://127.0.0.1:${native_port}" k6 run --vus "${LONG_K6_VUS}" --duration "${LONG_DURATION}" --summary-export "${native_k6_summary}" "${ROOT_DIR}/load-tests/k6-gateway.js" > "${native_k6_log}" 2>&1 &
  local native_pid="$!"

  wait "${baseline_pid}"
  wait "${leyden_pid}"
  wait "${native_pid}"

  cat <<MSG
Grafana long-run workload complete. Apps are still running for inspection.

Dashboard:
  http://localhost:3000/d/long-run-baseline-native-leyden-aot/long-run-baseline-native-leyden-aot

Grafana login:
  admin / admin
MSG
}

case "${COMPARE_TYPE}" in
  long) run_long_comparison ;;
  grafana) run_grafana_comparison ;;
esac
