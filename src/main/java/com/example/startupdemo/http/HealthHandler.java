package com.example.startupdemo.http;

import com.example.startupdemo.app.StartupInfo;
import com.example.startupdemo.util.Json;

import java.io.IOException;

public final class HealthHandler extends JsonHandler {
    private final StartupInfo startupInfo;

    public HealthHandler(StartupInfo startupInfo) {
        this.startupInfo = startupInfo;
    }

    @Override
    protected String handleJson() throws IOException {
        return Json.object(startupInfo.healthPayload());
    }
}
