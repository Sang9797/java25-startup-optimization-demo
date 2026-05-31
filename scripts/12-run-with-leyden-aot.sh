#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_built_app
require_leyden_aot_support

LOG_FILE="${LOG_DIR}/12-leyden-aot.log"
if [[ ! -s "${LEYDEN_AOT_CACHE}" ]]; then
  echo "Leyden AOT cache not found: ${LEYDEN_AOT_CACHE}" >&2
  echo "Run scripts/11-generate-leyden-aot-cache.sh first." >&2
  exit 1
fi

run_until_healthy_then_stop "leyden-aot" "${LOG_FILE}" \
  env APP_RUNTIME_MODE=leyden-aot APP_JDK=25 APP_NAME=gateway-demo \
  java \
  -XX:AOTCache="${LEYDEN_AOT_CACHE}" \
  -Xlog:cds=info,class+load=info \
  -Ddemo.port="${APP_PORT}" \
  -jar "$(app_boot_jar)"
