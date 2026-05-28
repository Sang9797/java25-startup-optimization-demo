#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-monitoring.sh"

for mode in baseline cds appcds crac native; do
  stop_mode_if_running "${mode}"
done

if command -v docker >/dev/null 2>&1; then
  docker compose -f "${ROOT_DIR}/docker-compose.monitoring.yml" down
fi

echo "Stopped monitored gateway processes and monitoring containers."
