#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-monitoring.sh"

port="$(port_for_mode baseline)"
log_file="${LOG_DIR}/monitoring-baseline.log"
start_standard_mode baseline "${port}" "${log_file}" >/dev/null
pid="$(cat "${PID_DIR}/baseline.pid")"
warm_gateway_endpoints "${port}"

cat <<MSG
Baseline gateway is running.
PID: ${pid}
URL: http://localhost:${port}
Metrics: http://localhost:${port}/actuator/prometheus
Log: ${log_file}

Prometheus target: gateway-baseline
Stop with: scripts/monitoring/02-stop-monitoring.sh
MSG
