#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

require_native_app
require_command curl

ITERATIONS="${ITERATIONS:-5}"
RESULTS="${LOG_DIR}/benchmark-native-results.txt"
CSV="${LOG_DIR}/benchmark-native-results.csv"
: > "${RESULTS}"
echo "mode,iteration,process_startup_ms,spring_boot_startup_ms,first_request_latency_ms,warm_request_latency_ms,rss_after_startup_kb,rss_after_warmup_kb,heap_used_bytes,nonheap_used_bytes,loaded_classes,threads_live,gc_pause_count,gc_pause_sum_seconds,process_cpu_usage,http_reqs_per_sec,http_req_p95_ms,image_size_bytes,log_file" > "${CSV}"

old_results="${MONITORING_RESULTS}"
old_csv="${MONITORING_CSV}"
MONITORING_RESULTS="${RESULTS}"
MONITORING_CSV="${CSV}"

mode="native"
port="$(port_for_mode native)"
for iteration in $(seq 1 "${ITERATIONS}"); do
  log_file="${LOG_DIR}/benchmark-native-${iteration}.log"
  start_native_mode "${port}" "${log_file}" >/dev/null
  pid="$(cat "${PID_DIR}/native.pid")"
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
  echo "native iteration ${iteration}/${ITERATIONS} complete"
done

MONITORING_RESULTS="${old_results}"
MONITORING_CSV="${old_csv}"
echo "Native benchmark results: ${RESULTS}"
echo "Native benchmark CSV: ${CSV}"
