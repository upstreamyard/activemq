<img src="https://upstreamyard.github.io/helm-charts/logo.png" alt="upstreamyard logo" width="120" align="right">

# ActiveMQ Docker image (Apache ActiveMQ Classic 5.19, 6.2, 6.3)

Production-ready, multi-arch (`amd64`, `arm64`) and signed **Apache ActiveMQ Docker image** for every supported ActiveMQ Classic release line: **5.19** (`javax.jms`), **6.2** and **6.3** (`jakarta.jms`). It is **secure by default**: no anonymous clients, no `admin/admin`, and it runs as non-root. **High availability** works without shared storage (JDBC master/slave on PostgreSQL, driver included), and **Prometheus metrics** are built in. The web console works out of the box in Docker and Kubernetes. Use it with Docker, Docker Compose, or Kubernetes via our **[ActiveMQ Helm chart](https://github.com/upstreamyard/helm-charts/tree/main/charts/activemq)**. It is also a drop-in alternative to the discontinued Bitnami ActiveMQ image and to the outdated `apache/activemq-classic` image.

> Community-maintained by **upstreamyard**. This is not an official Apache ActiveMQ image. Apache ActiveMQ is licensed under Apache-2.0 (see [Licences](#licences)). Apache, Apache ActiveMQ and ActiveMQ are trademarks of the Apache Software Foundation.

| Registry | Image |
|---|---|
| Docker Hub | `upstreamyard/activemq` |
| GitHub Container Registry | `ghcr.io/upstreamyard/activemq` |

| Tag | Follows | Java |
|---|---|---|
| `6.3.2`, `6.3`, `6`, `latest` | ActiveMQ 6.3.x, the newest release line | Eclipse Temurin 25 |
| `6.2.10`, `6.2` | ActiveMQ 6.2.x | Eclipse Temurin 17 |
| `5.19.11`, `5.19`, `5` | ActiveMQ 5.19.x, the last `javax.jms` line | Eclipse Temurin 17 |

New ActiveMQ releases are built within 24 hours of appearing on Apache's download server, for every release line Apache still supports. Pin a release line (`6.3`, `5.19`) to get patch updates automatically.

## Why this ActiveMQ image

Compared with the official `apache/activemq-classic` image. We tested its newest tag, `6.2.0`, in October 2026.

| | `apache/activemq-classic:6.2.0` | `upstreamyard/activemq` |
|---|---|---|
| Newest ActiveMQ | 6.2.0 (last pushed 2026-02-13) | 6.3.2, 6.2.10, 5.19.11; rebuilt for every release |
| Clients without a password | accepted | refused; `ACTIVEMQ_ADMIN_PASSWORD` is required |
| Web console login | `admin` / `admin` | your admin user only; the app user gets no console access |
| Runs as | root | non-root UID `10001`; read-only root filesystem supported |
| `docker stop` | broker killed after the 10 s timeout | clean broker shutdown in under a second |
| Healthcheck | none | built in (TCP on the first transport) |
| Heap | fixed `-Xmx1G` | 60% of the container's memory limit |
| HA without shared storage | needs your own JDBC driver and config | `ACTIVEMQ_PERSISTENCE=jdbc`, PostgreSQL driver included |
| Prometheus metrics | none | `ACTIVEMQ_METRICS_ENABLED=true`, port 9404 |
| Signed, SBOM, provenance | no | cosign, SBOM, SLSA provenance |
| Helm chart | none | [upstreamyard/activemq](https://github.com/upstreamyard/helm-charts/tree/main/charts/activemq) |

## At a glance

| | |
|---|---|
| Ports | `61616` OpenWire (JMS), `5672` AMQP, `61613` STOMP, `1883` MQTT, `61614` WebSocket, `8161` web console and Jolokia (JMX over HTTP), `9404` Prometheus metrics. Only OpenWire is on by default; see `ACTIVEMQ_TRANSPORTS` |
| Probes | `healthcheck`: TCP on the first transport (61616 by default). `broker-state`: prints `active`, `standby` or `starting`, and succeeds for active and standby. A master/slave standby doesn't listen until it takes over |
| Requires | nothing for a single broker. JDBC high availability needs PostgreSQL (tested: PostgreSQL 18) |
| Storage | `/var/lib/activemq` (KahaDB). Mount a volume there |
| Config | environment variables (below); your own files in `/etc/activemq` replace the defaults |
| Runs as | UID/GID `10001`. With a read-only root filesystem, `/tmp` must be writable |
| Default users | **none**: the container refuses to start without `ACTIVEMQ_ADMIN_PASSWORD` |
| Shutdown | `SIGTERM` stops the broker cleanly (exit code 143) |

**AI agents and coding assistants:** read [`AGENTS.md`](https://github.com/upstreamyard/activemq/blob/main/AGENTS.md) for deployment rules, and [`llms.txt`](https://github.com/upstreamyard/activemq/blob/main/llms.txt) for an index of all docs.

## Quick start: run ActiveMQ in Docker

```bash
docker run -d --name activemq \
  -p 61616:61616 -p 8161:8161 \
  -e ACTIVEMQ_ADMIN_PASSWORD=change-me \
  -e ACTIVEMQ_APP_USER=app -e ACTIVEMQ_APP_PASSWORD=change-me-too \
  -v activemq-data:/var/lib/activemq \
  upstreamyard/activemq:6.3
```

- Web console: http://localhost:8161/admin, log in as `admin` / `change-me`.
- JMS clients: `tcp://localhost:61616` as `app` / `change-me-too`.
- Send and receive test messages with ActiveMQ's own command line tools:

```bash
docker exec activemq activemq producer --user app --password change-me-too --destination queue://test --messageCount 10
docker exec activemq activemq consumer --user app --password change-me-too --destination queue://test --messageCount 10
```

With Docker Compose: [`docker-compose.yml`](https://github.com/upstreamyard/activemq/blob/main/docker-compose.yml) starts a broker with OpenWire, AMQP, STOMP and metrics.

## Configuration

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `ACTIVEMQ_ADMIN_PASSWORD` | – (**required**) | Password of the admin user: all broker rights and the web console |
| `ACTIVEMQ_ADMIN_USER` | `admin` | Name of the admin user (group `admins`) |
| `ACTIVEMQ_APP_USER` | – | Optional application user (group `users`): may send to, receive from and create any queue or topic; no web console |
| `ACTIVEMQ_APP_PASSWORD` | – | Password of the application user |
| `ACTIVEMQ_TRANSPORTS` | `openwire` | Comma-separated: `openwire`, `amqp`, `stomp`, `mqtt`, `ws` |
| `ACTIVEMQ_PERSISTENCE` | `kahadb` | `kahadb` (files in `/var/lib/activemq`) or `jdbc` (database, see [High availability](#high-availability)) |
| `ACTIVEMQ_JDBC_URL` | – | e.g. `jdbc:postgresql://postgres:5432/activemq` |
| `ACTIVEMQ_JDBC_USER`, `ACTIVEMQ_JDBC_PASSWORD` | – | Database login. The user needs to create tables on the first start |
| `ACTIVEMQ_JDBC_DRIVER` | `org.postgresql.Driver` | JDBC driver class. Other databases need their driver in a derived image (see [Extending](#extending-the-image)) |
| `ACTIVEMQ_BROKER_NAME` | `localhost` | Broker name (JMX, metrics label, networks of brokers) |
| `ACTIVEMQ_SCHEDULER_ENABLED` | `false` | Scheduled and delayed messages (`AMQ_SCHEDULED_DELAY`, …) |
| `ACTIVEMQ_STORE_LIMIT`, `ACTIVEMQ_TEMP_LIMIT` | `100 gb`, `50 gb` | Disk limits. ActiveMQ lowers them to the free space of the volume and logs a warning |
| `ACTIVEMQ_WEB_CONSOLE` | `true` | `false` turns off the web console and Jolokia (port 8161) |
| `ACTIVEMQ_METRICS_ENABLED` | `false` | Prometheus metrics on `:9404/metrics` |
| `ACTIVEMQ_METRICS_PORT` | `9404` | Metrics port |
| `ACTIVEMQ_METRICS_CONFIG` | `/opt/jmx-exporter/activemq.yml` | JMX exporter rules file |
| `ACTIVEMQ_OPTS_MEMORY` | `-XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=60.0` | Heap options. ActiveMQ uses up to 70% of the heap for messages in memory |
| `ACTIVEMQ_OPTS` | – | Extra Java options, added after ours |
| `ACTIVEMQ_HEALTHCHECK_PORT` | first transport | Port the healthcheck probes |

Every password variable also has a `_FILE` variant (`ACTIVEMQ_ADMIN_PASSWORD_FILE`, `ACTIVEMQ_APP_PASSWORD_FILE`, `ACTIVEMQ_JDBC_PASSWORD_FILE`) that reads the value from a file, e.g. a mounted Kubernetes Secret. Passwords must be printable ASCII; with ActiveMQ 5.19 they also must not contain a comma.

### Users, groups and permissions

- **Group `admins`** (the admin user) may do everything: all queues and topics, advisory topics, the web console and Jolokia.
- **Group `users`** (the app user) may send to, receive from and create any queue or topic, and use temporary queues (request/reply). It can't use the web console or Jolokia. Because ActiveMQ combines all matching permission entries, it can also read the `ActiveMQ.Advisory.*` topics. Those show user names and client addresses, never passwords.

For more users, LDAP, per-queue permissions or locking down advisory topics, mount your own `users.properties` and `groups.properties`, or your own `activemq.xml` and `login.config`, in `/etc/activemq`. ActiveMQ's [security guide](https://activemq.apache.org/components/classic/documentation/security) describes the options.

### Your own configuration files

Every file you mount in `/etc/activemq` replaces the default file of the same name, e.g. `activemq.xml`, `log4j2.properties`, `users.properties` or `jetty.xml`. A ConfigMap or Secret mounted as a folder works too. At start the container copies the defaults plus your files to `/tmp/activemq/conf`, the folder ActiveMQ reads.

```bash
docker run -d -v "$PWD/activemq.xml:/etc/activemq/activemq.xml:ro" -e ACTIVEMQ_ADMIN_PASSWORD=change-me upstreamyard/activemq:6.3
```

With your own `activemq.xml`, the variables that build it (`ACTIVEMQ_TRANSPORTS`, `ACTIVEMQ_PERSISTENCE`, `ACTIVEMQ_BROKER_NAME`, …) are ignored and the container says so in its log. Keep `<jaasAuthenticationPlugin configuration="activemq"/>` in it if you want the generated users. Start from our [default `activemq.xml`](https://github.com/upstreamyard/activemq/blob/main/conf/activemq.xml) and see ActiveMQ's [configuration reference](https://activemq.apache.org/components/classic/documentation/xml-reference).

### Logging

Logs go to the console only, not to files in the data volume. To change levels, mount your own `log4j2.properties`, starting from [ours](https://github.com/upstreamyard/activemq/blob/main/conf/log4j2.properties).

### Prometheus metrics

With `ACTIVEMQ_METRICS_ENABLED=true`, the [Prometheus JMX exporter](https://github.com/prometheus/jmx_exporter) serves `:9404/metrics`:

- `activemq_broker_*{broker}`: connections, enqueue/dequeue totals, memory, store and temp usage, `activemq_broker_slave`;
- `activemq_destination_*{broker,destination,destination_type}`: queue size, enqueue/dequeue/dispatch/expired counts, consumers, producers, blocked sends, enqueue times. Advisory topics are left out;
- `jvm_*`: heap, GC, threads.

Rules: [`conf/jmx-exporter.yml`](https://github.com/upstreamyard/activemq/blob/main/conf/jmx-exporter.yml). Your own rules: mount a file and set `ACTIVEMQ_METRICS_CONFIG` to its path.

## High availability

ActiveMQ Classic runs one active broker; a standby broker waits for a lock and takes over when the active one stops. Clients connect with a failover URL, e.g. `failover:(tcp://broker-1:61616,tcp://broker-2:61616)`, and reconnect by themselves.

| | JDBC master/slave | Shared storage master/slave |
|---|---|---|
| Set up | `ACTIVEMQ_PERSISTENCE=jdbc` + `ACTIVEMQ_JDBC_*`, same database for all brokers | same volume (`/var/lib/activemq`) for all brokers |
| Needs | PostgreSQL | a shared filesystem with working file locks (e.g. NFSv4); `ReadWriteMany` in Kubernetes |
| Takeover (tested) | 17–22 s after the active broker died | 12 s |
| Speed | slower than KahaDB | KahaDB speed |

Tested in both modes: messages sent before the active broker was killed were all received from the standby.

**JDBC notes:**
- Every broker needs a unique hostname; the container uses it as the lease holder ID. In Kubernetes, pod names are unique.
- The first broker creates the tables `ACTIVEMQ_MSGS`, `ACTIVEMQ_ACKS` and `ACTIVEMQ_LOCK`. Every later start logs `Could not create JDBC tables; they could already exist`. That's ActiveMQ's normal behaviour and harmless.
- Scheduled messages (`ACTIVEMQ_SCHEDULER_ENABLED=true`) stay in a local store in `/var/lib/activemq`, even with JDBC. They are **not** handed over to the standby.

Example: [`examples/jdbc-ha/docker-compose.yml`](https://github.com/upstreamyard/activemq/blob/main/examples/jdbc-ha/docker-compose.yml), two brokers and PostgreSQL.

## Kubernetes and Helm: ActiveMQ Helm chart

The recommended way to run ActiveMQ on Kubernetes is our Helm chart ([`upstreamyard/helm-charts`](https://github.com/upstreamyard/helm-charts/tree/main/charts/activemq)), with a single broker or JDBC high availability, a ServiceMonitor and Secrets for all passwords:

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install activemq upstreamyard/activemq --set auth.adminPassword=change-me
```

Running the image yourself:

1. Pass passwords from a Secret (`ACTIVEMQ_ADMIN_PASSWORD_FILE` or `env.valueFrom.secretKeyRef`).
2. Use a StatefulSet with a volume at `/var/lib/activemq`, or `ACTIVEMQ_PERSISTENCE=jdbc` for HA without shared storage.
3. Probes: with a single broker, TCP on 61616. With master/slave, use `exec: [broker-state]` for startup, liveness and readiness: a standby never opens the broker port, so a TCP probe keeps it unready and blocks StatefulSet rolling updates. Clients then connect with a failover URL listing all brokers.
4. Set a memory limit; the heap is 60% of it.
5. Allow at least 30 seconds of `terminationGracePeriodSeconds`.

The container works with `runAsNonRoot: true`, `readOnlyRootFilesystem: true` (plus an `emptyDir` at `/tmp`) and all capabilities dropped.

## Migrating to this image

**From the official `apache/activemq-classic` image:**
- `ACTIVEMQ_WEB_USER`/`ACTIVEMQ_WEB_PASSWORD` become `ACTIVEMQ_ADMIN_USER`/`ACTIVEMQ_ADMIN_PASSWORD`.
- `ACTIVEMQ_CONNECTION_USER`/`ACTIVEMQ_CONNECTION_PASSWORD` become `ACTIVEMQ_APP_USER`/`ACTIVEMQ_APP_PASSWORD`.
- The data folder moves from `/opt/apache-activemq/data` to `/var/lib/activemq`.

**From the Bitnami ActiveMQ image:**
- `ACTIVEMQ_PASSWORD` becomes `ACTIVEMQ_ADMIN_PASSWORD`.
- The volume moves from `/bitnami/activemq` to `/var/lib/activemq`.
- Custom files move from `ACTIVEMQ_MOUNTED_CONF_DIR` to `/etc/activemq`.

**Existing data volumes:** the files must belong to UID `10001`. We haven't tested reusing a data volume from another image; drain the queues before switching if you can.

## Extending the image

Other JDBC drivers (MySQL, Oracle, SQL Server) or plugins go into `/opt/activemq/lib/optional`:

```dockerfile
FROM upstreamyard/activemq:6.3
ADD --chmod=644 https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/26.7.0/mysql-connector-j-26.7.0.jar /opt/activemq/lib/optional/
```

## FAQ

**How do I run ActiveMQ in Docker?** Use the [quick start](#quick-start-run-activemq-in-docker) command above; `ACTIVEMQ_ADMIN_PASSWORD` is the only required setting.

**Is there a Helm chart for ActiveMQ?** Yes: [`upstreamyard/activemq`](https://github.com/upstreamyard/helm-charts/tree/main/charts/activemq), for ActiveMQ Classic 5.19, 6.2 and 6.3, with HA and metrics.

**What replaces the Bitnami ActiveMQ image?** This image, and our Helm chart for Kubernetes. See [Migrating](#migrating-to-this-image).

**Why can't I reach the ActiveMQ web console in Docker?** ActiveMQ binds the console to `127.0.0.1` and only lets `127.0.0.1` in, so it's unreachable from outside a container. This image binds it to all interfaces and lets all addresses in; a login is still required.

**ActiveMQ Classic or Artemis?** This image is ActiveMQ **Classic** (the `activemq` 5.x/6.x broker). ActiveMQ Artemis is a different broker with its own images.

**Which version should I use?** 6.3 for new projects. 5.19 if your clients use `javax.jms` (Java EE 8, Spring Boot 2) and can't move to `jakarta.jms` yet.

**How do I set up ActiveMQ high availability on Kubernetes?** JDBC master/slave with PostgreSQL needs no shared storage; see [High availability](#high-availability) and the Helm chart.

**How do I monitor ActiveMQ with Prometheus?** Set `ACTIVEMQ_METRICS_ENABLED=true` and scrape port 9404; see [Prometheus metrics](#prometheus-metrics).

**Why does the container exit with `ACTIVEMQ_ADMIN_PASSWORD is not set`?** On purpose: an ActiveMQ broker without a password lets anyone read and send messages.

## Verifying images

Images are signed keylessly with [cosign](https://github.com/sigstore/cosign) and include an SBOM and SLSA provenance:

```bash
cosign verify upstreamyard/activemq:6.3 \
  --certificate-identity-regexp '^https://github.com/upstreamyard/activemq/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect upstreamyard/activemq:6.3 --format '{{ json .SBOM }}'
```

## How it's built

[`.github/workflows/build.yml`](https://github.com/upstreamyard/activemq/blob/main/.github/workflows/build.yml) finds every release Apache currently lists on its download server (one per supported release line). For each one, [`scripts/fetch-release.sh`](https://github.com/upstreamyard/activemq/blob/main/scripts/fetch-release.sh) downloads the official binary release and checks its SHA-512 and its GPG signature against the ActiveMQ KEYS file. CI then builds the [`Dockerfile`](https://github.com/upstreamyard/activemq/blob/main/Dockerfile) for amd64 and arm64.

- **Java:** the same Eclipse Temurin JRE version as Apache's own image for that release, but at least 17. Base: Ubuntu 24.04.
- **Added:** PostgreSQL JDBC driver 42.7.14 (Maven Central) and Prometheus JMX exporter 1.7.0 (GitHub release), both pinned by SHA-256.
- **Removed:** the Tanuki service wrapper, demos, examples, offline docs and the all-in-one client jar.
- **Changed:**
  - our `activemq.xml`, based on ActiveMQ's, with authentication and authorization always on;
  - console-only logging;
  - the web console listens on all interfaces.
- **Testing:** before publishing, [`scripts/smoke-test.sh`](https://github.com/upstreamyard/activemq/blob/main/scripts/smoke-test.sh) checks each release line:
  - sending and receiving as the app user;
  - refused anonymous and wrong-password logins;
  - web console roles;
  - all five transports, STOMP login and metrics;
  - clean shutdown;
  - a JDBC failover on PostgreSQL without message loss.

## Licences

| Component | Licence | Licence text in the image | Source code |
|---|---|---|---|
| Apache ActiveMQ | Apache-2.0 | `/licenses/activemq/` (LICENSE and NOTICE, covering its bundled libraries) | [apache/activemq](https://github.com/apache/activemq) at tag `activemq-<version>` |
| PostgreSQL JDBC driver | BSD-2-Clause | `/licenses/postgresql-jdbc/` | [pgjdbc/pgjdbc](https://github.com/pgjdbc/pgjdbc) |
| Prometheus JMX exporter | Apache-2.0 | `/licenses/jmx-exporter/` | [prometheus/jmx_exporter](https://github.com/prometheus/jmx_exporter) |
| Ubuntu packages, Eclipse Temurin | various, incl. GPL | `/usr/share/doc/*/copyright`, `/opt/java/openjdk/legal/` | Ubuntu and Adoptium source archives |
| Our packaging (Dockerfile, scripts, config) | Apache-2.0 | – | this repository |

## Support

Issues with the image: [open an issue here](https://github.com/upstreamyard/activemq/issues). Questions about using ActiveMQ: [ActiveMQ's mailing lists](https://activemq.apache.org/contact).
