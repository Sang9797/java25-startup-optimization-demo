package com.example.startupdemo.config;

import org.springframework.aot.hint.RuntimeHints;
import org.springframework.aot.hint.RuntimeHintsRegistrar;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.ImportRuntimeHints;

@Configuration
@ImportRuntimeHints(NativeRuntimeHints.GatewayRuntimeHints.class)
public class NativeRuntimeHints {
    static final class GatewayRuntimeHints implements RuntimeHintsRegistrar {
        @Override
        public void registerHints(RuntimeHints hints, ClassLoader classLoader) {
            // Spring Boot AOT supplies the required web, actuator, and Micrometer hints for this app.
            // This registrar is intentionally small and is a stable place for future gateway reflection hints.
        }
    }
}
