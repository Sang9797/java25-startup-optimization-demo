#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command mvn
require_command java

java -version 2>&1 | tee "${LOG_DIR}/01-java-version.log"
mvn -q -DskipTests clean package 2>&1 | tee "${LOG_DIR}/01-build.log"

echo "Built ${APP_CLASSES} and ${APP_JAR}"
