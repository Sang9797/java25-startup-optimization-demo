# Java 25 Startup Optimization Demo

This is a complete Maven demo project for comparing four startup modes:

- normal JVM startup
- CDS startup with a custom base archive
- AppCDS startup with application classes in the archive
- CRaC restore startup from a checkpoint image

The application is a plain Java HTTP service using `com.sun.net.httpserver.HttpServer`. It avoids Spring Boot so the CDS/AppCDS mechanics are visible and easy to reproduce.

## Project Tree

```text
.
├── pom.xml
├── README.md
├── src/main/java/com/example/startupdemo
│   ├── app
│   │   ├── StartupInfo.java
│   │   └── StartupOptimizationApplication.java
│   ├── compute
│   │   └── ComputeService.java
│   ├── config
│   │   └── ApplicationConfig.java
│   ├── crac
│   │   └── CracLifecycleResource.java
│   ├── http
│   │   ├── ApplicationHttpServer.java
│   │   ├── ComputeHandler.java
│   │   ├── HealthHandler.java
│   │   ├── HelloHandler.java
│   │   └── JsonHandler.java
│   └── util
│       └── Json.java
├── scripts
│   ├── common.sh
│   ├── 01-build.sh
│   ├── 02-run-baseline.sh
│   ├── 03-generate-cds-archive.sh
│   ├── 04-run-with-cds.sh
│   ├── 05-generate-appcds-classlist.sh
│   ├── 06-generate-appcds-archive.sh
│   ├── 07-run-with-appcds.sh
│   ├── 08-crac-checkpoint.sh
│   ├── 09-crac-restore.sh
│   └── 10-benchmark-all.sh
├── logs
│   └── .gitkeep
└── build/runtime-artifacts
    └── .gitkeep
```

## Requirements

- Java/JDK 25 for building this project.
- Maven 3.9+.
- Linux or macOS for CDS/AppCDS scripts.
- `curl` for health checks in scripts.
- CRaC requires a CRaC-enabled JDK/build and Linux support. A standard JDK 25 normally supports CDS/AppCDS, but does not necessarily support `-XX:CRaCCheckpointTo`, `-XX:CRaCRestoreFrom`, or `jcmd JDK.checkpoint`.

The project depends on `org.crac:crac:1.5.0`. That library lets the CRaC lifecycle API compile and run on ordinary JDKs, but it does not add checkpoint/restore support to a JVM that lacks CRaC.

Useful references:

- CRaC project overview: https://crac.org/
- OpenJDK CRaC wiki: https://wiki.openjdk.org/display/crac/Main
- Azul CRaC usage notes: https://docs.azul.com/core/crac/crac-guidelines
- `org.crac` Maven artifact: https://central.sonatype.com/artifact/org.crac/crac

## Application

The server listens on port `8080` by default.

Endpoints:

- `GET /health`
- `GET /hello`
- `GET /compute`

At startup the application logs a JSON event with:

- `event=application started`
- JVM version
- Java vendor
- PID
- port
- startup time in milliseconds

All script logs are written under `logs/`. Runtime archives, class lists, and checkpoint files are written under `build/runtime-artifacts/`.

Override the port with:

```bash
APP_PORT=9090 scripts/02-run-baseline.sh
```

## Run From Zero

```bash
scripts/01-build.sh

scripts/02-run-baseline.sh

scripts/03-generate-cds-archive.sh
scripts/04-run-with-cds.sh

scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh
scripts/07-run-with-appcds.sh

# Only on Linux with a CRaC-enabled JDK/build:
scripts/08-crac-checkpoint.sh
scripts/09-crac-restore.sh

ITERATIONS=5 scripts/10-benchmark-all.sh
```

To inspect loaded class logging:

```bash
grep "class,load" logs/*.log | wc -l
```

## Script Details

### `01-build.sh`

Builds the Maven jar and copies runtime dependencies to `target/lib`.

Output logs:

- `logs/01-java-version.log`
- `logs/01-build.log`

### `02-run-baseline.sh`

Runs the application without a custom archive:

```bash
java -Xlog:class+load=info -cp "$CP" com.example.startupdemo.app.StartupOptimizationApplication
```

Output log:

- `logs/02-baseline.log`

### `03-generate-cds-archive.sh`

Generates a custom base CDS archive:

```bash
java -Xshare:dump \
  -XX:SharedArchiveFile=build/runtime-artifacts/cds-base.jsa \
  -Xlog:cds=info
```

Output:

- `build/runtime-artifacts/cds-base.jsa`
- `logs/03-generate-cds-archive.log`

### `04-run-with-cds.sh`

Runs with the generated base CDS archive:

```bash
java -Xshare:on \
  -XX:SharedArchiveFile=build/runtime-artifacts/cds-base.jsa \
  -Xlog:cds=info,class+load=info \
  -cp "$CP" \
  com.example.startupdemo.app.StartupOptimizationApplication
```

Output log:

- `logs/04-cds.log`

### `05-generate-appcds-classlist.sh`

Runs the application and records loaded classes:

```bash
java -XX:DumpLoadedClassList=build/runtime-artifacts/appcds.classlist \
  -Xlog:class+load=info \
  -cp "$CP" \
  com.example.startupdemo.app.StartupOptimizationApplication
```

Output:

- `build/runtime-artifacts/appcds.classlist`
- `logs/05-generate-appcds-classlist.log`

### `06-generate-appcds-archive.sh`

Creates an AppCDS archive from the class list:

```bash
java -Xshare:dump \
  -XX:SharedClassListFile=build/runtime-artifacts/appcds.classlist \
  -XX:SharedArchiveFile=build/runtime-artifacts/appcds.jsa \
  -Xlog:cds=info \
  -cp "$CP"
```

Output:

- `build/runtime-artifacts/appcds.jsa`
- `logs/06-generate-appcds-archive.log`

The log also records the equivalent dynamic archive shape using:

```bash
java -XX:ArchiveClassesAtExit=build/runtime-artifacts/appcds-dynamic-at-exit.jsa ...
```

### `07-run-with-appcds.sh`

Runs with the generated AppCDS archive:

```bash
java -Xshare:on \
  -XX:SharedArchiveFile=build/runtime-artifacts/appcds.jsa \
  -Xlog:cds=info,class+load=info \
  -cp "$CP" \
  com.example.startupdemo.app.StartupOptimizationApplication
```

Output log:

- `logs/07-appcds.log`

### `08-crac-checkpoint.sh`

Starts the application with a checkpoint target and requests a checkpoint through `jcmd`:

```bash
java -XX:CRaCCheckpointTo=build/runtime-artifacts/crac-checkpoint \
  -cp "$CP" \
  com.example.startupdemo.app.StartupOptimizationApplication

jcmd "$PID" JDK.checkpoint
```

Output:

- `build/runtime-artifacts/crac-checkpoint/`
- `logs/08-crac-checkpoint.log`

During checkpoint, `CracLifecycleResource.beforeCheckpoint()` closes the HTTP server so open listening sockets are not captured incorrectly.

### `09-crac-restore.sh`

Restores from the checkpoint:

```bash
java -XX:CRaCRestoreFrom=build/runtime-artifacts/crac-checkpoint
```

Output log:

- `logs/09-crac-restore.log`

During restore, `CracLifecycleResource.afterRestore()` reopens the HTTP server.

### `10-benchmark-all.sh`

Runs each available mode multiple times and writes:

- `logs/benchmark-results.txt`
- `logs/benchmark-baseline-*.log`
- `logs/benchmark-cds-*.log`
- `logs/benchmark-appcds-*.log`
- `logs/benchmark-crac-restore-*.log`

Set the number of iterations:

```bash
ITERATIONS=10 scripts/10-benchmark-all.sh
```

## Concepts

### CDS

Class Data Sharing stores JVM metadata for a set of classes in a shared archive. On later JVM starts, class metadata can be memory-mapped from the archive instead of recreated from scratch. CDS is primarily useful for reducing startup cost and memory footprint for classes known to the JVM/runtime.

In this project, `cds-base.jsa` is a custom base archive generated by `-Xshare:dump`.

### AppCDS

Application Class Data Sharing extends the idea to application and dependency classes. The usual flow is:

1. Run the application once with `-XX:DumpLoadedClassList`.
2. Generate an archive using that class list.
3. Run later starts with `-Xshare:on` and `-XX:SharedArchiveFile`.

AppCDS is useful when the application repeatedly starts with the same classpath and similar startup code path.

### CRaC

Coordinated Restore at Checkpoint checkpoints a running, initialized JVM process and restores it later. Instead of optimizing class loading alone, CRaC can preserve a warmed application state. It requires lifecycle coordination because open files, sockets, remote connections, timers, credentials, and machine-specific state may not be valid after restore.

This demo registers `CracLifecycleResource`:

- `beforeCheckpoint()` closes the HTTP server.
- `afterRestore()` starts the HTTP server again.

### CDS/AppCDS vs CRaC

CDS and AppCDS optimize JVM class metadata loading during a normal JVM start. The process still starts from `main()`.

CRaC restores a process image from a previous running state. The restored process does not repeat normal startup in the same way, so its measured restore time can be much lower. The tradeoff is operational complexity: CRaC needs a compatible runtime, OS support, checkpoint storage, and careful resource lifecycle code.

## When To Use Each

Use CDS when:

- you want a low-risk JVM-supported startup optimization
- the app starts frequently
- you want modest improvement with minimal code changes

Use AppCDS when:

- startup loads many stable application/dependency classes
- the deployment classpath is stable
- you can generate archives as part of build or release

Use CRaC when:

- startup and warmup dominate latency or scaling time
- the runtime and infrastructure support CRaC
- the application can safely close and reopen external resources
- checkpoint images can be protected like sensitive runtime memory

## Interpreting Results

Open `logs/benchmark-results.txt`.

For baseline, CDS, and AppCDS, compare `startupTimeMillis`. This value is emitted by the application after the HTTP server starts. Lower is better.

For CRaC restore, compare `externalRestoreMillis`. This is measured by the shell from launching `java -XX:CRaCRestoreFrom=...` until `/health` responds. It is not identical to `startupTimeMillis`, because a restored process does not execute normal startup from `main()`.

Also inspect class loading logs:

```bash
grep "class,load" logs/*.log | wc -l
grep "source: shared objects file" logs/07-appcds.log | wc -l
```

Class counts are not the same as latency, but they help confirm that archive sharing is being used.

Run each benchmark multiple times. JVM startup measurements are noisy because of filesystem cache, CPU power state, background load, and port reuse timing.

## Troubleshooting

### Archive not found

Run the archive generation step first:

```bash
scripts/03-generate-cds-archive.sh
scripts/05-generate-appcds-classlist.sh
scripts/06-generate-appcds-archive.sh
```

### Wrong archive path

All scripts use paths relative to the repository root. Do not run copied commands from another directory unless you adjust paths.

Expected archive locations:

- `build/runtime-artifacts/cds-base.jsa`
- `build/runtime-artifacts/appcds.jsa`

### Class list empty

Check:

```bash
cat logs/05-generate-appcds-classlist.log
```

Common causes:

- the application failed before startup
- port `8080` was already in use
- the script could not reach `/health`
- the classpath changed between generation steps

### CRaC permission issue

CRaC commonly needs Linux kernel and CRIU permissions/capabilities. Depending on your runtime and OS, you may need elevated privileges, relaxed ptrace restrictions, or container options such as `--privileged`.

Check:

```bash
cat logs/08-crac-checkpoint.log
```

### CRaC unsupported JDK

If you see an error like `Unrecognized VM option 'CRaCCheckpointTo'`, your JVM is not CRaC-enabled. Install and run a CRaC-enabled JDK/build, then ensure `java` and `jcmd` both come from that installation:

```bash
which java
which jcmd
java -version
```

### Port 8080 already in use

Find and stop the process using the port, or run with another port:

```bash
APP_PORT=9090 scripts/02-run-baseline.sh
```

For manual JVM commands, also pass:

```bash
-Ddemo.port=9090
```

## Limitations

- JDK 25 CDS/AppCDS flags are JVM-specific in their exact behavior. The scripts use common HotSpot flags.
- AppCDS archives are sensitive to classpath changes. Rebuild the class list and archive after changing application code or dependencies.
- CDS and AppCDS do not preserve warmed heap state, JIT state, or open resources as a restored process image.
- CRaC support is not guaranteed in a standard JDK 25 distribution. Use a CRaC-enabled JDK/build on Linux.
- CRaC checkpoint images can contain secrets from process memory. Treat `build/runtime-artifacts/crac-checkpoint/` as sensitive.
- CRaC checkpoints are not generally portable across arbitrary kernels, CPUs, containers, or runtime versions.
