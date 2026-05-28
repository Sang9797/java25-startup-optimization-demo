package com.example.startupdemo.config;

import io.micrometer.core.instrument.config.MeterFilter;
import io.micrometer.core.instrument.Tags;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableConfigurationProperties(GatewayProperties.class)
public class MonitoringConfiguration {
    @Bean
    MeterFilter commonMetricTags(GatewayProperties properties) {
        return MeterFilter.commonTags(Tags.of(
                "app", properties.appName(),
                "mode", properties.runtimeMode(),
                "jdk", properties.jdk()
        ));
    }
}
