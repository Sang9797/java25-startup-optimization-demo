package com.example.startupdemo.config;

import java.util.List;
import java.util.Locale;
import java.util.Map;

public record ApplicationConfig(int port, String greeting, Map<String, String> labels, List<String> featureFlags) {
    public static ApplicationConfig load() {
        int port = Integer.parseInt(System.getProperty("demo.port", "8080"));
        String greeting = System.getProperty("demo.greeting", "Hello from Java startup optimization demo");
        return new ApplicationConfig(
                port,
                greeting,
                Map.of(
                        "runtime", "java-" + Runtime.version().feature(),
                        "profile", System.getProperty("demo.profile", "local").toLowerCase(Locale.ROOT),
                        "server", "jdk-http-server"
                ),
                List.of("health-endpoint", "compute-endpoint", "crac-resource-lifecycle", "appcds-class-shape")
        );
    }
}
