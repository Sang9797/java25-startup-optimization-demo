#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_built_app

ITERATIONS="${ITERATIONS:-5}"
RESULTS="${LOG_DIR}/benchmark-results.txt"
CP="$(app_classpath)"
CDS_ARCHIVE="${ARTIFACT_DIR}/cds-base.jsa"
APPCDS_ARCHIVE="${ARTIFACT_DIR}/appcds.jsa"
CRAC_CHECKPOINT_DIR="${ARTIFACT_DIR}/crac-checkpoint"

: > "${RESULTS}"
{
  echo "Java startup benchmark"
  echo "date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "iterations=${ITERATIONS}"
  echo "java=$(java -version 2>&1 | head -1)"
  echo
} >> "${RESULTS}"

benchmark_mode() {
  local mode="$1"
  shift
  echo "[${mode}]" >> "${RESULTS}"
  for iteration in $(seq 1 "${ITERATIONS}"); do
    local log_file="${LOG_DIR}/benchmark-${mode}-${iteration}.log"
    local output
    output="$(run_until_healthy_then_stop "${mode}" "${log_file}" "$@")"
    local startup_ms
    startup_ms="$(extract_startup_ms "${log_file}")"
    echo "iteration=${iteration} startupTimeMillis=${startup_ms:-unknown} log=${log_file}" >> "${RESULTS}"
    echo "${output}"
  done
  echo >> "${RESULTS}"
}

benchmark_mode "baseline" \
  env APP_RUNTIME_MODE=baseline APP_JDK=25 APP_NAME=gateway-demo \
  java -Xlog:class+load=info -Ddemo.port="${APP_PORT}" -cp "${CP}" "${MAIN_CLASS}"

if [[ -f "${CDS_ARCHIVE}" ]]; then
  benchmark_mode "cds" \
    env APP_RUNTIME_MODE=cds APP_JDK=25 APP_NAME=gateway-demo \
    java -Xshare:on -XX:SharedArchiveFile="${CDS_ARCHIVE}" -Xlog:cds=info,class+load=info \
    -Ddemo.port="${APP_PORT}" -cp "${CP}" "${MAIN_CLASS}"
else
  echo "[cds] skipped missing archive ${CDS_ARCHIVE}" >> "${RESULTS}"
fi

if [[ -f "${APPCDS_ARCHIVE}" ]]; then
  benchmark_mode "appcds" \
    env APP_RUNTIME_MODE=appcds APP_JDK=25 APP_NAME=gateway-demo \
    java -Xshare:on -XX:SharedArchiveFile="${APPCDS_ARCHIVE}" -Xlog:cds=info,class+load=info \
    -Ddemo.port="${APP_PORT}" -cp "${CP}" "${MAIN_CLASS}"
else
  echo "[appcds] skipped missing archive ${APPCDS_ARCHIVE}" >> "${RESULTS}"
fi

if [[ -d "${CRAC_CHECKPOINT_DIR}" ]]; then
  echo "[crac-restore]" >> "${RESULTS}"
  for iteration in $(seq 1 "${ITERATIONS}"); do
    log_file="${LOG_DIR}/benchmark-crac-restore-${iteration}.log"
    : > "${log_file}"
    start_ns="$(date +%s%N)"
    env APP_RUNTIME_MODE=crac APP_JDK=25 APP_NAME=gateway-demo \
    java -XX:CRaCRestoreFrom="${CRAC_CHECKPOINT_DIR}" > "${log_file}" 2>&1 &
    pid="$!"
    if wait_for_health "${APP_PORT}" 40; then
      end_ns="$(date +%s%N)"
      elapsed_ms="$(((end_ns - start_ns) / 1000000))"
      curl -fsS "http://127.0.0.1:${APP_PORT}/health" >> "${log_file}" 2>&1 || true
      stop_pid "${pid}"
      echo "iteration=${iteration} externalRestoreMillis=${elapsed_ms} log=${log_file}" >> "${RESULTS}"
      echo "crac-restore externalRestoreMillis=${elapsed_ms} log=${log_file}"
    else
      stop_pid "${pid}"
      echo "iteration=${iteration} failed log=${log_file}" >> "${RESULTS}"
      echo "CRaC restore benchmark failed. See ${log_file}" >&2
    fi
  done
  echo >> "${RESULTS}"
else
  echo "[crac-restore] skipped missing checkpoint ${CRAC_CHECKPOINT_DIR}" >> "${RESULTS}"
fi

{
  echo "Loaded class log line count:"
  grep "class,load" "${LOG_DIR}"/*.log 2>/dev/null | wc -l | tr -d ' '
} >> "${RESULTS}"

echo "Benchmark results written to ${RESULTS}"
