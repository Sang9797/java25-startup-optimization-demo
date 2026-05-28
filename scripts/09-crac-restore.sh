#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl

CHECKPOINT_DIR="${ARTIFACT_DIR}/crac-checkpoint"
LOG_FILE="${LOG_DIR}/09-crac-restore.log"
if [[ ! -d "${CHECKPOINT_DIR}" ]]; then
  echo "CRaC checkpoint directory not found: ${CHECKPOINT_DIR}" >&2
  echo "Run scripts/08-crac-checkpoint.sh first on a CRaC-enabled JDK." >&2
  exit 1
fi

: > "${LOG_FILE}"
env APP_RUNTIME_MODE=crac APP_JDK=25 APP_NAME=gateway-demo \
java \
  -XX:CRaCRestoreFrom="${CHECKPOINT_DIR}" \
  > "${LOG_FILE}" 2>&1 &
PID="$!"

if ! wait_for_health "${APP_PORT}" 40; then
  echo "Restored application did not become healthy. See ${LOG_FILE}" >&2
  stop_pid "${PID}"
  exit 1
fi

curl -fsS "http://127.0.0.1:${APP_PORT}/actuator/health" >> "${LOG_FILE}" 2>&1 || true
stop_pid "${PID}"
echo "CRaC restore completed. Log: ${LOG_FILE}"
