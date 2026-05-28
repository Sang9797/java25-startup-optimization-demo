package com.example.startupdemo.http;

import com.example.startupdemo.util.Json;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

public abstract class JsonHandler implements HttpHandler {
    @Override
    public final void handle(HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) {
            write(exchange, 405, Json.object(Map.of("error", "method not allowed")));
            return;
        }
        try {
            write(exchange, 200, handleJson());
        } catch (RuntimeException ex) {
            write(exchange, 500, Json.object(Map.of("error", ex.getMessage())));
        }
    }

    protected abstract String handleJson() throws IOException;

    private static void write(HttpExchange exchange, int statusCode, String body) throws IOException {
        byte[] bytes = (body + System.lineSeparator()).getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(statusCode, bytes.length);
        try (OutputStream outputStream = exchange.getResponseBody()) {
            outputStream.write(bytes);
        }
    }
}
