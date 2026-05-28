package com.example.startupdemo.http;

import com.example.startupdemo.compute.ComputeService;
import com.example.startupdemo.util.Json;

import java.util.Map;

public final class ComputeHandler extends JsonHandler {
    private final ComputeService computeService;

    public ComputeHandler(ComputeService computeService) {
        this.computeService = computeService;
    }

    @Override
    protected String handleJson() {
        ComputeService.ComputeResult result = computeService.runSampleWorkload();
        return Json.object(Map.of(
                "inputSize", result.inputSize(),
                "primeCount", result.primeCount(),
                "checksum", result.checksum(),
                "elapsedMicros", result.elapsedMicros()
        ));
    }
}
