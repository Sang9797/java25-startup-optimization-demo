package com.example.startupdemo.crac;

import com.example.startupdemo.dependency.DependencyWorkloadService;
import com.example.startupdemo.metrics.StartupMetrics;
import com.zaxxer.hikari.HikariDataSource;
import org.crac.Context;
import org.crac.Core;
import org.crac.Resource;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.ProducerFactory;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;

@Component
public final class CracLifecycleResource implements Resource, ApplicationListener<ApplicationReadyEvent> {
    private final StartupMetrics startupMetrics;
    private final DependencyWorkloadService dependencyWorkloadService;
    private final DataSource dataSource;
    private final RedisConnectionFactory redisConnectionFactory;
    private final ProducerFactory<?, ?> producerFactory;

    public CracLifecycleResource(StartupMetrics startupMetrics, DependencyWorkloadService dependencyWorkloadService,
                                 DataSource dataSource, RedisConnectionFactory redisConnectionFactory,
                                 ProducerFactory<?, ?> producerFactory) {
        this.startupMetrics = startupMetrics;
        this.dependencyWorkloadService = dependencyWorkloadService;
        this.dataSource = dataSource;
        this.redisConnectionFactory = redisConnectionFactory;
        this.producerFactory = producerFactory;
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        Core.getGlobalContext().register(this);
    }

    @Override
    public void beforeCheckpoint(Context<? extends Resource> context) {
        if (producerFactory instanceof DefaultKafkaProducerFactory<?, ?> defaultKafkaProducerFactory) {
            defaultKafkaProducerFactory.reset();
        }
        if (redisConnectionFactory instanceof LettuceConnectionFactory lettuceConnectionFactory) {
            lettuceConnectionFactory.resetConnection();
        }
        if (dataSource instanceof HikariDataSource hikariDataSource) {
            hikariDataSource.getHikariPoolMXBean().softEvictConnections();
        }
        System.out.println("{\"event\":\"beforeCheckpoint\",\"message\":\"Dependency clients were quiesced before checkpoint\"}");
    }

    @Override
    public void afterRestore(Context<? extends Resource> context) {
        startupMetrics.markRestored();
        dependencyWorkloadService.runRequestWorkload();
        System.out.println("{\"event\":\"afterRestore\",\"message\":\"Spring Boot gateway restored from CRaC checkpoint\"}");
    }
}
