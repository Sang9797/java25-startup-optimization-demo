#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PGO_PROFILE="${NATIVE_PGO_PROFILE:-${ROOT_DIR}/build/native/default.iprof}"

echo "Building instrumented native image for profile collection..."
NATIVE_PGO_MODE=instrument \
NATIVE_PGO_PROFILE="${PGO_PROFILE}" \
  "${ROOT_DIR}/scripts/native/01-build-native.sh"

echo "Instrumented binary ready: ${ROOT_DIR}/build/native/gateway-native"
echo "Profile will be written on process exit. Default profile path: ${PGO_PROFILE}"
