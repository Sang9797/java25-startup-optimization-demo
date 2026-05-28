#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

require_command curl
require_native_app

APP_PORT="${APP_PORT:-8080}"
LOG_FILE="${LOG_DIR}/native-run.log"

run_until_healthy_then_stop "native" "${LOG_FILE}" \
  env APP_RUNTIME_MODE=native APP_JDK=25 APP_NAME=gateway-demo SERVER_PORT="${APP_PORT}" \
  "$(native_executable)"

echo "Native run complete. Log: ${LOG_FILE}"
