#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

port="$(port_for_mode native)"
log_file="${LOG_DIR}/monitoring-native.log"
start_native_mode "${port}" "${log_file}" >/dev/null
pid="$(cat "${PID_DIR}/native.pid")"
warm_gateway_endpoints "${port}"

cat <<MSG
Native gateway is running.
PID: ${pid}
URL: http://localhost:${port}
Metrics: http://localhost:${port}/actuator/prometheus
Log: ${log_file}

Prometheus target: gateway-native
Stop with: scripts/monitoring/02-stop-monitoring.sh
MSG
