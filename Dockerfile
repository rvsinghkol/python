# ---------- Stage 1: build the WAR ----------
FROM maven:3.9-eclipse-temurin-11 AS build
WORKDIR /app

# Download dependencies first (cached unless pom.xml changes)
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B clean package -DskipTests

# ---------- Stage 2: run on Tomcat ----------
FROM tomcat:9-jdk11

# Use up to 75% of the container's memory for the JVM heap
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0"

# Remove default apps and run as a non-root user
RUN rm -rf /usr/local/tomcat/webapps/* \
 && groupadd -r app \
 && useradd -r -g app -d /usr/local/tomcat -s /usr/sbin/nologin app \
 && chown -R app:app /usr/local/tomcat

COPY --from=build --chown=app:app /app/target/*.war /usr/local/tomcat/webapps/ROOT.war

USER app
EXPOSE 8080
CMD ["catalina.sh", "run"]
