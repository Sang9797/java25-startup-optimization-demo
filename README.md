# JDK 25 Startup Optimization Performance Lab

Spring Boot gateway benchmark project for comparing:

- JVM baseline
- CDS
- AppCDS
- CRaC restore
- GraalVM Native Image

The app is intentionally small: a lightweight HTTP gateway/router with Actuator and Prometheus metrics. It is built to measure cold start, first request latency, memory, CPU, GC, loaded classes, and warm throughput.

## Architecture

```text
             +-------------------+
             | Grafana :3000     |
             | provisioned       |
             +---------+---------+
                       |
                       v
             +-------------------+
             | Prometheus :9090  |
             +---------+---------+
                       |
   +-------------------+-------------------+
   |       |           |           |       |
 8081    8082        8083        8084    8085
 JVM     CDS         AppCDS      CRaC    Native
```

## Endpoints

Application:

```text
GET /health
GET /hello
GET /compute
GET /api/users/{id}
GET /api/orders/{id}
GET /api/products/{id}
```

Observability:

```text
GET /actuator/health
GET /actuator/prometheus
```

## Runtime Modes

Set with:

```bash
APP_RUNTIME_MODE=baseline|cds|appcds|crac|native
```

Metrics are tagged with:

```text
app="gateway-demo"
jdk="25"
mode="baseline|cds|appcds|crac|native"
```

Custom metrics:

```text
app_startup_time_ms
app_spring_boot_startup_time_ms
app_first_request_latency_ms
app_restore_time_ms
app_jvm_mode
app_cds_enabled
app_appcds_enabled
app_crac_enabled
app_native_enabled
```

## Requirements

- JDK 25
- Maven 3.9+
- Docker + Docker Compose
- `curl`
- `k6` for load tests
- GraalVM 25 with `native-image` for local native builds
- CRaC-enabled JDK for CRaC, for example `25.0.3.crac-zulu`

SDKMAN examples:

```bash
sdk install java 25.0.3.crac-zulu
sdk install java 25.0.3-graal
sdk default java 25.0.3.crac-zulu
```

Check CRaC:

```bash
java -XX:CRaCCheckpointTo=/tmp/crac-test -version
```

Check native-image:

```bash
~/.sdkman/candidates/java/25.0.3-graal/bin/native-image --version
```

## Run From Zero

Use this order from a clean checkout. The order matters because CDS/AppCDS/CRaC/native modes depend on generated build artifacts.

```bash
cd /home/sangle/codex/java25-startup-optimization-demo

# 1. Build the Spring Boot gateway jar and dependency classpath.
scripts/01-build.sh

# 2. Generate JVM CDS and AppCDS runtime artifacts.
scripts/03-generate-cds-archive.sh
scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh

# 3. Generate the CRaC checkpoint.
# Requires a CRaC-enabled JDK and Linux support.
scripts/08-crac-checkpoint.sh

# 4. Build the GraalVM native executable.
scripts/native/01-build-native.sh

# 5. Start Prometheus and Grafana.
scripts/monitoring/01-start-monitoring.sh

# 6. Start every monitored runtime mode side by side.
scripts/monitoring/03-run-baseline-monitored.sh
scripts/monitoring/04-run-cds-monitored.sh
scripts/monitoring/05-run-appcds-monitored.sh
scripts/monitoring/06-run-crac-monitored.sh
scripts/native/03-run-native-monitored.sh
```

Open:

```text
Prometheus: http://localhost:9090
Grafana:    http://localhost:3000
Login:      admin / admin
```

Verify everything is up:

```bash
for p in 8081 8082 8083 8084 8085; do
  curl -fsS "http://localhost:$p/actuator/health"
done

curl -fsS 'http://localhost:9090/api/v1/targets?state=active'

curl -fsS -u admin:admin 'http://localhost:3000/api/search?type=dash-db'
```

## Individual Runs

```bash
scripts/02-run-baseline.sh
scripts/04-run-with-cds.sh
scripts/07-run-with-appcds.sh
scripts/09-crac-restore.sh
scripts/native/02-run-native.sh
```

## Full Benchmark

```bash
ITERATIONS=3 scripts/native/05-compare-all-modes.sh
```

Outputs:

```text
logs/benchmark-results.csv
logs/benchmark-results.json
logs/benchmark-results.md
logs/benchmark-summary.txt
logs/benchmark-monitoring-results.txt
logs/benchmark-monitoring-results.csv
```

The benchmark captures:

- process startup time
- Spring Boot startup time
- first request latency
- warm request latency
- RSS after startup and warmup
- heap and non-heap memory
- CPU usage
- HTTP throughput from k6
- HTTP p95 latency from k6
- GC count and pause time where available
- loaded classes where available
- runtime payload/native executable size

CRaC note: `process_startup_ms` is restore-to-health time. `spring_boot_startup_ms` is empty because Spring Boot startup does not run again after restore.

## Tomorrow Quick Check

If the lab is already running, use:

```bash
cd /home/sangle/codex/java25-startup-optimization-demo

docker ps

for p in 8081 8082 8083 8084 8085; do
  echo "checking $p"
  curl -fsS "http://localhost:$p/actuator/health"
done

curl -fsS 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D~%22gateway-.*%22%7D'
curl -fsS -u admin:admin 'http://localhost:3000/api/search?type=dash-db'
```

If you want to restart everything cleanly:

```bash
scripts/monitoring/02-stop-monitoring.sh

scripts/monitoring/01-start-monitoring.sh
scripts/monitoring/03-run-baseline-monitored.sh
scripts/monitoring/04-run-cds-monitored.sh
scripts/monitoring/05-run-appcds-monitored.sh
scripts/monitoring/06-run-crac-monitored.sh
scripts/native/03-run-native-monitored.sh
```

If you changed source code, regenerate all artifacts first:

```bash
scripts/01-build.sh
scripts/03-generate-cds-archive.sh
scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh
scripts/08-crac-checkpoint.sh
scripts/native/01-build-native.sh
```

## Docker

JVM image:

```bash
docker build -f Dockerfile.jvm -t gateway-jvm .
```

Native image container:

```bash
docker build -f Dockerfile.native --target runtime -t gateway-native .
```

Compose monitoring:

```bash
docker compose -f docker-compose.monitoring.yml up -d prometheus grafana
```

Optional app containers are defined with compose profiles, but the default Prometheus config scrapes host-run apps on ports `8081` to `8085`. This avoids down targets when optional containers are not running.

## Grafana Dashboards

Provisioned dashboards:

```text
JVM Startup Optimization Comparison
Native Image vs JVM
Memory & Resource Analysis
Cold Start Comparison
```

Panels include startup bars, first request latency, CRaC restore time, native cold start, heap/non-heap/RSS memory, CPU usage, loaded classes, GC, HTTP throughput, p95 latency, heatmaps, and ranking tables.

### How To See Metrics In Grafana

1. Open `http://localhost:3000`.
2. Log in with `admin / admin`.
3. Open the left menu and go to **Dashboards**.
4. Open the folder **Startup Monitoring**.
5. Choose one of these dashboards:

```text
JVM Startup Optimization Comparison
Native Image vs JVM
Memory & Resource Analysis
Cold Start Comparison
```

Recommended viewing order:

1. **Cold Start Comparison**
   - Use this first to see startup time ranking and first request latency.
   - Key panels: `Cold start by mode`, `First request by mode`, `Ranking all runtime modes`.

2. **JVM Startup Optimization Comparison**
   - Use this to compare baseline, CDS, AppCDS, CRaC, and native on startup, p95 HTTP latency, and throughput.
   - Key panels: `Startup time comparison`, `HTTP latency p95`, `Throughput by mode`, `Startup leaderboard`.

3. **Native Image vs JVM**
   - Use this to focus on native image startup, RSS, CPU, and latency compared with JVM baseline.
   - Key panels: `Native Image cold start advantage`, `Native vs JVM RSS`, `Native vs JVM CPU usage`.

4. **Memory & Resource Analysis**
   - Use this for heap, non-heap, process RSS, loaded classes, GC pause, GC count, and CPU.
   - Native Image may show missing or zero values for some JVM-specific metrics; see Native Image Notes.

### How To See Metrics In Prometheus

Open:

```text
http://localhost:9090
```

Go to **Graph**, paste one of the PromQL queries below, and click **Execute**. Use the **Table** tab for exact values and **Graph** for time series.

Check scrape health:

```promql
up{job=~"gateway-.*"}
```

You should see five `up = 1` targets:

```text
gateway-baseline
gateway-cds
gateway-appcds
gateway-crac
gateway-native
```

## Important PromQL

Startup:

```promql
max by (mode) (app_startup_time_ms{app="gateway-demo",jdk="25"})
```

First request:

```promql
max by (mode) (app_first_request_latency_ms{app="gateway-demo",jdk="25"})
```

CRaC restore:

```promql
max by (mode) (app_restore_time_ms{app="gateway-demo",jdk="25",mode="crac"})
```

Heap:

```promql
sum by (mode) (jvm_memory_used_bytes{app="gateway-demo",jdk="25",area="heap"})
```

RSS:

```promql
max by (mode) (process_resident_memory_bytes{app="gateway-demo",jdk="25"})
```

Loaded classes:

```promql
max by (mode) (jvm_classes_loaded_classes{app="gateway-demo",jdk="25"})
```

GC pause:

```promql
sum by (mode) (rate(jvm_gc_pause_seconds_sum{app="gateway-demo",jdk="25"}[1m]))
```

HTTP throughput:

```promql
sum by (mode) (rate(http_server_requests_seconds_count{app="gateway-demo",jdk="25"}[1m]))
```

HTTP p95:

```promql
histogram_quantile(0.95, sum by (mode,le) (rate(http_server_requests_seconds_bucket{app="gateway-demo",jdk="25"}[1m])))
```

## Native Image Notes

Native Image advantages:

- very fast process startup
- low first-request latency
- no JIT warmup requirement
- good fit for scale-to-zero and cold-start-sensitive services

Tradeoffs:

- build is slower and more memory intensive
- native executable can be larger than a thin jar payload
- peak throughput can differ from JVM JIT behavior
- reflection/dynamic loading needs AOT hints when used
- debugging and profiling are different from JVM workflows
- some JVM metrics are unavailable or behave differently

Observed limitation in this project: native mode emits a warning that GC notifications are unavailable for the native runtime GC MXBeans. GC pause metrics may therefore be empty in Native Image while present in JVM modes. Loaded class counts may also be `0` or not meaningful because Native Image does not load application bytecode like a normal JVM.

## JFR And Flamegraphs

JFR is useful for JVM modes:

```bash
java -XX:StartFlightRecording=filename=logs/startup.jfr,dumponexit=true,duration=20s ...
```

Native Image does not use the same JIT/compiler runtime profile as a JVM process. Treat JFR/JIT warmup comparisons as JVM-only unless you explicitly build native profiling support.

Startup flamegraphs are intentionally optional because they require platform tooling such as `async-profiler` or `perf` permissions. Add them outside the core benchmark loop to avoid perturbing cold-start numbers.

## Troubleshooting

Prometheus targets:

```bash
curl 'http://localhost:9090/api/v1/targets?state=active'
```

Grafana dashboards:

```bash
curl -u admin:admin 'http://localhost:3000/api/search?type=dash-db'
```

Stop monitored apps and containers:

```bash
scripts/monitoring/02-stop-monitoring.sh
```

Port conflict:

```text
8081 baseline
8082 cds
8083 appcds
8084 crac
8085 native
9090 prometheus
3000 grafana
```

CRaC unsupported:

```text
Unrecognized VM option 'CRaCCheckpointTo=...'
```

Use a CRaC-enabled JDK.

Native build missing `native-image`:

```bash
sdk install java 25.0.3-graal
```

The native build script automatically uses `~/.sdkman/candidates/java/25.0.3-graal` if the active JDK does not provide `native-image`. If no local `native-image` exists, it attempts a Docker BuildKit native export.

CDS/AppCDS archive errors:

```bash
scripts/03-generate-cds-archive.sh
scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh
```

Regenerate archives after changing code, dependencies, JDK, or classpath.

## Clean Generated Runtime Data

```bash
rm -rf logs build/runtime-artifacts build/native
mkdir -p logs build/runtime-artifacts build/native
: > logs/.gitkeep
: > build/runtime-artifacts/.gitkeep
```

## Current Verified Result Shape

A successful full run produces rankings similar to:

```text
Startup ranking:
native
crac
appcds
baseline
cds
```

Exact numbers vary by CPU load, filesystem cache, and background processes.
