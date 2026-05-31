#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_built_app

ARCHIVE="${ARTIFACT_DIR}/appcds.jsa"
LOG_FILE="${LOG_DIR}/07-appcds.log"
if [[ ! -f "${ARCHIVE}" ]]; then
  echo "AppCDS archive not found: ${ARCHIVE}" >&2
  echo "Run scripts/05-generate-appcds-classlist.sh and scripts/06-generate-appcds-archive.sh first." >&2
  exit 1
fi

run_until_healthy_then_stop "appcds" "${LOG_FILE}" \
  env APP_RUNTIME_MODE=appcds APP_JDK=25 APP_NAME=gateway-demo \
  java \
  -Xshare:on \
  -XX:SharedArchiveFile="${ARCHIVE}" \
  -Xlog:cds=info,class+load=info \
  -Ddemo.port="${APP_PORT}" \
  -cp "$(appcds_classpath)" \
  "${MAIN_CLASS}"
