#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-monitoring.sh"

port="$(port_for_mode crac)"
log_file="${LOG_DIR}/monitoring-crac-restore.log"
start_crac_restore_mode "${port}" "${log_file}" >/dev/null
pid="$(cat "${PID_DIR}/crac.pid")"
warm_gateway_endpoints "${port}"

cat <<MSG
CRaC-restored gateway is running.
PID: ${pid}
URL: http://localhost:${port}
Metrics: http://localhost:${port}/actuator/prometheus
Log: ${log_file}

Prometheus target: gateway-crac
Stop with: scripts/monitoring/02-stop-monitoring.sh
MSG
