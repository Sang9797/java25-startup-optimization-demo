#!/usr/bin/env bash

MONITORING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MONITORING_DIR}/../common.sh"

PID_DIR="${ARTIFACT_DIR}/pids"
MONITORING_RESULTS="${LOG_DIR}/benchmark-monitoring-results.txt"
MONITORING_CSV="${LOG_DIR}/benchmark-monitoring-results.csv"
mkdir -p "${PID_DIR}"

port_for_mode() {
  case "$1" in
    baseline) printf '8081\n' ;;
    cds) printf '8082\n' ;;
    appcds) printf '8083\n' ;;
    crac) printf '8084\n' ;;
    native) printf '8085\n' ;;
    leyden-aot) printf '8086\n' ;;
    *) printf '%s\n' "${APP_PORT}" ;;
  esac
}

archive_args_for_mode() {
  case "$1" in
    baseline) ;;
    cds) printf '%s\n' "-Xshare:on -XX:SharedArchiveFile=${ARTIFACT_DIR}/cds-base.jsa" ;;
    appcds) printf '%s\n' "-Xshare:on -XX:SharedArchiveFile=${ARTIFACT_DIR}/appcds.jsa" ;;
    leyden-aot) printf '%s\n' "-XX:AOTCache=${LEYDEN_AOT_CACHE}" ;;
    *) ;;
  esac
}

require_archive_for_mode() {
  case "$1" in
    cds)
      [[ -f "${ARTIFACT_DIR}/cds-base.jsa" ]] || {
        echo "Missing CDS archive. Run scripts/03-generate-cds-archive.sh first." >&2
        exit 1
      }
      ;;
    appcds)
      [[ -f "${ARTIFACT_DIR}/appcds.jsa" ]] || {
        echo "Missing AppCDS archive. Run scripts/05-generate-appcds-classlist.sh and scripts/06-generate-appcds-archive.sh first." >&2
        exit 1
      }
      ;;
    leyden-aot)
      require_leyden_aot_support
      [[ -s "${LEYDEN_AOT_CACHE}" ]] || {
        echo "Missing Leyden AOT cache. Run scripts/11-generate-leyden-aot-cache.sh first." >&2
        exit 1
      }
      ;;
  esac
}

stop_mode_if_running() {
  local mode="$1"
  local pid_file="${PID_DIR}/${mode}.pid"
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"
    stop_pid "${pid}"
    rm -f "${pid_file}"
  fi
}

start_mode_process() {
  local mode="$1"
  local port="$2"
  local log_file="$3"
  shift 3

  ensure_dependency_services
  stop_mode_if_running "${mode}"
  : > "${log_file}"
  setsid "$@" > "${log_file}" 2>&1 < /dev/null &
  local pid="$!"
  echo "${pid}" > "${PID_DIR}/${mode}.pid"

  if ! wait_for_health "${port}" 160; then
    echo "Mode ${mode} did not become healthy. See ${log_file}" >&2
    stop_pid "${pid}"
    rm -f "${PID_DIR}/${mode}.pid"
    return 1
  fi

  printf '%s\n' "${pid}"
}

start_standard_mode() {
  local mode="$1"
  local port="$2"
  local log_file="$3"
  require_built_app
  require_archive_for_mode "${mode}"
  local archive_args
  archive_args="$(archive_args_for_mode "${mode}")"

  if [[ "${mode}" == "leyden-aot" ]]; then
    # shellcheck disable=SC2086
    start_mode_process "${mode}" "${port}" "${log_file}" \
      env APP_RUNTIME_MODE="${mode}" APP_JDK=25 APP_NAME=gateway-demo \
      java ${archive_args} -Xlog:class+load=info -Ddemo.port="${port}" -jar "$(app_boot_jar)"
  elif [[ "${mode}" == "appcds" ]]; then
    # shellcheck disable=SC2086
    start_mode_process "${mode}" "${port}" "${log_file}" \
      env APP_RUNTIME_MODE="${mode}" APP_JDK=25 APP_NAME=gateway-demo \
      java ${archive_args} -Xlog:class+load=info -Ddemo.port="${port}" -cp "$(appcds_classpath)" \
      "${MAIN_CLASS}"
  else
    local cp
    cp="$(app_classpath)"
    # shellcheck disable=SC2086
    start_mode_process "${mode}" "${port}" "${log_file}" \
      env APP_RUNTIME_MODE="${mode}" APP_JDK=25 APP_NAME=gateway-demo \
      java ${archive_args} -Xlog:class+load=info -Ddemo.port="${port}" -cp "${cp}" "${MAIN_CLASS}"
  fi
}

create_crac_checkpoint_for_monitoring() {
  require_command jcmd
  require_built_app
  local port="$1"
  local checkpoint_dir="${ARTIFACT_DIR}/crac-checkpoint-monitoring"
  local log_file="${LOG_DIR}/monitoring-crac-checkpoint.log"
  local cp
  cp="$(app_classpath)"
  rm -rf "${checkpoint_dir}"
  mkdir -p "${checkpoint_dir}"
  : > "${log_file}"

  env APP_RUNTIME_MODE=crac APP_JDK=25 APP_NAME=gateway-demo \
    java -XX:CRaCCheckpointTo="${checkpoint_dir}" -Ddemo.port="${port}" -cp "${cp}" "${MAIN_CLASS}" \
    > "${log_file}" 2>&1 &
  local pid="$!"

  if ! wait_for_health "${port}" 160; then
    echo "CRaC checkpoint app did not become healthy. See ${log_file}" >&2
    stop_pid "${pid}"
    return 1
  fi

  warm_gateway_endpoints "${port}" >> "${log_file}" 2>&1 || true
  jcmd "${pid}" JDK.checkpoint >> "${log_file}" 2>&1 || {
    echo "CRaC checkpoint failed. See ${log_file}" >&2
    stop_pid "${pid}"
    return 1
  }
  wait "${pid}" >/dev/null 2>&1 || true
  printf '%s\n' "${checkpoint_dir}"
}

start_crac_restore_mode() {
  local port="$1"
  local log_file="$2"
  local checkpoint_dir="${ARTIFACT_DIR}/crac-checkpoint-monitoring"
  if [[ ! -d "${checkpoint_dir}" ]]; then
    create_crac_checkpoint_for_monitoring "${port}" >/dev/null
  fi

  start_mode_process "crac" "${port}" "${log_file}" \
    env APP_RUNTIME_MODE=crac APP_JDK=25 APP_NAME=gateway-demo \
    java -XX:CRaCRestoreFrom="${checkpoint_dir}"
}

native_executable() {
  printf '%s\n' "${ROOT_DIR}/build/native/gateway-native"
}

require_native_app() {
  local exe
  exe="$(native_executable)"
  if [[ ! -x "${exe}" ]]; then
    echo "Native executable not found: ${exe}" >&2
    echo "Run scripts/native/01-build-native.sh first." >&2
    exit 1
  fi
}

start_native_mode() {
  local port="$1"
  local log_file="$2"
  require_native_app
  local exe
  exe="$(native_executable)"
  start_mode_process "native" "${port}" "${log_file}" \
    env APP_RUNTIME_MODE=native APP_JDK=25 APP_NAME=gateway-demo SERVER_PORT="${port}" \
    SPRING_AUTOCONFIGURE_EXCLUDE=org.springframework.boot.autoconfigure.jdbc.DataSourceCheckpointRestoreConfiguration \
    "${exe}"
}

first_request_latency_ms() {
  local port="$1"
  local start_ns
  local end_ns
  start_ns="$(date +%s%N)"
  curl -fsS "http://127.0.0.1:${port}/api/users/123" >/dev/null
  end_ns="$(date +%s%N)"
  echo "$(((end_ns - start_ns) / 1000000))"
}

metric_value() {
  local port="$1"
  local metric="$2"
  local selector="${3:-}"
  local metrics
  metrics="$(curl -fsS "http://127.0.0.1:${port}/actuator/prometheus" 2>/dev/null || true)"
  printf '%s\n' "${metrics}" |
    awk -v metric="${metric}" -v selector="${selector}" '
      $0 !~ /^#/ && index($0, metric) == 1 {
        if (selector == "" || index($0, selector) > 0) {
          print $NF
          exit
        }
      }'
}

rss_kb_for_pid() {
  local pid="$1"
  ps -o rss= -p "${pid}" | tr -d ' '
}

class_count_from_log() {
  local log_file="$1"
  grep -c "class,load" "${log_file}" 2>/dev/null || true
}

append_benchmark_header() {
  : > "${MONITORING_RESULTS}"
  : > "${MONITORING_CSV}"
  echo "Java 25 Spring Boot monitored startup benchmark" >> "${MONITORING_RESULTS}"
  echo "date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${MONITORING_RESULTS}"
  echo "mode,iteration,process_startup_ms,spring_boot_startup_ms,first_request_latency_ms,warm_request_latency_ms,rss_after_startup_kb,rss_after_warmup_kb,heap_used_bytes,nonheap_used_bytes,loaded_classes,threads_live,gc_pause_count,gc_pause_sum_seconds,process_cpu_usage,dependency_postgres_startup_ms,dependency_redis_startup_ms,dependency_kafka_startup_ms,dependency_total_startup_ms,http_reqs_per_sec,http_req_p95_ms,image_size_bytes,log_file" >> "${MONITORING_CSV}"
}

request_latency_ms() {
  local port="$1"
  local path="${2:-/api/products/789}"
  local start_ns
  local end_ns
  start_ns="$(date +%s%N)"
  curl -fsS "http://127.0.0.1:${port}${path}" >/dev/null
  end_ns="$(date +%s%N)"
  echo "$(((end_ns - start_ns) / 1000000))"
}

image_size_bytes_for_mode() {
  local mode="$1"
  case "${mode}" in
    native)
      local exe
      exe="$(native_executable)"
      [[ -f "${exe}" ]] && stat -c '%s' "${exe}" 2>/dev/null || true
      ;;
    *)
      if [[ -f "${APP_JAR}" ]]; then
        local total
        total="$(stat -c '%s' "${APP_JAR}" 2>/dev/null || echo 0)"
        if [[ -d "${TARGET_DIR}/lib" ]]; then
          while IFS= read -r size; do
            total="$((total + size))"
          done < <(find "${TARGET_DIR}/lib" -type f -name '*.jar' -printf '%s\n')
        fi
        printf '%s\n' "${total}"
      fi
      ;;
  esac
}

run_k6_load() {
  local mode="$1"
  local port="$2"
  local iteration="$3"
  local summary_file="${LOG_DIR}/k6-${mode}-${iteration}.json"
  local log_file="${LOG_DIR}/k6-${mode}-${iteration}.log"
  if ! command -v k6 >/dev/null 2>&1; then
    echo ","
    return 0
  fi
  K6_BASE_URL="http://127.0.0.1:${port}" k6 run \
    --vus "${K6_VUS:-4}" \
    --duration "${K6_DURATION:-5s}" \
    --summary-export "${summary_file}" \
    "${ROOT_DIR}/load-tests/k6-gateway.js" \
    > "${log_file}" 2>&1 || true

  local rate=""
  local p95=""
  if command -v jq >/dev/null 2>&1 && [[ -s "${summary_file}" ]]; then
    rate="$(jq -r '.metrics.http_reqs.rate // empty' "${summary_file}")"
    p95="$(jq -r '.metrics.http_req_duration."p(95)" // empty' "${summary_file}")"
  elif [[ -s "${summary_file}" ]]; then
    rate="$(sed -n 's/.*"http_reqs".*"rate":\([0-9.]*\).*/\1/p' "${summary_file}" | head -1)"
    p95="$(sed -n 's/.*"p(95)":\([0-9.]*\).*/\1/p' "${summary_file}" | head -1)"
  fi
  echo "${rate},${p95}"
}

append_benchmark_row() {
  local mode="$1"
  local iteration="$2"
  local port="$3"
  local pid="$4"
  local log_file="$5"
  local first_latency_ms="$6"
  local rss_startup_kb="$7"
  local rss_warmup_kb="$8"
  local warm_latency_ms="${9:-}"
  local http_reqs_per_sec="${10:-}"
  local http_req_p95_ms="${11:-}"

  local process_startup_ms
  local spring_boot_startup_ms
  local heap_used
  local nonheap_used
  local loaded_classes
  local threads_live
  local gc_pause_count
  local gc_pause_sum
  local cpu_usage
  local dependency_postgres_ms
  local dependency_redis_ms
  local dependency_kafka_ms
  local dependency_total_ms

  process_startup_ms="$(extract_startup_ms "${log_file}")"
  spring_boot_startup_ms="$(extract_spring_startup_ms "${log_file}")"
  heap_used="$(metric_value "${port}" "jvm_memory_used_bytes" 'area="heap"')"
  nonheap_used="$(metric_value "${port}" "jvm_memory_used_bytes" 'area="nonheap"')"
  loaded_classes="$(metric_value "${port}" "jvm_classes_loaded_classes")"
  threads_live="$(metric_value "${port}" "jvm_threads_live_threads")"
  gc_pause_count="$(metric_value "${port}" "jvm_gc_pause_seconds_count")"
  gc_pause_sum="$(metric_value "${port}" "jvm_gc_pause_seconds_sum")"
  cpu_usage="$(metric_value "${port}" "process_cpu_usage")"
  dependency_postgres_ms="$(metric_value "${port}" "app_dependency_postgres_startup_ms")"
  dependency_redis_ms="$(metric_value "${port}" "app_dependency_redis_startup_ms")"
  dependency_kafka_ms="$(metric_value "${port}" "app_dependency_kafka_startup_ms")"
  dependency_total_ms="$(metric_value "${port}" "app_dependency_total_startup_ms")"
  local image_size_bytes
  image_size_bytes="$(image_size_bytes_for_mode "${mode}")"

  {
    echo "mode=${mode} iteration=${iteration}"
    echo "  processStartupMs=${process_startup_ms:-unknown}"
    echo "  springBootStartupMs=${spring_boot_startup_ms:-unknown}"
    echo "  firstRequestLatencyMs=${first_latency_ms}"
    echo "  warmRequestLatencyMs=${warm_latency_ms:-unknown}"
    echo "  rssAfterStartupKb=${rss_startup_kb}"
    echo "  rssAfterWarmupKb=${rss_warmup_kb}"
    echo "  heapUsedBytes=${heap_used:-unknown}"
    echo "  nonHeapUsedBytes=${nonheap_used:-unknown}"
    echo "  loadedClasses=${loaded_classes:-unknown}"
    echo "  threadsLive=${threads_live:-unknown}"
    echo "  gcPauseCount=${gc_pause_count:-unknown}"
    echo "  gcPauseSumSeconds=${gc_pause_sum:-unknown}"
    echo "  processCpuUsage=${cpu_usage:-unknown}"
    echo "  dependencyPostgresStartupMs=${dependency_postgres_ms:-unknown}"
    echo "  dependencyRedisStartupMs=${dependency_redis_ms:-unknown}"
    echo "  dependencyKafkaStartupMs=${dependency_kafka_ms:-unknown}"
    echo "  dependencyTotalStartupMs=${dependency_total_ms:-unknown}"
    echo "  httpReqsPerSecond=${http_reqs_per_sec:-unknown}"
    echo "  httpReqDurationP95Ms=${http_req_p95_ms:-unknown}"
    echo "  imageSizeBytes=${image_size_bytes:-unknown}"
    echo "  loadedClassLogLines=$(class_count_from_log "${log_file}")"
  } >> "${MONITORING_RESULTS}"

  echo "${mode},${iteration},${process_startup_ms:-},${spring_boot_startup_ms:-},${first_latency_ms},${warm_latency_ms:-},${rss_startup_kb},${rss_warmup_kb},${heap_used:-},${nonheap_used:-},${loaded_classes:-},${threads_live:-},${gc_pause_count:-},${gc_pause_sum:-},${cpu_usage:-},${dependency_postgres_ms:-},${dependency_redis_ms:-},${dependency_kafka_ms:-},${dependency_total_ms:-},${http_reqs_per_sec:-},${http_req_p95_ms:-},${image_size_bytes:-},${log_file}" >> "${MONITORING_CSV}"
}
