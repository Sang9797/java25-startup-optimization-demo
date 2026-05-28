#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-monitoring.sh"

require_command curl
require_built_app

ITERATIONS="${ITERATIONS:-5}"
append_benchmark_header

benchmark_standard_mode() {
  local mode="$1"
  local port
  port="$(port_for_mode "${mode}")"

  for iteration in $(seq 1 "${ITERATIONS}"); do
    local log_file="${LOG_DIR}/benchmark-monitoring-${mode}-${iteration}.log"
    local pid
    start_standard_mode "${mode}" "${port}" "${log_file}" >/dev/null
    pid="$(cat "${PID_DIR}/${mode}.pid")"
    local rss_startup_kb
    rss_startup_kb="$(rss_kb_for_pid "${pid}")"
    local first_latency_ms
    first_latency_ms="$(first_request_latency_ms "${port}")"
    warm_gateway_endpoints "${port}"
    sleep 1
    local warm_latency_ms
    warm_latency_ms="$(request_latency_ms "${port}" "/api/products/789")"
    local load_metrics
    load_metrics="$(run_k6_load "${mode}" "${port}" "${iteration}")"
    local http_reqs_per_sec="${load_metrics%%,*}"
    local http_req_p95_ms="${load_metrics#*,}"
    local rss_warmup_kb
    rss_warmup_kb="$(rss_kb_for_pid "${pid}")"
    append_benchmark_row "${mode}" "${iteration}" "${port}" "${pid}" "${log_file}" "${first_latency_ms}" "${rss_startup_kb}" "${rss_warmup_kb}" "${warm_latency_ms}" "${http_reqs_per_sec}" "${http_req_p95_ms}"
    stop_mode_if_running "${mode}"
    echo "${mode} iteration ${iteration}/${ITERATIONS} complete"
  done
}

benchmark_crac_mode() {
  local mode="crac"
  local port
  port="$(port_for_mode "${mode}")"

  for iteration in $(seq 1 "${ITERATIONS}"); do
    rm -rf "${ARTIFACT_DIR}/crac-checkpoint-monitoring"
    create_crac_checkpoint_for_monitoring "${port}" >/dev/null
    local log_file="${LOG_DIR}/benchmark-monitoring-crac-${iteration}.log"
    local pid
    local restore_start_ns
    local restore_end_ns
    restore_start_ns="$(date +%s%N)"
    start_crac_restore_mode "${port}" "${log_file}" >/dev/null
    pid="$(cat "${PID_DIR}/crac.pid")"
    restore_end_ns="$(date +%s%N)"
    local restore_ms
    restore_ms="$(((restore_end_ns - restore_start_ns) / 1000000))"
    echo "{\"event\":\"crac restore measured\",\"startupTimeMillis\":${restore_ms},\"springBootStartupTimeMillis\":-1}" >> "${log_file}"
    local rss_startup_kb
    rss_startup_kb="$(rss_kb_for_pid "${pid}")"
    local first_latency_ms
    first_latency_ms="$(first_request_latency_ms "${port}")"
    warm_gateway_endpoints "${port}"
    sleep 1
    local warm_latency_ms
    warm_latency_ms="$(request_latency_ms "${port}" "/api/products/789")"
    local load_metrics
    load_metrics="$(run_k6_load "${mode}" "${port}" "${iteration}")"
    local http_reqs_per_sec="${load_metrics%%,*}"
    local http_req_p95_ms="${load_metrics#*,}"
    local rss_warmup_kb
    rss_warmup_kb="$(rss_kb_for_pid "${pid}")"
    append_benchmark_row "${mode}" "${iteration}" "${port}" "${pid}" "${log_file}" "${first_latency_ms}" "${rss_startup_kb}" "${rss_warmup_kb}" "${warm_latency_ms}" "${http_reqs_per_sec}" "${http_req_p95_ms}"
    stop_mode_if_running "${mode}"
    echo "crac iteration ${iteration}/${ITERATIONS} complete"
  done
}

benchmark_native_mode() {
  local mode="native"
  local port
  port="$(port_for_mode "${mode}")"

  for iteration in $(seq 1 "${ITERATIONS}"); do
    local log_file="${LOG_DIR}/benchmark-monitoring-native-${iteration}.log"
    local pid
    start_native_mode "${port}" "${log_file}" >/dev/null
    pid="$(cat "${PID_DIR}/native.pid")"
    local rss_startup_kb
    rss_startup_kb="$(rss_kb_for_pid "${pid}")"
    local first_latency_ms
    first_latency_ms="$(first_request_latency_ms "${port}")"
    warm_gateway_endpoints "${port}"
    sleep 1
    local warm_latency_ms
    warm_latency_ms="$(request_latency_ms "${port}" "/api/products/789")"
    local load_metrics
    load_metrics="$(run_k6_load "${mode}" "${port}" "${iteration}")"
    local http_reqs_per_sec="${load_metrics%%,*}"
    local http_req_p95_ms="${load_metrics#*,}"
    local rss_warmup_kb
    rss_warmup_kb="$(rss_kb_for_pid "${pid}")"
    append_benchmark_row "${mode}" "${iteration}" "${port}" "${pid}" "${log_file}" "${first_latency_ms}" "${rss_startup_kb}" "${rss_warmup_kb}" "${warm_latency_ms}" "${http_reqs_per_sec}" "${http_req_p95_ms}"
    stop_mode_if_running "${mode}"
    echo "native iteration ${iteration}/${ITERATIONS} complete"
  done
}

benchmark_standard_mode baseline

if [[ -f "${ARTIFACT_DIR}/cds-base.jsa" ]]; then
  benchmark_standard_mode cds
else
  echo "Skipping cds: missing ${ARTIFACT_DIR}/cds-base.jsa" | tee -a "${MONITORING_RESULTS}"
fi

if [[ -f "${ARTIFACT_DIR}/appcds.jsa" ]]; then
  benchmark_standard_mode appcds
else
  echo "Skipping appcds: missing ${ARTIFACT_DIR}/appcds.jsa" | tee -a "${MONITORING_RESULTS}"
fi

if java -XX:CRaCCheckpointTo=/tmp/crac-probe -version >/dev/null 2>&1; then
  benchmark_crac_mode
else
  echo "Skipping crac: current JDK does not support CRaC flags" | tee -a "${MONITORING_RESULTS}"
fi

if [[ -x "$(native_executable)" ]]; then
  benchmark_native_mode
else
  echo "Skipping native: missing $(native_executable)" | tee -a "${MONITORING_RESULTS}"
fi

cat <<MSG
Monitored benchmark complete.

Text results: ${MONITORING_RESULTS}
CSV results:  ${MONITORING_CSV}

Next:
  scripts/monitoring/01-start-monitoring.sh
  Open Grafana at http://localhost:3000
MSG
