package com.example.startupdemo.metrics;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

@Component
public final class FirstRequestLatencyFilter extends OncePerRequestFilter {
    private final StartupMetrics startupMetrics;

    public FirstRequestLatencyFilter(StartupMetrics startupMetrics) {
        this.startupMetrics = startupMetrics;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        if (!request.getRequestURI().startsWith("/actuator")) {
            startupMetrics.recordFirstRequestIfNeeded();
        }
        filterChain.doFilter(request, response);
    }
}
