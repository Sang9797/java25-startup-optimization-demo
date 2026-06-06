#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/common.sh"

SBOM_OUTPUT="${SBOM_OUTPUT:-${ROOT_DIR}/build/native/gateway-native.sbom.json}"
NATIVE_EXE="${ROOT_DIR}/build/native/gateway-native"

if [[ ! -x "${NATIVE_EXE}" ]]; then
  echo "Native executable not found: ${NATIVE_EXE}" >&2
  echo "Run scripts/native/01-build-native.sh first." >&2
  exit 1
fi

if ! command -v native-image-configure >/dev/null 2>&1 && [[ -x "${JAVA_HOME:-}/bin/native-image-configure" ]]; then
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

require_command native-image-configure
mkdir -p "$(dirname "${SBOM_OUTPUT}")"
native-image-configure extract-sbom --image-path="${NATIVE_EXE}" > "${SBOM_OUTPUT}"
echo "SBOM exported to ${SBOM_OUTPUT}"
