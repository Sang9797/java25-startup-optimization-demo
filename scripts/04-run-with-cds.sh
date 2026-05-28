#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_built_app

ARCHIVE="${ARTIFACT_DIR}/cds-base.jsa"
LOG_FILE="${LOG_DIR}/04-cds.log"
if [[ ! -f "${ARCHIVE}" ]]; then
  echo "CDS archive not found: ${ARCHIVE}" >&2
  echo "Run scripts/03-generate-cds-archive.sh first." >&2
  exit 1
fi

CP="$(app_classpath)"
run_until_healthy_then_stop "cds" "${LOG_FILE}" \
  java \
  -Xshare:on \
  -XX:SharedArchiveFile="${ARCHIVE}" \
  -Xlog:cds=info,class+load=info \
  -Ddemo.port="${APP_PORT}" \
  -Ddemo.profile=cds \
  -cp "${CP}" \
  "${MAIN_CLASS}"
