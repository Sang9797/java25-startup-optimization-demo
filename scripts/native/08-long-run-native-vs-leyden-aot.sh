#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

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
LONG_SAMPLES_CSV="${LONG_RESULTS_DIR}/native-vs-leyden-aot-samples.csv"
LONG_SUMMARY_CSV="${LONG_RESULTS_DIR}/native-vs-leyden-aot-summary.csv"
LONG_SUMMARY_MD="${LONG_RESULTS_DIR}/native-vs-leyden-aot-summary.md"
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
  local mode="$1"
  local port="$2"
  local pid="$3"
  local phase="$4"
  local started_epoch="$5"
  local iteration="$6"
  local now_epoch
  now_epoch="$(date +%s)"
  local elapsed_s="$((now_epoch - started_epoch))"
  local rss_kb
  local heap_used
  local nonheap_used
  local cpu_usage
  local threads_live
  local gc_pause_count
  local gc_pause_sum
  local http_count

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
  local mode="$1"
  local port="$2"
  local phase="$3"
  local duration="$4"
  local summary_file="$5"
  local k6_log_file="$6"

  K6_BASE_URL="http://127.0.0.1:${port}" k6 run \
    --vus "${LONG_K6_VUS}" \
    --duration "${duration}" \
    --summary-export "${summary_file}" \
    "${ROOT_DIR}/load-tests/k6-gateway.js" \
    > "${k6_log_file}" 2>&1 &
  K6_PHASE_PID="$!"
}

monitor_k6_phase() {
  local mode="$1"
  local port="$2"
  local pid="$3"
  local phase="$4"
  local k6_pid="$5"
  local iteration="$6"
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

append_mode_summary() {
  local mode="$1"
  local port="$2"
  local pid="$3"
  local startup_log="$4"
  local summary_file="$5"
  local iteration="$6"

  local process_startup_ms
  local spring_boot_startup_ms
  local throughput
  local avg_ms
  local p95_ms
  local p99_ms
  local max_ms
  local failed_rate
  local checks_rate
  local image_size

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
  local mode="$1"
  local iteration="$2"
  local port
  local pid
  local startup_log="${LONG_RESULTS_DIR}/${mode}-${iteration}-startup.log"
  local warmup_summary="${LONG_RESULTS_DIR}/${mode}-${iteration}-warmup-k6.json"
  local warmup_log="${LONG_RESULTS_DIR}/${mode}-${iteration}-warmup-k6.log"
  local measured_summary="${LONG_RESULTS_DIR}/${mode}-${iteration}-measured-k6.json"
  local measured_log="${LONG_RESULTS_DIR}/${mode}-${iteration}-measured-k6.log"

  port="$(port_for_mode "${mode}")"
  case "${mode}" in
    leyden-aot)
      start_standard_mode leyden-aot "${port}" "${startup_log}" >/dev/null
      ;;
    native)
      start_native_mode "${port}" "${startup_log}" >/dev/null
      ;;
    *)
      echo "Unsupported long-run mode: ${mode}" >&2
      exit 1
      ;;
  esac
  pid="$(cat "${PID_DIR}/${mode}.pid")"
  warm_gateway_endpoints "${port}"

  echo "${mode}: iteration ${iteration}/${LONG_ITERATIONS} warmup ${LONG_WARMUP_DURATION} with ${LONG_K6_VUS} VUs"
  run_k6_phase "${mode}" "${port}" "warmup" "${LONG_WARMUP_DURATION}" "${warmup_summary}" "${warmup_log}"
  monitor_k6_phase "${mode}" "${port}" "${pid}" "warmup" "${K6_PHASE_PID}" "${iteration}"

  echo "${mode}: iteration ${iteration}/${LONG_ITERATIONS} measured run ${LONG_DURATION} with ${LONG_K6_VUS} VUs"
  run_k6_phase "${mode}" "${port}" "measured" "${LONG_DURATION}" "${measured_summary}" "${measured_log}"
  monitor_k6_phase "${mode}" "${port}" "${pid}" "measured" "${K6_PHASE_PID}" "${iteration}"

  append_mode_summary "${mode}" "${port}" "${pid}" "${startup_log}" "${measured_summary}" "${iteration}"
  stop_mode_if_running "${mode}"
}

write_markdown_summary() {
  {
    echo "# Long Run Native vs Leyden AOT Cache"
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
        if (!("leyden-aot" in count) || !("native" in count)) {
          print "Verdict: incomplete data."
          exit
        }
        throughput["leyden-aot"]=throughput["leyden-aot"]/count["leyden-aot"]
        throughput["native"]=throughput["native"]/count["native"]
        p95["leyden-aot"]=p95["leyden-aot"]/count["leyden-aot"]
        p95["native"]=p95["native"]/count["native"]
        rss["leyden-aot"]=rss["leyden-aot"]/count["leyden-aot"]
        rss["native"]=rss["native"]/count["native"]
        print "Verdict:"
        if (throughput["native"] >= throughput["leyden-aot"]) {
          printf "- Native throughput is %.2f%% of Leyden AOT cache or better.\n", throughput["native"] / throughput["leyden-aot"] * 100
        } else {
          printf "- Native throughput is %.2f%% of Leyden AOT cache.\n", throughput["native"] / throughput["leyden-aot"] * 100
        }
        if (p95["native"] <= p95["leyden-aot"]) {
          printf "- Native p95 latency is %.2f%% of Leyden AOT cache or better.\n", p95["native"] / p95["leyden-aot"] * 100
        } else {
          printf "- Native p95 latency is %.2f%% of Leyden AOT cache.\n", p95["native"] / p95["leyden-aot"] * 100
        }
        if (rss["native"] <= rss["leyden-aot"]) {
          printf "- Native average RSS is %.2f%% of Leyden AOT cache or better.\n", rss["native"] / rss["leyden-aot"] * 100
        } else {
          printf "- Native average RSS is %.2f%% of Leyden AOT cache.\n", rss["native"] / rss["leyden-aot"] * 100
        }
      }
    ' "${LONG_SUMMARY_CSV}"
  } > "${LONG_SUMMARY_MD}"
}

: > "${LONG_SAMPLES_CSV}"
echo "mode,iteration,phase,elapsed_s,rss_kb,heap_used_bytes,nonheap_used_bytes,process_cpu_usage,threads_live,gc_pause_count,gc_pause_sum_seconds,http_request_count,observed_at" >> "${LONG_SAMPLES_CSV}"
: > "${LONG_SUMMARY_CSV}"
echo "mode,iteration,process_startup_ms,spring_boot_startup_ms,throughput_rps,http_avg_ms,http_p95_ms,http_p99_ms,http_max_ms,http_failed_rate,checks_rate,avg_rss_kb,max_rss_kb,avg_cpu,max_cpu,avg_heap_bytes,image_size_bytes" >> "${LONG_SUMMARY_CSV}"

for iteration in $(seq 1 "${LONG_ITERATIONS}"); do
  run_mode leyden-aot "${iteration}"
  run_mode native "${iteration}"
done
write_markdown_summary

cat <<MSG
Long-run native vs Leyden AOT cache benchmark complete.

Summary: ${LONG_SUMMARY_MD}
CSV:     ${LONG_SUMMARY_CSV}
Samples: ${LONG_SAMPLES_CSV}

Use longer settings for a stronger steady-state signal, for example:
  LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 scripts/native/08-long-run-native-vs-leyden-aot.sh
MSG
