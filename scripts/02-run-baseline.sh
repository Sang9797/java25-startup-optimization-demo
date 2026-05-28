#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_built_app

LOG_FILE="${LOG_DIR}/02-baseline.log"
CP="$(app_classpath)"

run_until_healthy_then_stop "baseline" "${LOG_FILE}" \
  java \
  -Xlog:class+load=info \
  -Ddemo.port="${APP_PORT}" \
  -Ddemo.profile=baseline \
  -cp "${CP}" \
  "${MAIN_CLASS}"
