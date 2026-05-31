package com.example.startupdemo.metrics;

import com.example.startupdemo.app.StartupOptimizationApplication;
import com.example.startupdemo.config.GatewayProperties;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.stereotype.Component;

import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

@Component
public final class StartupMetrics implements ApplicationListener<ApplicationReadyEvent> {
    private final GatewayProperties properties;
    private final AtomicLong startupTimeMs = new AtomicLong(-1);
    private final AtomicLong springBootStartupTimeMs = new AtomicLong(-1);
    private final AtomicLong restoreTimeMs = new AtomicLong(-1);
    private final AtomicLong firstRequestLatencyMs = new AtomicLong(-1);
    private volatile boolean ready;

    public StartupMetrics(MeterRegistry registry, GatewayProperties properties) {
        this.properties = properties;
        registerGauges(registry);
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        long processStartupMs = (System.nanoTime() - StartupOptimizationApplication.PROCESS_START_NANOS) / 1_000_000L;
        long bootStartupMs = event.getTimeTaken() == null ? processStartupMs : event.getTimeTaken().toMillis();
        startupTimeMs.set(processStartupMs);
        springBootStartupTimeMs.set(bootStartupMs);
        ready = true;

        String pid = ManagementFactory.getRuntimeMXBean().getName().split("@", 2)[0];
        String jvmVersion = Runtime.version().toString();
        String logLine = "{\"event\":\"application started\""
                + ",\"app\":\"" + properties.appName() + "\""
                + ",\"mode\":\"" + properties.runtimeMode() + "\""
                + ",\"jdk\":\"" + properties.jdk() + "\""
                + ",\"jvmVersion\":\"" + jvmVersion + "\""
                + ",\"pid\":\"" + pid + "\""
                + ",\"startupTimeMillis\":" + processStartupMs
                + ",\"springBootStartupTimeMillis\":" + bootStartupMs
                + "}";
        System.out.println(logLine);
    }

    public void recordFirstRequestIfNeeded() {
        if (ready && firstRequestLatencyMs.get() < 0) {
            long latencyMs = (System.nanoTime() - StartupOptimizationApplication.PROCESS_START_NANOS) / 1_000_000L;
            firstRequestLatencyMs.compareAndSet(-1, latencyMs);
        }
    }

    public void markRestored() {
        long restoredMs = Duration.between(StartupOptimizationApplication.PROCESS_START_INSTANT, Instant.now()).toMillis();
        restoreTimeMs.set(restoredMs);
    }

    private void registerGauges(MeterRegistry registry) {
        Gauge.builder("app.startup.time.ms", startupTimeMs, AtomicLong::get)
                .description("Process startup time from main entry to Spring ApplicationReadyEvent.")
                .register(registry);
        Gauge.builder("app.spring.boot.startup.time.ms", springBootStartupTimeMs, AtomicLong::get)
                .description("Spring Boot ApplicationReadyEvent startup time.")
                .register(registry);
        Gauge.builder("app.restore.time.ms", restoreTimeMs, AtomicLong::get)
                .description("Elapsed process lifetime when CRaC afterRestore was called. -1 means no restore observed.")
                .register(registry);
        Gauge.builder("app.first.request.latency.ms", firstRequestLatencyMs, AtomicLong::get)
                .description("Elapsed time from process start to the first non-actuator request. -1 means no request observed.")
                .register(registry);
        Gauge.builder("process.resident.memory.bytes", this, ignored -> residentMemoryBytes())
                .description("Resident set size of the current process in bytes.")
                .register(registry);
        Gauge.builder("app.jvm.mode", this, ignored -> 1.0)
                .description("Runtime mode marker. The mode tag carries baseline, cds, appcds, crac, native, or leyden-aot.")
                .register(registry);
        Gauge.builder("app.cds.enabled", this, ignored -> enabled("cds"))
                .description("1 when the configured runtime mode is cds.")
                .register(registry);
        Gauge.builder("app.appcds.enabled", this, ignored -> enabled("appcds"))
                .description("1 when the configured runtime mode is appcds.")
                .register(registry);
        Gauge.builder("app.crac.enabled", this, ignored -> enabled("crac"))
                .description("1 when the configured runtime mode is crac.")
                .register(registry);
        Gauge.builder("app.native.enabled", this, ignored -> enabled("native"))
                .description("1 when the configured runtime mode is native.")
                .register(registry);
        Gauge.builder("app.leyden.aot.enabled", this, ignored -> enabled("leyden-aot"))
                .description("1 when the configured runtime mode is leyden-aot.")
                .register(registry);
    }

    private double enabled(String expectedMode) {
        return expectedMode.equals(properties.runtimeMode().toLowerCase(Locale.ROOT)) ? 1.0 : 0.0;
    }

    private double residentMemoryBytes() {
        try {
            for (String line : Files.readAllLines(Path.of("/proc/self/status"))) {
                if (line.startsWith("VmRSS:")) {
                    String value = line.replaceAll("[^0-9]", "");
                    if (!value.isBlank()) {
                        return Long.parseLong(value) * 1024.0;
                    }
                }
            }
        } catch (Exception ignored) {
            // Fall through to -1 when the host does not expose /proc/self/status.
        }
        return -1.0;
    }

    public Map<String, Long> snapshot() {
        return Map.of(
                "startupTimeMs", startupTimeMs.get(),
                "springBootStartupTimeMs", springBootStartupTimeMs.get(),
                "restoreTimeMs", restoreTimeMs.get(),
                "firstRequestLatencyMs", firstRequestLatencyMs.get()
        );
    }
}
