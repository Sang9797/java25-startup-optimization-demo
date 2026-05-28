#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_command jcmd
require_built_app

CHECKPOINT_DIR="${ARTIFACT_DIR}/crac-checkpoint"
LOG_FILE="${LOG_DIR}/08-crac-checkpoint.log"
CP="$(app_classpath)"
rm -rf "${CHECKPOINT_DIR}"
mkdir -p "${CHECKPOINT_DIR}"
: > "${LOG_FILE}"

java \
  -XX:CRaCCheckpointTo="${CHECKPOINT_DIR}" \
  -Ddemo.port="${APP_PORT}" \
  -Ddemo.profile=crac-checkpoint \
  -cp "${CP}" \
  "${MAIN_CLASS}" \
  > "${LOG_FILE}" 2>&1 &
PID="$!"

if ! wait_for_health "${APP_PORT}"; then
  echo "Application did not become healthy before checkpoint. See ${LOG_FILE}" >&2
  stop_pid "${PID}"
  exit 1
fi

curl -fsS "http://127.0.0.1:${APP_PORT}/compute" >> "${LOG_FILE}" 2>&1 || true

echo "Requesting CRaC checkpoint for PID ${PID}" | tee -a "${LOG_FILE}"
if ! jcmd "${PID}" JDK.checkpoint >> "${LOG_FILE}" 2>&1; then
  echo "CRaC checkpoint failed. This usually means the runtime is not CRaC-enabled or OS permissions are missing." >&2
  echo "See ${LOG_FILE}" >&2
  stop_pid "${PID}"
  exit 1
fi

wait "${PID}" >/dev/null 2>&1 || true
echo "Created CRaC checkpoint under: ${CHECKPOINT_DIR}"
