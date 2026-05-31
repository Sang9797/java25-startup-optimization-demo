#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

require_command curl
require_command docker
require_command k6
require_built_app
require_native_app

LONG_DURATION="${LONG_DURATION:-30m}"
LONG_K6_VUS="${LONG_K6_VUS:-8}"
LONG_RESULTS_DIR="${LOG_DIR}/long-run-grafana"
mkdir -p "${LONG_RESULTS_DIR}"

baseline_port="$(port_for_mode baseline)"
native_port="$(port_for_mode native)"
baseline_log="${LONG_RESULTS_DIR}/baseline-startup.log"
native_log="${LONG_RESULTS_DIR}/native-startup.log"
baseline_k6_summary="${LONG_RESULTS_DIR}/baseline-k6.json"
native_k6_summary="${LONG_RESULTS_DIR}/native-k6.json"
baseline_k6_log="${LONG_RESULTS_DIR}/baseline-k6.log"
native_k6_log="${LONG_RESULTS_DIR}/native-k6.log"

docker compose -f "${ROOT_DIR}/docker-compose.monitoring.yml" up -d prometheus grafana >/dev/null

start_standard_mode baseline "${baseline_port}" "${baseline_log}" >/dev/null
start_native_mode "${native_port}" "${native_log}" >/dev/null
warm_gateway_endpoints "${baseline_port}"
warm_gateway_endpoints "${native_port}"

echo "Running concurrent long workload for Grafana."
echo "baseline: http://localhost:${baseline_port}"
echo "native:   http://localhost:${native_port}"
echo "duration: ${LONG_DURATION}"
echo "VUs per mode: ${LONG_K6_VUS}"

K6_BASE_URL="http://127.0.0.1:${baseline_port}" k6 run \
  --vus "${LONG_K6_VUS}" \
  --duration "${LONG_DURATION}" \
  --summary-export "${baseline_k6_summary}" \
  "${ROOT_DIR}/load-tests/k6-gateway.js" \
  > "${baseline_k6_log}" 2>&1 &
baseline_k6_pid="$!"

K6_BASE_URL="http://127.0.0.1:${native_port}" k6 run \
  --vus "${LONG_K6_VUS}" \
  --duration "${LONG_DURATION}" \
  --summary-export "${native_k6_summary}" \
  "${ROOT_DIR}/load-tests/k6-gateway.js" \
  > "${native_k6_log}" 2>&1 &
native_k6_pid="$!"

wait "${baseline_k6_pid}"
wait "${native_k6_pid}"

cat <<MSG
Grafana long-run workload complete. Apps are still running for inspection.

Dashboard:
  http://localhost:3000/d/long-run-baseline-vs-native/long-run-baseline-vs-native

Grafana login:
  admin / admin

k6 summaries:
  ${baseline_k6_summary}
  ${native_k6_summary}

Stop apps and containers:
  scripts/monitoring/02-stop-monitoring.sh
MSG
