package com.example.startupdemo.crac;

import com.example.startupdemo.app.StartupInfo;
import com.example.startupdemo.http.ApplicationHttpServer;
import org.crac.Context;
import org.crac.Resource;

public final class CracLifecycleResource implements Resource {
    private final ApplicationHttpServer httpServer;
    private final StartupInfo startupInfo;

    public CracLifecycleResource(ApplicationHttpServer httpServer, StartupInfo startupInfo) {
        this.httpServer = httpServer;
        this.startupInfo = startupInfo;
    }

    @Override
    public void beforeCheckpoint(Context<? extends Resource> context) {
        System.out.println("{\"event\":\"beforeCheckpoint\",\"message\":\"closing HTTP server before checkpoint\"}");
        httpServer.stop();
    }

    @Override
    public void afterRestore(Context<? extends Resource> context) throws Exception {
        System.out.println("{\"event\":\"afterRestore\",\"message\":\"reopening HTTP server after restore\"}");
        httpServer.start();
        startupInfo.markRestored();
    }
}
