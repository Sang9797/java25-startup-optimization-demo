#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

mkdir -p "${LOG_DIR}" "${ROOT_DIR}/build/native"
LOG_FILE="${LOG_DIR}/native-build.log"
NATIVE_EXE="${ROOT_DIR}/build/native/gateway-native"
rm -f "${NATIVE_EXE}"

echo "Building GraalVM Native Image..."
if ! command -v native-image >/dev/null 2>&1 && [[ -x "${HOME}/.sdkman/candidates/java/25.0.3-graal/bin/native-image" ]]; then
  export JAVA_HOME="${HOME}/.sdkman/candidates/java/25.0.3-graal"
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

if command -v native-image >/dev/null 2>&1; then
  echo "Using local native-image: $(native-image --version 2>&1 | head -1)"
  mvn -Pnative -DskipTests native:compile > "${LOG_FILE}" 2>&1
  cp "${ROOT_DIR}/target/gateway-native" "${NATIVE_EXE}"
else
  require_command docker
  echo "native-image not found locally. Using Docker BuildKit export from Dockerfile.native."
  DOCKER_BUILDKIT=1 docker build \
    -f "${ROOT_DIR}/Dockerfile.native" \
    --target export \
    --output "type=local,dest=${ROOT_DIR}/build/native" \
    "${ROOT_DIR}" > "${LOG_FILE}" 2>&1
fi

chmod +x "${NATIVE_EXE}"
mvn -q -DskipTests package >> "${LOG_FILE}" 2>&1
echo "Native executable: ${NATIVE_EXE}"
echo "Native image size bytes: $(stat -c '%s' "${NATIVE_EXE}")"
echo "Build log: ${LOG_FILE}"
