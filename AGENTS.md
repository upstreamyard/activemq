# AGENTS.md

Instructions for AI agents and coding assistants working with this repository or deploying the image it publishes: a Docker image of Apache ActiveMQ Classic (not Artemis).

## Image facts

| Key | Value |
|---|---|
| Image | `upstreamyard/activemq` (Docker Hub), `ghcr.io/upstreamyard/activemq` |
| Tags | `<version>` (e.g. `6.3.2`), `<major>.<minor>` (`6.3`, `6.2`, `5.19`), `<major>` (`6`, `5`), `latest` (= newest 6.x) |
| Release lines | 6.3 (Java 25), 6.2 (Java 17), 5.19 (Java 17; `javax.jms` clients). 6.x uses `jakarta.jms` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Ports | `61616` OpenWire, `5672` AMQP, `61613` STOMP, `1883` MQTT, `61614` WebSocket, `8161` web console and Jolokia, `9404` Prometheus metrics |
| Default transports | OpenWire only; enable others with `ACTIVEMQ_TRANSPORTS=openwire,amqp,stomp,mqtt,ws` |
| Probes | `healthcheck`: TCP on the first transport (built-in `HEALTHCHECK`). `broker-state`: `active` / `standby` (exit 0) or `starting` (exit 1), for master/slave probes |
| User | non-root, UID/GID `10001`; read-only root filesystem works with a writable `/tmp` |
| Data | `/var/lib/activemq` (KahaDB) |
| Config | env vars `ACTIVEMQ_*`; files mounted in `/etc/activemq` replace defaults of the same name; effective config is rendered to `/tmp/activemq/conf` |
| Required | `ACTIVEMQ_ADMIN_PASSWORD` (or `_FILE`), unless `users.properties` is mounted |
| Included extras | PostgreSQL JDBC driver (`lib/optional`), Prometheus JMX exporter (`/opt/jmx-exporter`) |
| ActiveMQ project | https://github.com/apache/activemq (Apache-2.0) |

## Deploying the image

Rules that avoid the common failures:

- **Credentials:** the container exits if `ACTIVEMQ_ADMIN_PASSWORD` is missing. Give applications their own login with `ACTIVEMQ_APP_USER`/`ACTIVEMQ_APP_PASSWORD` (group `users`: all queues and topics, no web console or Jolokia). Use the `_FILE` variants for Kubernetes Secrets. Passwords must be printable ASCII; for 5.19 no commas.
- **Clients:** JMS clients must send a user name and password. Use `failover:(tcp://a:61616,tcp://b:61616)` URLs with more than one broker.
- **ActiveMQ CLI quirk:** `activemq producer|consumer` pastes arguments into `sh -c`, so a failover URL needs extra quotes: `--brokerUrl "'failover:(tcp://a:61616,tcp://b:61616)'"`.
- **Persistence:** mount a volume at `/var/lib/activemq` (KahaDB). For HA without shared storage, set `ACTIVEMQ_PERSISTENCE=jdbc` with `ACTIVEMQ_JDBC_URL/USER/PASSWORD` (PostgreSQL); every broker needs a unique hostname (lease holder ID).
- **HA behaviour:** only the active broker listens; a standby takes over 12–22 s after the active one dies (tested). In Kubernetes, probe with `exec: [broker-state]`, not TCP: a TCP probe keeps the standby unready forever and blocks StatefulSet rolling updates. Clients use a failover URL listing all brokers.
- **Scheduler:** `ACTIVEMQ_SCHEDULER_ENABLED=true` keeps scheduled messages in a local store even with JDBC; they don't fail over.
- **Own activemq.xml:** mount it at `/etc/activemq/activemq.xml`; then `ACTIVEMQ_TRANSPORTS`, `ACTIVEMQ_PERSISTENCE`, `ACTIVEMQ_BROKER_NAME`, `ACTIVEMQ_SCHEDULER_ENABLED`, the store limits and `ACTIVEMQ_WEB_CONSOLE` are ignored. Keep `<jaasAuthenticationPlugin configuration="activemq"/>` and `id="broker"` on `<broker>` (the 5.19/6.2 `jetty.xml` depends on it).
- **Memory:** set a memory limit; the heap is 60% of it (`ACTIVEMQ_OPTS_MEMORY`). `ACTIVEMQ_OPTS` is appended to our Java options, not a replacement.
- **Shutdown:** `SIGTERM` stops the broker cleanly; allow 30 s or more of grace period.
- **Other JDBC drivers:** build `FROM upstreamyard/activemq` and add the jar to `/opt/activemq/lib/optional`.

Ready-to-use manifests:

- Docker Compose, single broker: [`docker-compose.yml`](docker-compose.yml)
- Docker Compose, JDBC master/slave with PostgreSQL: [`examples/jdbc-ha/docker-compose.yml`](examples/jdbc-ha/docker-compose.yml)
- Kubernetes: Helm chart `upstreamyard/activemq` from `https://upstreamyard.github.io/helm-charts` (also `oci://ghcr.io/upstreamyard/charts/activemq`), documented in https://github.com/upstreamyard/helm-charts/tree/main/charts/activemq

Verify a deployment:

```bash
docker exec <container> activemq producer --user app --password <pw> --destination queue://check --messageCount 1
docker exec <container> activemq consumer --user app --password <pw> --destination queue://check --messageCount 1
```

## Working on this repository

Layout:

- `Dockerfile`: packages the official binary release, which `scripts/fetch-release.sh` downloads, verifies (SHA-512 and GPG) and unpacks into `./upstream/` (git-ignored); adds the PostgreSQL driver and the JMX exporter, pinned by version and SHA-256
- `scripts/prepare-dist.sh`: build-time changes to the release (slimming, our config defaults, web console binding, licences). It fails the build if the Jetty patch stops matching
- `conf/`: our `activemq.xml` template (`@PLACEHOLDERS@` filled by the entrypoint), `log4j2.properties`, `jmx-exporter.yml`
- `docker-entrypoint.sh`: assembles `/tmp/activemq/conf`, generates users and `activemq.xml` from env vars, starts the broker and forwards `SIGTERM` to the JVM
- `healthcheck`: TCP check on the port chosen by the entrypoint; `broker-state`: active/standby/starting, based on that port and the standby log lines the entrypoint watches for
- `scripts/smoke-test.sh`: the test CI runs for every release line before publishing; run it locally too
- `.github/workflows/build.yml`: builds every release line listed on Apache's download server (matrix), smoke-tests, pushes multi-arch, signs and syncs the Docker Hub README

Build and test locally:

```bash
scripts/fetch-release.sh 6.3.2
docker build -t activemq:dev --build-arg ACTIVEMQ_VERSION=6.3.2 --build-arg JAVA_VERSION=25 .
scripts/smoke-test.sh activemq:dev
```

Use `JAVA_VERSION=17` for 5.19 and 6.2.

Rules:

- Never push to `main`. Create a branch and open a pull request into `main`.
- Do not modify ActiveMQ's files beyond what `prepare-dist.sh` does now; report ActiveMQ bugs to the user rather than filing them.
- **Extras:** to update the PostgreSQL driver or the JMX exporter, change the version and SHA-256 `ARG`s in the `Dockerfile` and the versions in `README.md` (How it's built). Dependabot does not track them.
- Changes must work for all release lines (5.19, 6.2, 6.3): their Jetty configs differ (`conf/jetty.xml` vs `conf/jetty/*.xml`, `jetty-realm.properties` in 5.19). Run the smoke test against each.
- Keep the image non-root with UID `10001`, and keep `HEALTHCHECK` and the OCI labels.
- When ports, env vars or the config layout change, update `README.md`, this file and `llms.txt` in the same pull request.
- The workflow must pass `actionlint` (`docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest`).
- `README.md` is also the Docker Hub description, so keep it under 25,000 characters.
