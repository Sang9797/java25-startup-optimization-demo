package com.example.startupdemo.app;

import java.lang.management.ManagementFactory;
import java.time.Instant;
import java.util.Map;

public final class StartupInfo {
    private final long startedAtNanos;
    private final Instant processStartedAt;
    private final String pid;
    private volatile Instant lastRestoreAt;

    public StartupInfo(long startedAtNanos) {
        this.startedAtNanos = startedAtNanos;
        this.processStartedAt = Instant.now();
        this.pid = ManagementFactory.getRuntimeMXBean().getName().split("@", 2)[0];
    }

    public Map<String, Object> healthPayload() {
        return Map.of(
                "status", "UP",
                "pid", pid,
                "jvmVersion", Runtime.version().toString(),
                "uptimeMillis", uptimeMillis(),
                "processStartedAt", processStartedAt.toString(),
                "lastRestoreAt", lastRestoreAt == null ? "" : lastRestoreAt.toString()
        );
    }

    public void markRestored() {
        lastRestoreAt = Instant.now();
    }

    private long uptimeMillis() {
        return (System.nanoTime() - startedAtNanos) / 1_000_000L;
    }
}
