ARG BASE_IMAGE=eclipse-temurin:25-jdk
FROM ${BASE_IMAGE}

WORKDIR /app
COPY target/java25-startup-optimization-demo-1.0.0.jar /app/app.jar
COPY target/lib /app/lib
COPY build/runtime-artifacts /app/build/runtime-artifacts

ENV APP_NAME=gateway-demo
ENV APP_JDK=25
ENV APP_RUNTIME_MODE=baseline
ENV SERVER_PORT=8080

EXPOSE 8080

ENTRYPOINT ["java"]
CMD ["-cp", "/app/app.jar:/app/lib/*", "com.example.startupdemo.app.StartupOptimizationApplication"]
