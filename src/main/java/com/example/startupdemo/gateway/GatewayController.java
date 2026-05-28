package com.example.startupdemo.gateway;

import com.example.startupdemo.compute.ComputeService;
import com.example.startupdemo.config.GatewayProperties;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.lang.management.ManagementFactory;
import java.time.Instant;
import java.util.Map;

@RestController
public class GatewayController {
    private final GatewayProperties properties;
    private final ComputeService computeService;

    public GatewayController(GatewayProperties properties, ComputeService computeService) {
        this.properties = properties;
        this.computeService = computeService;
    }

    @GetMapping("/health")
    Map<String, Object> health() {
        return Map.of(
                "status", "UP",
                "app", properties.appName(),
                "mode", properties.runtimeMode(),
                "jdk", properties.jdk(),
                "pid", ManagementFactory.getRuntimeMXBean().getName().split("@", 2)[0],
                "time", Instant.now().toString()
        );
    }

    @GetMapping("/hello")
    Map<String, Object> hello() {
        return Map.of(
                "message", "Hello from the JDK 25 Spring Boot gateway demo",
                "mode", properties.runtimeMode(),
                "app", properties.appName()
        );
    }

    @RequestMapping("/api/users/{id}")
    Map<String, Object> user(@PathVariable String id) {
        return Map.of("route", "users", "id", id, "upstream", "users-service", "mode", properties.runtimeMode());
    }

    @RequestMapping("/api/orders/{id}")
    Map<String, Object> order(@PathVariable String id) {
        return Map.of("route", "orders", "id", id, "upstream", "orders-service", "mode", properties.runtimeMode());
    }

    @RequestMapping("/api/products/{id}")
    Map<String, Object> product(@PathVariable String id) {
        return Map.of("route", "products", "id", id, "upstream", "products-service", "mode", properties.runtimeMode());
    }

    @GetMapping("/compute")
    Map<String, Object> compute() {
        ComputeService.ComputeResult result = computeService.runSampleWorkload();
        return Map.of(
                "inputSize", result.inputSize(),
                "primeCount", result.primeCount(),
                "checksum", result.checksum(),
                "elapsedMicros", result.elapsedMicros()
        );
    }
}
