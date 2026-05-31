#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_built_app

CLASSLIST="${ARTIFACT_DIR}/appcds.classlist"
LOG_FILE="${LOG_DIR}/05-generate-appcds-classlist.log"
rm -f "${CLASSLIST}"

run_until_healthy_then_stop "appcds-classlist" "${LOG_FILE}" \
  env APP_RUNTIME_MODE=appcds APP_JDK=25 APP_NAME=gateway-demo \
  java \
  -XX:DumpLoadedClassList="${CLASSLIST}" \
  -Xlog:class+load=info \
  -Ddemo.port="${APP_PORT}" \
  -cp "$(appcds_classpath)" \
  "${MAIN_CLASS}"

if [[ ! -s "${CLASSLIST}" ]]; then
  echo "AppCDS class list is empty or missing: ${CLASSLIST}" >&2
  echo "See ${LOG_FILE}" >&2
  exit 1
fi

echo "Created AppCDS class list: ${CLASSLIST}"
