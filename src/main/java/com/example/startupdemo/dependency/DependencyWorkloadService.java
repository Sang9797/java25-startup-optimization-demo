package com.example.startupdemo.dependency;

import com.example.startupdemo.config.GatewayProperties;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

@Service
public final class DependencyWorkloadService implements ApplicationRunner {
    private final GatewayProperties properties;
    private final JdbcTemplate jdbcTemplate;
    private final StringRedisTemplate redisTemplate;
    private final KafkaTemplate<String, String> kafkaTemplate;
    private final AtomicLong postgresStartupMs = new AtomicLong(-1);
    private final AtomicLong redisStartupMs = new AtomicLong(-1);
    private final AtomicLong kafkaStartupMs = new AtomicLong(-1);
    private final AtomicLong totalStartupMs = new AtomicLong(-1);
    private volatile DependencySnapshot latestSnapshot = DependencySnapshot.disabled();

    public DependencyWorkloadService(GatewayProperties properties, JdbcTemplate jdbcTemplate,
                                     StringRedisTemplate redisTemplate,
                                     KafkaTemplate<String, String> kafkaTemplate,
                                     MeterRegistry registry) {
        this.properties = properties;
        this.jdbcTemplate = jdbcTemplate;
        this.redisTemplate = redisTemplate;
        this.kafkaTemplate = kafkaTemplate;
        registerGauges(registry);
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        if (!properties.dependencyWorkload().enabled()) {
            latestSnapshot = DependencySnapshot.disabled();
            return;
        }
        latestSnapshot = runWorkload("startup");
        postgresStartupMs.set(latestSnapshot.postgresMs());
        redisStartupMs.set(latestSnapshot.redisMs());
        kafkaStartupMs.set(latestSnapshot.kafkaMs());
        totalStartupMs.set(latestSnapshot.totalMs());

        System.out.println("{\"event\":\"dependency workload initialized\""
                + ",\"postgresMs\":" + latestSnapshot.postgresMs()
                + ",\"redisMs\":" + latestSnapshot.redisMs()
                + ",\"kafkaMs\":" + latestSnapshot.kafkaMs()
                + ",\"totalMs\":" + latestSnapshot.totalMs()
                + "}");
    }

    public DependencySnapshot runRequestWorkload() {
        if (!properties.dependencyWorkload().enabled()) {
            return DependencySnapshot.disabled();
        }
        latestSnapshot = runWorkload("request");
        return latestSnapshot;
    }

    public DependencySnapshot latestSnapshot() {
        return latestSnapshot;
    }

    private DependencySnapshot runWorkload(String source) {
        long totalStarted = System.nanoTime();
        String id = UUID.randomUUID().toString();
        long postgresMs = timeMillis(() -> touchPostgres(id, source));
        long redisMs = timeMillis(() -> touchRedis(id, source));
        long kafkaMs = timeMillis(() -> touchKafka(id, source));
        long totalMs = elapsedMillis(totalStarted);
        return new DependencySnapshot(true, source, postgresMs, redisMs, kafkaMs, totalMs, Instant.now().toString());
    }

    private void touchPostgres(String id, String source) {
        jdbcTemplate.execute("""
                create table if not exists dependency_events (
                    id varchar(64) primary key,
                    source varchar(32) not null,
                    mode varchar(32) not null,
                    created_at timestamptz not null default now()
                )
                """);
        jdbcTemplate.update("""
                insert into dependency_events (id, source, mode)
                values (?, ?, ?)
                on conflict (id) do nothing
                """, id, source, properties.runtimeMode());
        jdbcTemplate.queryForObject("select count(*) from dependency_events", Long.class);
    }

    private void touchRedis(String id, String source) {
        String key = "startup-demo:" + properties.runtimeMode() + ":" + source;
        redisTemplate.opsForValue().set(key, id, Duration.ofMinutes(10));
        redisTemplate.opsForValue().get(key);
    }

    private void touchKafka(String id, String source) {
        try {
            String payload = "{\"id\":\"" + id + "\",\"source\":\"" + source
                    + "\",\"mode\":\"" + properties.runtimeMode() + "\"}";
            kafkaTemplate.send(properties.dependencyWorkload().kafkaTopic(), properties.runtimeMode(), payload)
                    .get(properties.dependencyWorkload().timeoutMs(), TimeUnit.MILLISECONDS);
            kafkaTemplate.flush();
        } catch (Exception ex) {
            throw new IllegalStateException("Kafka dependency workload failed", ex);
        }
    }

    private long timeMillis(Runnable runnable) {
        long started = System.nanoTime();
        runnable.run();
        return elapsedMillis(started);
    }

    private long elapsedMillis(long started) {
        return (System.nanoTime() - started) / 1_000_000L;
    }

    private void registerGauges(MeterRegistry registry) {
        Gauge.builder("app.dependency.postgres.startup.ms", postgresStartupMs, AtomicLong::get)
                .description("Postgres startup dependency workload time.")
                .register(registry);
        Gauge.builder("app.dependency.redis.startup.ms", redisStartupMs, AtomicLong::get)
                .description("Redis startup dependency workload time.")
                .register(registry);
        Gauge.builder("app.dependency.kafka.startup.ms", kafkaStartupMs, AtomicLong::get)
                .description("Kafka startup dependency workload time.")
                .register(registry);
        Gauge.builder("app.dependency.total.startup.ms", totalStartupMs, AtomicLong::get)
                .description("Total startup dependency workload time.")
                .register(registry);
    }

    public record DependencySnapshot(boolean enabled, String source, long postgresMs, long redisMs,
                                     long kafkaMs, long totalMs, String observedAt) {
        static DependencySnapshot disabled() {
            return new DependencySnapshot(false, "disabled", -1, -1, -1, -1, "");
        }

        public Map<String, Object> asMap() {
            Map<String, Object> values = new LinkedHashMap<>();
            values.put("enabled", enabled);
            values.put("source", source);
            values.put("postgresMs", postgresMs);
            values.put("redisMs", redisMs);
            values.put("kafkaMs", kafkaMs);
            values.put("totalMs", totalMs);
            values.put("observedAt", observedAt);
            return values;
        }
    }
}
