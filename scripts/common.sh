#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
ARTIFACT_DIR="${ROOT_DIR}/build/runtime-artifacts"
TARGET_DIR="${ROOT_DIR}/target"
APP_JAR="${TARGET_DIR}/java25-startup-optimization-demo-1.0.0.jar"
APP_CLASSES="${TARGET_DIR}/classes"
MAIN_CLASS="com.example.startupdemo.app.StartupOptimizationApplication"
APP_PORT="${APP_PORT:-8080}"
LEYDEN_AOT_CACHE="${ARTIFACT_DIR}/leyden-aot-cache.aot"

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

require_leyden_aot_support() {
  if ! java -XX:AOTMode=off -version >/dev/null 2>&1; then
    echo "Current JDK does not support Project Leyden AOT cache flags." >&2
    echo "Use a JDK 25+ build with -XX:AOTMode, -XX:AOTCacheOutput, and -XX:AOTCache support." >&2
    exit 1
  fi
}

dependency_workload_enabled() {
  [[ "${DEPENDENCY_WORKLOAD_ENABLED:-true}" != "false" ]]
}

ensure_dependency_services() {
  if ! dependency_workload_enabled || [[ "${SKIP_DEPENDENCY_INFRA:-false}" == "true" ]]; then
    return 0
  fi

  require_command docker
  docker compose -f "${ROOT_DIR}/docker-compose.monitoring.yml" up -d postgres redis kafka >/dev/null
  wait_for_container_health jdk25-startup-postgres 90
  wait_for_container_health jdk25-startup-redis 90
  wait_for_container_health jdk25-startup-kafka 160
}

wait_for_container_health() {
  local container="$1"
  local attempts="${2:-90}"
  local status=""
  for _ in $(seq 1 "${attempts}"); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "${container}" 2>/dev/null || true)"
    if [[ "${status}" == "healthy" || "${status}" == "running" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "Container ${container} did not become healthy. Last status: ${status:-unknown}" >&2
  return 1
}

free_port_if_occupied() {
  local port="$1"
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi

  local pids
  pids="$(ss -ltnp "sport = :${port}" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)"
  if [[ -n "${pids}" ]]; then
    echo "Stopping stale process on port ${port}: ${pids}"
    kill ${pids} >/dev/null 2>&1 || true
    sleep 1
  fi
}

app_classpath() {
  local cp="${APP_CLASSES}:${APP_JAR}"
  if compgen -G "${TARGET_DIR}/lib/*.jar" >/dev/null; then
    cp="${cp}:${TARGET_DIR}/lib/*"
  fi
  printf '%s\n' "${cp}"
}

app_jar_classpath() {
  local cp="${APP_JAR}"
  if compgen -G "${TARGET_DIR}/lib/*.jar" >/dev/null; then
    cp="${cp}:${TARGET_DIR}/lib/*"
  fi
  printf '%s\n' "${cp}"
}

app_boot_jar() {
  printf '%s\n' "${APP_JAR}"
}

appcds_classpath() {
  require_command jar
  local classes_jar="${ARTIFACT_DIR}/appcds-classes.jar"
  if [[ ! -f "${classes_jar}" ]] || find "${APP_CLASSES}" -type f -newer "${classes_jar}" -print -quit | grep -q .; then
    jar --create --file "${classes_jar}" -C "${APP_CLASSES}" . >/dev/null 2>&1
  fi
  local cp="${classes_jar}"
  if compgen -G "${TARGET_DIR}/lib/*.jar" >/dev/null; then
    cp="${cp}:${TARGET_DIR}/lib/*"
  fi
  printf '%s\n' "${cp}"
}

wait_for_health() {
  local port="$1"
  local attempts="${2:-160}"
  for _ in $(seq 1 "${attempts}"); do
    if curl -fsS "http://127.0.0.1:${port}/actuator/health/readiness" >/dev/null 2>&1; then
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
  curl -fsS "http://127.0.0.1:${port}/dependencies" >/dev/null
}

wait_for_startup_metrics() {
  local log_file="$1"
  local attempts="${2:-100}"
  for _ in $(seq 1 "${attempts}"); do
    if [[ -s "${log_file}" ]] && grep -q '"startupTimeMillis":' "${log_file}" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

run_until_healthy_then_stop() {
  local mode="$1"
  local log_file="$2"
  shift 2

  ensure_dependency_services
  free_port_if_occupied "${APP_PORT}"
  : > "${log_file}"
  "$@" > "${log_file}" 2>&1 &
  local pid="$!"

  if ! wait_for_health "${APP_PORT}"; then
    echo "Application did not become healthy. See ${log_file}" >&2
    stop_pid "${pid}"
    return 1
  fi

  warm_gateway_endpoints "${APP_PORT}" >> "${log_file}" 2>&1 || true
  wait_for_startup_metrics "${log_file}" >/dev/null 2>&1 || true
  stop_pid "${pid}"

  local startup_ms
  startup_ms="$(extract_startup_ms "${log_file}")"
  local spring_startup_ms
  spring_startup_ms="$(extract_spring_startup_ms "${log_file}")"
  echo "${mode} startupTimeMillis=${startup_ms:-unknown} springBootStartupTimeMillis=${spring_startup_ms:-unknown} log=${log_file}"
}
