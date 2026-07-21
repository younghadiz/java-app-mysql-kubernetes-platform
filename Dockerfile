# syntax=docker/dockerfile:1.7

# -------------------------------------------------------------------
# Stage 1: Build and test the Spring Boot application
# -------------------------------------------------------------------
FROM gradle:8.10.2-jdk17 AS builder

WORKDIR /workspace

# Copy Gradle configuration files first so Docker can reuse the
# dependency-related layers when application source files change.
COPY build.gradle settings.gradle ./

# Copy the application source code.
COPY src ./src

# Build the executable Spring Boot JAR and run the automated tests.
RUN gradle clean test bootJar --no-daemon


# -------------------------------------------------------------------
# Stage 2: Create the lightweight runtime image
# -------------------------------------------------------------------
FROM eclipse-temurin:17-jre-resolute AS runtime

LABEL org.opencontainers.image.title="Java MySQL Kubernetes Application"
LABEL org.opencontainers.image.description="Spring Boot Java application deployed on Kubernetes"
LABEL org.opencontainers.image.source="https://github.com/younghadiz/java-app-mysql-kubernetes-platform"
LABEL org.opencontainers.image.licenses="MIT"

# Create a dedicated non-root Linux user and application directory.
RUN groupadd --system appgroup \
    && useradd \
        --system \
        --gid appgroup \
        --home-dir /opt/app \
        --shell /usr/sbin/nologin \
        appuser \
    && mkdir -p /opt/app \
    && chown -R appuser:appgroup /opt/app

WORKDIR /opt/app

# Copy only the compiled JAR from the builder stage.
COPY --from=builder \
    --chown=appuser:appgroup \
    /workspace/build/libs/*.jar \
    /opt/app/application.jar

# Run the application as an unprivileged user.
USER appuser

EXPOSE 8080

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"

ENTRYPOINT ["sh", "-c", "exec java ${JAVA_OPTS} -jar /opt/app/application.jar"]