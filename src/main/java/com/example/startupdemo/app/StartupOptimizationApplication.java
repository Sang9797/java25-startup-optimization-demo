package com.example.startupdemo.app;

import com.example.startupdemo.compute.ComputeService;
import com.example.startupdemo.config.ApplicationConfig;
import com.example.startupdemo.crac.CracLifecycleResource;
import com.example.startupdemo.http.ApplicationHttpServer;
import com.example.startupdemo.http.HealthHandler;
import com.example.startupdemo.http.HelloHandler;
import com.example.startupdemo.http.ComputeHandler;
import com.example.startupdemo.util.Json;
import org.crac.Core;

import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;

public final class StartupOptimizationApplication {
    private StartupOptimizationApplication() {
    }

    public static void main(String[] args) throws Exception {
        long startedAtNanos = System.nanoTime();
        ApplicationRuntime runtime = createRuntime(startedAtNanos);
        CracLifecycleResource cracLifecycle = new CracLifecycleResource(runtime.httpServer(), runtime.startupInfo());
        Core.getGlobalContext().register(cracLifecycle);

        runtime.httpServer().start();

        long startupMillis = (System.nanoTime() - startedAtNanos) / 1_000_000L;
        logStartup(startupMillis, runtime.config());

        Runtime.getRuntime().addShutdownHook(new Thread(runtime.httpServer()::stop, "shutdown-http-server"));
        new CountDownLatch(1).await();
    }

    private static ApplicationRuntime createRuntime(long startedAtNanos) throws IOException {
        ApplicationConfig config = ApplicationConfig.load();
        ComputeService computeService = new ComputeService();
        StartupInfo startupInfo = new StartupInfo(startedAtNanos);

        ApplicationHttpServer httpServer = new ApplicationHttpServer(config.port(), List.of(
                new ApplicationHttpServer.Route("/health", new HealthHandler(startupInfo)),
                new ApplicationHttpServer.Route("/hello", new HelloHandler(config)),
                new ApplicationHttpServer.Route("/compute", new ComputeHandler(computeService))
        ));
        return new ApplicationRuntime(config, httpServer, startupInfo);
    }

    private static void logStartup(long startupMillis, ApplicationConfig config) {
        String pid = ManagementFactory.getRuntimeMXBean().getName().split("@", 2)[0];
        Map<String, Object> logEvent = Map.of(
                "event", "application started",
                "time", Instant.now().toString(),
                "jvmVersion", Runtime.version().toString(),
                "javaVendor", System.getProperty("java.vendor"),
                "pid", pid,
                "port", config.port(),
                "startupTimeMillis", startupMillis
        );
        System.out.println(Json.object(logEvent));
    }

    private record ApplicationRuntime(ApplicationConfig config, ApplicationHttpServer httpServer, StartupInfo startupInfo) {
    }
}
