package com.example.startupdemo.gateway;

import com.example.startupdemo.compute.ComputeService;
import com.example.startupdemo.config.GatewayProperties;
import com.example.startupdemo.dependency.DependencyWorkloadService;
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
    private final DependencyWorkloadService dependencyWorkloadService;

    public GatewayController(GatewayProperties properties, ComputeService computeService,
                             DependencyWorkloadService dependencyWorkloadService) {
        this.properties = properties;
        this.computeService = computeService;
        this.dependencyWorkloadService = dependencyWorkloadService;
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

    @GetMapping("/dependencies")
    Map<String, Object> dependencies() {
        return dependencyWorkloadService.runRequestWorkload().asMap();
    }

    @GetMapping("/dependencies/latest")
    Map<String, Object> latestDependencies() {
        return dependencyWorkloadService.latestSnapshot().asMap();
    }
}
