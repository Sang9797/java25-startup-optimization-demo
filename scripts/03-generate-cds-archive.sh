#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_built_app

ARCHIVE="${ARTIFACT_DIR}/cds-base.jsa"
LOG_FILE="${LOG_DIR}/03-generate-cds-archive.log"
rm -f "${ARCHIVE}"

java \
  -Xshare:dump \
  -XX:SharedArchiveFile="${ARCHIVE}" \
  -Xlog:cds=info \
  > "${LOG_FILE}" 2>&1

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "CDS archive was not created. See ${LOG_FILE}" >&2
  exit 1
fi

echo "Created CDS archive: ${ARCHIVE}"
