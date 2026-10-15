# syntax=docker/dockerfile:1.7
# Container image for Apache ActiveMQ Classic (https://github.com/apache/activemq)
# Maintained by upstreamyard. Packages the official Apache binary release, unpacked into
# ./upstream by CI after checking its SHA-512 and GPG signature, plus the PostgreSQL JDBC
# driver (JDBC persistence and master/slave) and the Prometheus JMX exporter (metrics).

# CI passes the Java version Apache's own image uses for the release, but at least 17.
ARG JAVA_VERSION=25

# -----------------------------
# Prepare: release files, extras, config defaults
# -----------------------------
# Only handles platform-independent files (jars, scripts, XML), so it runs natively.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS prepare

# Prometheus JMX exporter (Apache-2.0), from its GitHub release.
ARG JMX_EXPORTER_VERSION=1.7.0
ARG JMX_EXPORTER_SHA256=0ad843261c567d1924a017d542e14c40f2afff523d940c25ee000742fde4b3a9
# PostgreSQL JDBC driver (BSD-2-Clause), from Maven Central.
ARG POSTGRESQL_JDBC_VERSION=42.7.14
ARG POSTGRESQL_JDBC_SHA256=73914527305a40cce504b0d3d90b23caf565136912d607ae8ae7c5895512332c

RUN apk add --no-cache unzip

COPY upstream/ /opt/activemq/
ADD --chmod=644 --checksum=sha256:${JMX_EXPORTER_SHA256} \
    https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
    /opt/jmx-exporter/jmx_prometheus_javaagent.jar
ADD --chmod=644 --checksum=sha256:${POSTGRESQL_JDBC_SHA256} \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRESQL_JDBC_VERSION}/postgresql-${POSTGRESQL_JDBC_VERSION}.jar \
    /opt/activemq/lib/optional/
COPY conf/ /tmp/conf/
COPY scripts/prepare-dist.sh /tmp/
RUN JMX_EXPORTER_VERSION=${JMX_EXPORTER_VERSION} POSTGRESQL_JDBC_VERSION=${POSTGRESQL_JDBC_VERSION} \
    sh /tmp/prepare-dist.sh

# -----------------------------
# Runtime
# -----------------------------
FROM eclipse-temurin:${JAVA_VERSION}-jre-noble AS final

ARG ACTIVEMQ_VERSION=unknown

RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 activemq \
    && useradd --system --uid 10001 --gid activemq --home-dir /var/lib/activemq --no-create-home activemq \
    && mkdir -p /var/lib/activemq /etc/activemq \
    && chown activemq:activemq /var/lib/activemq

COPY --from=prepare /licenses/ /licenses/
COPY --from=prepare /opt/ /opt/
COPY docker-entrypoint.sh healthcheck /usr/local/bin/

# The release stays read-only. The entrypoint renders the effective config to
# /tmp/activemq/conf; broker data (KahaDB) goes to /var/lib/activemq.
ENV ACTIVEMQ_HOME=/opt/activemq \
    ACTIVEMQ_BASE=/opt/activemq \
    ACTIVEMQ_DATA=/var/lib/activemq \
    PATH=$PATH:/opt/activemq/bin

WORKDIR /opt/activemq

LABEL org.opencontainers.image.title="activemq" \
      org.opencontainers.image.description="Apache ActiveMQ Classic message broker: secure by default, non-root, metrics and JDBC HA built in. Community image by upstreamyard, not an official Apache image." \
      org.opencontainers.image.version="${ACTIVEMQ_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0 AND BSD-2-Clause" \
      org.opencontainers.image.vendor="upstreamyard" \
      org.opencontainers.image.url="https://github.com/upstreamyard/activemq" \
      org.opencontainers.image.documentation="https://github.com/upstreamyard/activemq#readme"

# OpenWire, AMQP, STOMP, MQTT, WebSocket, web console, Prometheus metrics
EXPOSE 61616 5672 61613 1883 61614 8161 9404

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 CMD ["healthcheck"]

USER 10001:10001

ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
