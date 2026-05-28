package com.example.startupdemo.app;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

@SpringBootApplication(scanBasePackages = "com.example.startupdemo")
public class StartupOptimizationApplication {
    public static final long PROCESS_START_NANOS = System.nanoTime();
    public static final Instant PROCESS_START_INSTANT = Instant.now();

    public static void main(String[] args) {
        SpringApplication application = new SpringApplication(StartupOptimizationApplication.class);
        Map<String, Object> defaults = new HashMap<>();
        defaults.put("server.port", System.getProperty("demo.port", System.getenv().getOrDefault("SERVER_PORT", "8080")));
        application.setDefaultProperties(defaults);
        application.run(args);
    }
}
