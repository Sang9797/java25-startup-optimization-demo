package com.example.startupdemo.crac;

import com.example.startupdemo.metrics.StartupMetrics;
import org.crac.Context;
import org.crac.Core;
import org.crac.Resource;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.stereotype.Component;

@Component
public final class CracLifecycleResource implements Resource, ApplicationListener<ApplicationReadyEvent> {
    private final StartupMetrics startupMetrics;

    public CracLifecycleResource(StartupMetrics startupMetrics) {
        this.startupMetrics = startupMetrics;
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        Core.getGlobalContext().register(this);
    }

    @Override
    public void beforeCheckpoint(Context<? extends Resource> context) {
        System.out.println("{\"event\":\"beforeCheckpoint\",\"message\":\"Spring-managed resources are quiesced by the runtime before checkpoint\"}");
    }

    @Override
    public void afterRestore(Context<? extends Resource> context) {
        startupMetrics.markRestored();
        System.out.println("{\"event\":\"afterRestore\",\"message\":\"Spring Boot gateway restored from CRaC checkpoint\"}");
    }
}
