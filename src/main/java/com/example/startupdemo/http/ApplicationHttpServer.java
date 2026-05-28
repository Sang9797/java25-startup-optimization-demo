package com.example.startupdemo.http;

import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class ApplicationHttpServer {
    private final int port;
    private final List<Route> routes;
    private HttpServer server;
    private ExecutorService executor;

    public ApplicationHttpServer(int port, List<Route> routes) {
        this.port = port;
        this.routes = List.copyOf(routes);
    }

    public synchronized void start() throws IOException {
        if (server != null) {
            return;
        }
        executor = Executors.newVirtualThreadPerTaskExecutor();
        server = HttpServer.create(new InetSocketAddress(port), 0);
        for (Route route : routes) {
            server.createContext(route.path(), route.handler());
        }
        server.setExecutor(executor);
        server.start();
    }

    public synchronized void stop() {
        if (server != null) {
            server.stop(0);
            server = null;
        }
        if (executor != null) {
            executor.close();
            executor = null;
        }
    }

    public int port() {
        return port;
    }

    public record Route(String path, HttpHandler handler) {
    }
}
