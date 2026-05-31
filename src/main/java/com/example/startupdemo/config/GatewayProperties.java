package com.example.startupdemo.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "gateway")
public record GatewayProperties(String appName, String jdk, String runtimeMode,
                                DependencyWorkload dependencyWorkload) {
    public GatewayProperties {
        if (appName == null || appName.isBlank()) {
            appName = "gateway-demo";
        }
        if (jdk == null || jdk.isBlank()) {
            jdk = String.valueOf(Runtime.version().feature());
        }
        if (runtimeMode == null || runtimeMode.isBlank()) {
            runtimeMode = System.getenv().getOrDefault("APP_RUNTIME_MODE", "baseline");
        }
        if (dependencyWorkload == null) {
            dependencyWorkload = new DependencyWorkload(true, "startup-demo-events", 10_000);
        }
    }

    public record DependencyWorkload(boolean enabled, String kafkaTopic, long timeoutMs) {
        public DependencyWorkload {
            if (kafkaTopic == null || kafkaTopic.isBlank()) {
                kafkaTopic = "startup-demo-events";
            }
            if (timeoutMs <= 0) {
                timeoutMs = 10_000;
            }
        }
    }
}
