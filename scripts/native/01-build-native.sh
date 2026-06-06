#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

mkdir -p "${LOG_DIR}" "${ROOT_DIR}/build/native"
LOG_FILE="${LOG_DIR}/native-build.log"
NATIVE_EXE="${ROOT_DIR}/build/native/gateway-native"
NATIVE_BUILD_DIR="${ROOT_DIR}/build/native"
NATIVE_ARGS_FILE="${NATIVE_BUILD_DIR}/native-extra-args.txt"
NATIVE_PGO_PROFILE="${NATIVE_PGO_PROFILE:-${NATIVE_BUILD_DIR}/default.iprof}"
rm -f "${NATIVE_EXE}"
rm -f "${NATIVE_ARGS_FILE}"

native_image_help_supports() {
  local flag="$1"
  native-image --help-extra 2>/dev/null | grep -F -- "${flag}" >/dev/null 2>&1
}

append_native_arg() {
  printf '%s\n' "$1" >> "${NATIVE_ARGS_FILE}"
}

prepare_native_args() {
  local pgo_mode="${NATIVE_PGO_MODE:-off}"
  local preserve_target="${NATIVE_PRESERVE:-}"
  local sbom_mode="${NATIVE_ENABLE_SBOM:-}"
  local extra_args="${NATIVE_EXTRA_ARGS:-}"

  if [[ "${NATIVE_VERBOSE:-false}" == "true" ]]; then
    append_native_arg "--verbose"
  fi

  if [[ -n "${preserve_target}" ]]; then
    if native_image_help_supports "-H:Preserve"; then
      append_native_arg "-H:Preserve=${preserve_target}"
    else
      echo "Requested NATIVE_PRESERVE, but this native-image does not support -H:Preserve." >&2
      exit 1
    fi
  fi

  case "${pgo_mode}" in
    off)
      ;;
    instrument)
      if native_image_help_supports "--pgo-instrument"; then
        append_native_arg "--pgo-instrument"
      else
        echo "Requested NATIVE_PGO_MODE=instrument, but this native-image does not support --pgo-instrument." >&2
        exit 1
      fi
      ;;
    optimize)
      if native_image_help_supports "--pgo"; then
        if [[ -f "${NATIVE_PGO_PROFILE}" ]]; then
          append_native_arg "--pgo=${NATIVE_PGO_PROFILE}"
        else
          append_native_arg "--pgo"
        fi
      else
        echo "Requested NATIVE_PGO_MODE=optimize, but this native-image does not support --pgo." >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported NATIVE_PGO_MODE=${pgo_mode}. Use off, instrument, or optimize." >&2
      exit 1
      ;;
  esac

  if [[ -n "${sbom_mode}" ]]; then
    if native_image_help_supports "--enable-sbom"; then
      append_native_arg "--enable-sbom=${sbom_mode}"
    else
      echo "Requested NATIVE_ENABLE_SBOM, but this native-image does not support --enable-sbom." >&2
      exit 1
    fi
  fi

  if [[ "${NATIVE_ENABLE_OBFUSCATION:-false}" == "true" ]]; then
    if native_image_help_supports "-H:AdvancedObfuscation"; then
      append_native_arg "-H:AdvancedObfuscation=export-mapping"
    else
      echo "Requested NATIVE_ENABLE_OBFUSCATION, but this native-image does not support advanced obfuscation." >&2
      exit 1
    fi
  fi

  if [[ -n "${extra_args}" ]]; then
    for arg in ${extra_args}; do
      append_native_arg "${arg}"
    done
  fi
}

echo "Building GraalVM Native Image..."
if ! command -v native-image >/dev/null 2>&1 && [[ -x "${HOME}/.sdkman/candidates/java/25.0.3-graal/bin/native-image" ]]; then
  export JAVA_HOME="${HOME}/.sdkman/candidates/java/25.0.3-graal"
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

if command -v native-image >/dev/null 2>&1; then
  echo "Using local native-image: $(native-image --version 2>&1 | head -1)"
  prepare_native_args
  local_args=()
  if [[ -s "${NATIVE_ARGS_FILE}" ]]; then
    while IFS= read -r arg; do
      local_args+=("-Dnative.image.extra.${#local_args[@]}=${arg}")
    done < "${NATIVE_ARGS_FILE}"
  fi
  mvn -Pnative -DskipTests "${local_args[@]}" native:compile > "${LOG_FILE}" 2>&1
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
mvn -q -DskipTests clean package >> "${LOG_FILE}" 2>&1
echo "Native executable: ${NATIVE_EXE}"
echo "Native image size bytes: $(stat -c '%s' "${NATIVE_EXE}")"
if [[ -f "${ROOT_DIR}/target/native-build-report.html" ]]; then
  echo "Native build report: ${ROOT_DIR}/target/native-build-report.html"
fi
if [[ -f "${NATIVE_PGO_PROFILE}" ]]; then
  echo "PGO profile: ${NATIVE_PGO_PROFILE}"
fi
echo "Build log: ${LOG_FILE}"
