#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
ARTIFACT_DIR="${ROOT_DIR}/build/runtime-artifacts"
TARGET_DIR="${ROOT_DIR}/target"
APP_JAR="${TARGET_DIR}/java25-startup-optimization-demo-1.0.0.jar"
APP_CLASSES="${TARGET_DIR}/classes"
MAIN_CLASS="com.example.startupdemo.app.StartupOptimizationApplication"
APP_PORT="${APP_PORT:-8080}"

mkdir -p "${LOG_DIR}" "${ARTIFACT_DIR}"

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command not found: ${command_name}" >&2
    exit 1
  fi
}

require_built_app() {
  if [[ ! -f "${APP_JAR}" ]]; then
    echo "Application jar not found: ${APP_JAR}" >&2
    echo "Run scripts/01-build.sh first." >&2
    exit 1
  fi
}

app_classpath() {
  local cp="${APP_JAR}"
  if compgen -G "${TARGET_DIR}/lib/*.jar" >/dev/null; then
    cp="${cp}:${TARGET_DIR}/lib/*"
  fi
  printf '%s\n' "${cp}"
}

wait_for_health() {
  local port="$1"
  local attempts="${2:-80}"
  for _ in $(seq 1 "${attempts}"); do
    if curl -fsS "http://127.0.0.1:${port}/actuator/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stop_pid() {
  local pid="$1"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

extract_startup_ms() {
  local log_file="$1"
  sed -n 's/.*"startupTimeMillis":\([0-9][0-9]*\).*/\1/p' "${log_file}" | tail -1
}

extract_spring_startup_ms() {
  local log_file="$1"
  sed -n 's/.*"springBootStartupTimeMillis":\([0-9][0-9]*\).*/\1/p' "${log_file}" | tail -1
}

warm_gateway_endpoints() {
  local port="$1"
  curl -fsS "http://127.0.0.1:${port}/health" >/dev/null
  curl -fsS "http://127.0.0.1:${port}/api/users/123" >/dev/null
  curl -fsS "http://127.0.0.1:${port}/api/orders/456" >/dev/null
  curl -fsS "http://127.0.0.1:${port}/api/products/789" >/dev/null
}

run_until_healthy_then_stop() {
  local mode="$1"
  local log_file="$2"
  shift 2

  : > "${log_file}"
  "$@" > "${log_file}" 2>&1 &
  local pid="$!"

  if ! wait_for_health "${APP_PORT}"; then
    echo "Application did not become healthy. See ${log_file}" >&2
    stop_pid "${pid}"
    return 1
  fi

  warm_gateway_endpoints "${APP_PORT}" >> "${log_file}" 2>&1 || true
  stop_pid "${pid}"

  local startup_ms
  startup_ms="$(extract_startup_ms "${log_file}")"
  local spring_startup_ms
  spring_startup_ms="$(extract_spring_startup_ms "${log_file}")"
  echo "${mode} startupTimeMillis=${startup_ms:-unknown} springBootStartupTimeMillis=${spring_startup_ms:-unknown} log=${log_file}"
}
