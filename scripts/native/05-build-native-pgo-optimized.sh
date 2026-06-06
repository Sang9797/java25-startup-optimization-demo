#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PGO_PROFILE="${NATIVE_PGO_PROFILE:-${ROOT_DIR}/build/native/default.iprof}"

if [[ ! -f "${PGO_PROFILE}" ]]; then
  echo "Missing PGO profile: ${PGO_PROFILE}" >&2
  echo "Build and run scripts/native/04-build-native-pgo-instrumented.sh first, then stop the app to write the profile." >&2
  exit 1
fi

echo "Building PGO-optimized native image with profile ${PGO_PROFILE}..."
NATIVE_PGO_MODE=optimize \
NATIVE_PGO_PROFILE="${PGO_PROFILE}" \
  "${ROOT_DIR}/scripts/native/01-build-native.sh"
