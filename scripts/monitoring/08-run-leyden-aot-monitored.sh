#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-monitoring.sh"

port="$(port_for_mode leyden-aot)"
log_file="${LOG_DIR}/monitoring-leyden-aot.log"
start_standard_mode leyden-aot "${port}" "${log_file}" >/dev/null
pid="$(cat "${PID_DIR}/leyden-aot.pid")"
warm_gateway_endpoints "${port}"

cat <<MSG
Leyden AOT cache gateway is running.
PID: ${pid}
URL: http://localhost:${port}
Metrics: http://localhost:${port}/actuator/prometheus
Log: ${log_file}

Prometheus target: gateway-leyden-aot
Stop with: scripts/monitoring/02-stop-monitoring.sh
MSG
