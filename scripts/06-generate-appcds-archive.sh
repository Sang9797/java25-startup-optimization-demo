#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_built_app

CLASSLIST="${ARTIFACT_DIR}/appcds.classlist"
ARCHIVE="${ARTIFACT_DIR}/appcds.jsa"
DYNAMIC_ARCHIVE="${ARTIFACT_DIR}/appcds-dynamic-at-exit.jsa"
LOG_FILE="${LOG_DIR}/06-generate-appcds-archive.log"

if [[ ! -s "${CLASSLIST}" ]]; then
  echo "AppCDS class list not found or empty: ${CLASSLIST}" >&2
  echo "Run scripts/05-generate-appcds-classlist.sh first." >&2
  exit 1
fi

rm -f "${ARCHIVE}" "${DYNAMIC_ARCHIVE}"

java \
  -Xshare:dump \
  -XX:SharedClassListFile="${CLASSLIST}" \
  -XX:SharedArchiveFile="${ARCHIVE}" \
  -Xlog:cds=info \
  -cp "$(appcds_classpath)" \
  > "${LOG_FILE}" 2>&1

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "AppCDS archive was not created. See ${LOG_FILE}" >&2
  exit 1
fi

echo "Created AppCDS archive: ${ARCHIVE}"
echo "For dynamic AppCDS experimentation, this command shape is also valid:" >> "${LOG_FILE}"
echo "java -XX:ArchiveClassesAtExit=${DYNAMIC_ARCHIVE} -cp '$(appcds_classpath)' ${MAIN_CLASS}" >> "${LOG_FILE}"
