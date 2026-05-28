package com.example.startupdemo.http;

import com.example.startupdemo.config.ApplicationConfig;
import com.example.startupdemo.util.Json;

import java.util.LinkedHashMap;
import java.util.Map;

public final class HelloHandler extends JsonHandler {
    private final ApplicationConfig config;

    public HelloHandler(ApplicationConfig config) {
        this.config = config;
    }

    @Override
    protected String handleJson() {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("message", config.greeting());
        payload.put("labels", config.labels());
        payload.put("featureFlags", config.featureFlags());
        return Json.object(payload);
    }
}
