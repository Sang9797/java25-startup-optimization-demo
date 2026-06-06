# JDK 25 Startup Optimization Performance Lab

Spring Boot gateway benchmark project for comparing:

- JVM baseline
- CDS
- AppCDS
- Project Leyden AOT Cache
- CRaC restore
- GraalVM Native Image

The app is a lightweight HTTP gateway/router with Actuator and Prometheus metrics plus a realistic startup dependency workload. It initializes Postgres, Redis, and Kafka before `ApplicationReadyEvent` so the benchmark captures framework startup plus external client/bootstrap cost.

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
        +--------------+--------------+
        |              |              |
 Postgres :15432  Redis :16379  Kafka :19092
        |              |              |
   +-------------------+-------------------+
   |       |           |           |       |
  8081    8082        8083        8086        8084    8085
 JVM     CDS         AppCDS      Leyden     CRaC    Native
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
GET /dependencies
GET /dependencies/latest
```

Observability:

```text
GET /actuator/health
GET /actuator/prometheus
```

## Runtime Modes

Set with:

```bash
APP_RUNTIME_MODE=baseline|cds|appcds|leyden-aot|crac|native
```

Metrics are tagged with:

```text
app="gateway-demo"
jdk="25"
mode="baseline|cds|appcds|leyden-aot|crac|native"
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
app_leyden_aot_enabled
app_crac_enabled
app_native_enabled
app_dependency_postgres_startup_ms
app_dependency_redis_startup_ms
app_dependency_kafka_startup_ms
app_dependency_total_startup_ms
```

## Requirements

- JDK 25
- Maven 3.9+
- Docker + Docker Compose
- `curl`
- `k6` for load tests
- A JDK 25+ build with Project Leyden AOT cache flags for `leyden-aot`
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

Check Leyden AOT cache support:

```bash
java -XX:AOTMode=off -version
```

## Recommended Comparison Script

Use `scripts/compare.sh` as the main entrypoint for multi-mode runs. It handles jar builds, dependency services, mode-specific artifacts, monitoring, and result output.

```bash
# Remove old logs before a fresh test phase.
find logs -type f -name '*.log' -delete

# Default: baseline vs native cold/startup comparison.
scripts/compare.sh
```

Detailed single-mode, native-mode, and mixed-mode examples are in the `Workflows` section below.

Outputs for cold selected-mode comparisons:

```text
logs/cold-<mode-list>/compare-summary.md
logs/cold-<mode-list>/benchmark-monitoring-results.csv
logs/cold-<mode-list>/benchmark-monitoring-results.txt
logs/cold-<mode-list>/<mode>/
```

Use `--skip-build` and `--skip-native-build` only when you know existing artifacts are current.

## Run From Zero

Use this order from a clean checkout. The order matters because CDS/AppCDS/Leyden AOT/CRaC/native modes depend on generated build artifacts.
The run and benchmark scripts automatically start Postgres, Redis, and Kafka from `docker-compose.monitoring.yml`. To run without external dependencies for a quick smoke test, set `DEPENDENCY_WORKLOAD_ENABLED=false`.

```bash
cd /home/sangle/codex/java25-startup-optimization-demo

# 1. Build the Spring Boot gateway jar and dependency classpath.
scripts/01-build.sh

# 2. Generate JVM CDS, AppCDS, and Leyden AOT runtime artifacts.
# These steps start Postgres, Redis, and Kafka because the AppCDS class list
# and Leyden AOT cache are generated from a real dependency-backed application startup.
# The Leyden AOT cache step keeps the app alive for a configurable k6 training
# pass across /health, /hello, /compute, /api/*, /dependencies, and /dependencies/latest
# before the cache is written.
scripts/03-generate-cds-archive.sh
scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh
scripts/11-generate-leyden-aot-cache.sh

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
scripts/monitoring/08-run-leyden-aot-monitored.sh
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
for p in 8081 8082 8083 8086 8084 8085; do
  curl -fsS "http://localhost:$p/actuator/health"
done

curl -fsS 'http://localhost:9090/api/v1/targets?state=active'

curl -fsS -u admin:admin 'http://localhost:3000/api/search?type=dash-db'
```

## Workflows

### Single Mode

Build the shared application artifact first:

```bash
scripts/01-build.sh
```

Run one mode at a time:

```bash
scripts/02-run-baseline.sh
scripts/04-run-with-cds.sh
scripts/07-run-with-appcds.sh
scripts/12-run-with-leyden-aot.sh
scripts/09-crac-restore.sh
scripts/native/02-run-native.sh
```

Generate per-mode prerequisites only when needed:

```bash
scripts/03-generate-cds-archive.sh
scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh
scripts/11-generate-leyden-aot-cache.sh
scripts/08-crac-checkpoint.sh
```

### Native Mode

Default native build:

```bash
scripts/native/01-build-native.sh
scripts/native/02-run-native.sh
```

PGO flow:

```bash
scripts/native/04-build-native-pgo-instrumented.sh
scripts/native/02-run-native.sh
k6 run load-tests/k6-gateway.js
scripts/native/05-build-native-pgo-optimized.sh
```

Native build variants:

```bash
# Targeted compatibility help for migration.
NATIVE_PRESERVE='package=com.example.startupdemo.dependency.*' \
  scripts/native/01-build-native.sh

# Export SBOM when using Oracle GraalVM.
NATIVE_ENABLE_SBOM=classpath,export \
  scripts/native/01-build-native.sh

# Enable advanced obfuscation when using Oracle GraalVM.
NATIVE_ENABLE_OBFUSCATION=true \
NATIVE_ENABLE_SBOM=export \
  scripts/native/01-build-native.sh

# Pass extra native-image flags directly.
NATIVE_EXTRA_ARGS='-O3 -march=native' \
  scripts/native/01-build-native.sh
```

Export the SBOM from an existing native binary:

```bash
scripts/native/06-export-native-sbom.sh
```

Native build artifacts:

```text
build/native/gateway-native
build/native/default.iprof
build/native/gateway-native.sbom.json
target/native-build-report.html
target/native-build-output.json
```

Notes:

- `--enable-sbom`, advanced obfuscation, and PGO are Oracle GraalVM features.
- `NATIVE_PGO_MODE=instrument|optimize` is also supported directly by `scripts/native/01-build-native.sh`.
- Use `-H:Preserve` as a migration aid, then narrow back down to explicit hints.

### Mixed Mode

Use `scripts/compare.sh` as the main entrypoint for multi-mode runs. It builds missing artifacts, starts dependency services, and writes outputs under `logs/<type>-<mode-list>/`.

Cold comparison:

```bash
scripts/compare.sh --modes baseline,native --type cold --iterations 3
scripts/compare.sh --modes baseline,cds,appcds,leyden-aot,native --type cold --iterations 3 --skip-native-build
scripts/compare.sh --modes baseline,cds,appcds,leyden-aot,crac,native --type cold --iterations 3
```

Long sequential comparison:

```bash
LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 \
  scripts/compare.sh --modes baseline,leyden-aot,native --type long --skip-native-build

LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 \
  scripts/compare.sh --modes baseline,native --type long --skip-native-build

LONG_WARMUP_DURATION=5m LONG_DURATION=30m LONG_K6_VUS=16 \
  scripts/compare.sh --modes native,leyden-aot --type long --skip-native-build
```

Live Grafana comparison:

```bash
LONG_DURATION=30m LONG_K6_VUS=8 \
  scripts/compare.sh --modes baseline,leyden-aot,native --type grafana --skip-native-build

LONG_DURATION=30m LONG_K6_VUS=8 \
  scripts/compare.sh --modes baseline,native --type grafana --skip-native-build

LONG_DURATION=30m LONG_K6_VUS=8 \
  scripts/compare.sh --modes native,leyden-aot --type grafana --skip-native-build
```

Fast smoke-test form:

```bash
LONG_WARMUP_DURATION=1s LONG_DURATION=2s LONG_K6_VUS=1 LONG_SAMPLE_INTERVAL_SECONDS=1 \
  scripts/compare.sh --modes baseline,leyden-aot,native --type long --iterations 1 --skip-build --skip-native-build --no-monitoring
```

Leyden cache retraining:

```bash
LEYDEN_AOT_TRAINING_DURATION=3m LEYDEN_AOT_TRAINING_VUS=4 \
  scripts/compare.sh --modes baseline,leyden-aot,native --type long --skip-native-build
```

Native-aware `compare.sh` options:

```bash
# Build, train, and benchmark a PGO-optimized native image in one flow.
scripts/compare.sh --modes baseline,native --type cold --native-build-mode pgo-auto

# Benchmark an already-built PGO-optimized native executable.
scripts/compare.sh --modes native --type long --native-build-mode pgo-optimize --skip-native-build

# Benchmark a native build with targeted preservation.
scripts/compare.sh --modes native --type cold \
  --native-preserve 'package=com.example.startupdemo.dependency.*'

# Benchmark a native build with SBOM export.
scripts/compare.sh --modes native --type cold --native-sbom classpath,export

# Benchmark a native build with obfuscation.
scripts/compare.sh --modes native --type cold --native-obfuscation --native-sbom export
```

Common outputs:

```text
logs/cold-<mode-list>/compare-summary.md
logs/cold-<mode-list>/benchmark-monitoring-results.csv
logs/cold-<mode-list>/benchmark-monitoring-results.txt
logs/cold-<mode-list>/<mode>/

logs/long-run-<mode-list>/<mode-list>-summary.md
logs/long-run-<mode-list>/<mode-list>-summary.csv
logs/long-run-<mode-list>/<mode-list>-samples.csv
logs/long-run-<mode-list>/<mode>/
```

Benchmark metrics include startup time, Spring Boot startup time, first and warm request latency, RSS, heap and non-heap usage, CPU, dependency startup cost, throughput, HTTP p95, GC counters, loaded classes, and image size where available.

CRaC note: `process_startup_ms` is restore-to-health time. `spring_boot_startup_ms` stays empty because Spring Boot startup does not run again after restore.

### Full Lab

Build every artifact, then run all monitored modes side by side:

```bash
scripts/01-build.sh
scripts/03-generate-cds-archive.sh
scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh
scripts/11-generate-leyden-aot-cache.sh
scripts/08-crac-checkpoint.sh
scripts/native/01-build-native.sh

scripts/monitoring/01-start-monitoring.sh
scripts/monitoring/03-run-baseline-monitored.sh
scripts/monitoring/04-run-cds-monitored.sh
scripts/monitoring/05-run-appcds-monitored.sh
scripts/monitoring/08-run-leyden-aot-monitored.sh
scripts/monitoring/06-run-crac-monitored.sh
scripts/native/03-run-native-monitored.sh
```

Stop everything:

```bash
scripts/monitoring/02-stop-monitoring.sh
```

### Quick Check

If the lab is already running:

```bash
docker ps

for p in 8081 8082 8083 8086 8084 8085; do
  curl -fsS "http://localhost:$p/actuator/health"
done

curl -fsS 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D~%22gateway-.*%22%7D'
curl -fsS -u admin:admin 'http://localhost:3000/api/search?type=dash-db'
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

Postgres, Redis, and Kafka are part of the default compose stack because app startup depends on them. They are exposed on host ports `15432`, `16379`, and `19092` to avoid common local service conflicts. Optional app containers are defined with compose profiles, but the default Prometheus config scrapes host-run apps on ports `8081` to `8086`. This avoids down targets when optional containers are not running.

## Grafana Dashboards

Provisioned dashboards:

```text
JVM Startup Optimization Comparison
Native Image vs JVM
Memory & Resource Analysis
Cold Start Comparison
Long Run Baseline vs Native
Long Run Native vs Leyden AOT Cache
```

Panels include startup bars, first request latency, Leyden AOT cache startup, CRaC restore time, native cold start, heap/non-heap/RSS memory, CPU usage, loaded classes, GC, HTTP throughput, p95 latency, heatmaps, and ranking tables.
The long-run dashboard adds p99 latency, HTTP error rate, request mix, and side-by-side CPU/RSS/GC views for baseline and native under sustained load.

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
Long Run Baseline vs Native
Long Run Native vs Leyden AOT Cache
```

Recommended viewing order:

1. **Cold Start Comparison**
   - Use this first to see startup time ranking and first request latency.
   - Key panels: `Cold start by mode`, `First request by mode`, `Ranking all runtime modes`.

2. **JVM Startup Optimization Comparison**
   - Use this to compare baseline, CDS, AppCDS, Leyden AOT, CRaC, and native on startup, p95 HTTP latency, and throughput.
   - Key panels: `Startup time comparison`, `HTTP latency p95`, `Throughput by mode`, `Startup leaderboard`.

3. **Native Image vs JVM**
   - Use this to focus on native image startup, RSS, CPU, and latency compared with JVM baseline.
   - Key panels: `Native Image cold start advantage`, `Native vs JVM RSS`, `Native vs JVM CPU usage`.

4. **Memory & Resource Analysis**
   - Use this for heap, non-heap, process RSS, loaded classes, GC pause, GC count, and CPU.
   - Native Image may show missing or zero values for some JVM-specific metrics; see Native Image Notes.

5. **Long Run Baseline vs Native**
   - Use this while running sustained load to decide whether Native Image remains better after JVM JIT warmup.
   - Key panels: `Throughput`, `Latency p95`, `Latency p99`, `CPU Usage`, `RSS Memory`, `HTTP Error Rate`, `GC Pause Rate`, `Dependency Startup Breakdown`.

6. **Long Run Native vs Leyden AOT Cache**
   - Use this while running sustained load to compare Native Image against Leyden AOT cache startup, throughput, latency, CPU, RSS, GC, and dependency startup cost.
   - Key panels: `Startup Time`, `Throughput`, `Latency p95`, `Latency p99`, `CPU Usage`, `JVM Memory Used`, `Current Comparison Snapshot`.

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

You should see six `up = 1` targets:

```text
gateway-baseline
gateway-cds
gateway-appcds
gateway-leyden-aot
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

Leyden AOT cache marker:

```promql
max(app_leyden_aot_enabled{app="gateway-demo",jdk="25",mode="leyden-aot"})
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

Dependency startup:

```promql
max by (mode) (app_dependency_total_startup_ms{app="gateway-demo",jdk="25"})
max by (mode) (app_dependency_postgres_startup_ms{app="gateway-demo",jdk="25"})
max by (mode) (app_dependency_redis_startup_ms{app="gateway-demo",jdk="25"})
max by (mode) (app_dependency_kafka_startup_ms{app="gateway-demo",jdk="25"})
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
8086 leyden-aot
8084 crac
8085 native
15432 postgres
16379 redis
19092 kafka
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

Leyden AOT cache errors:

```bash
scripts/11-generate-leyden-aot-cache.sh
scripts/12-run-with-leyden-aot.sh
```

Regenerate the AOT cache after changing code, dependencies, JDK, classpath, or startup training traffic.
You can tune the training pass with `LEYDEN_AOT_TRAINING_DURATION` and `LEYDEN_AOT_TRAINING_VUS`.

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
