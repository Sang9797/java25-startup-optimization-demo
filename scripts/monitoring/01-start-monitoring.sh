#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-monitoring.sh"

require_command docker

docker compose -f "${ROOT_DIR}/docker-compose.monitoring.yml" up -d prometheus grafana

cat <<MSG
Monitoring stack started.

Prometheus: http://localhost:9090
Grafana:    http://localhost:3000
Grafana login: admin / admin

Next:
  scripts/monitoring/03-run-baseline-monitored.sh
  scripts/monitoring/04-run-cds-monitored.sh
  scripts/monitoring/05-run-appcds-monitored.sh
  scripts/monitoring/06-run-crac-monitored.sh
  scripts/native/03-run-native-monitored.sh
MSG
