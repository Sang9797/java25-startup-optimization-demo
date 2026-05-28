package com.example.startupdemo.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "gateway")
public record GatewayProperties(String appName, String jdk, String runtimeMode) {
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
    }
}
