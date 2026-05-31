#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_command k6
require_built_app
require_leyden_aot_support

LOG_FILE="${LOG_DIR}/11-generate-leyden-aot-cache.log"
rm -f "${LEYDEN_AOT_CACHE}"

LEYDEN_AOT_TRAINING_DURATION="${LEYDEN_AOT_TRAINING_DURATION:-3m}"
LEYDEN_AOT_TRAINING_VUS="${LEYDEN_AOT_TRAINING_VUS:-4}"

: > "${LOG_FILE}"
ensure_dependency_services
free_port_if_occupied "${APP_PORT}"
env APP_RUNTIME_MODE=leyden-aot APP_JDK=25 APP_NAME=gateway-demo \
  java \
  -XX:AOTCacheOutput="${LEYDEN_AOT_CACHE}" \
  -Xlog:cds=info,class+load=info \
  -Ddemo.port="${APP_PORT}" \
  -jar "$(app_boot_jar)" \
  > "${LOG_FILE}" 2>&1 &
app_pid="$!"

cleanup() {
  stop_pid "${app_pid}"
}
trap cleanup EXIT

if ! wait_for_health "${APP_PORT}"; then
  echo "Application did not become healthy. See ${LOG_FILE}" >&2
  exit 1
fi

warm_gateway_endpoints "${APP_PORT}" >> "${LOG_FILE}" 2>&1 || true

echo "Training Leyden AOT cache for ${LEYDEN_AOT_TRAINING_DURATION} with ${LEYDEN_AOT_TRAINING_VUS} VUs across all application endpoints..."
K6_BASE_URL="http://127.0.0.1:${APP_PORT}" k6 run \
  --vus "${LEYDEN_AOT_TRAINING_VUS}" \
  --duration "${LEYDEN_AOT_TRAINING_DURATION}" \
  "${ROOT_DIR}/load-tests/k6-leyden-aot-training.js" \
  >> "${LOG_FILE}" 2>&1

stop_pid "${app_pid}"
trap - EXIT

if [[ ! -s "${LEYDEN_AOT_CACHE}" ]]; then
  echo "Leyden AOT cache was not created: ${LEYDEN_AOT_CACHE}" >&2
  echo "See ${LOG_FILE}" >&2
  exit 1
fi

echo "Created Leyden AOT cache: ${LEYDEN_AOT_CACHE}"
