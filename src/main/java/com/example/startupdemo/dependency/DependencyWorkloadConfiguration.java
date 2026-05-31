package com.example.startupdemo.dependency;

import com.example.startupdemo.config.GatewayProperties;
import org.apache.kafka.clients.admin.NewTopic;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.TopicBuilder;

@Configuration
public class DependencyWorkloadConfiguration {
    @Bean
    NewTopic startupDemoEventsTopic(GatewayProperties properties) {
        return TopicBuilder.name(properties.dependencyWorkload().kafkaTopic())
                .partitions(1)
                .replicas(1)
                .build();
    }
}
