#!/bin/sh
# Runs in the Dockerfile's prepare stage (Alpine, POSIX sh). Slims the ActiveMQ release in
# /opt/activemq, installs our config defaults from /tmp/conf, makes the web console reachable
# from outside the container, and collects the licences in /licenses.
set -eux

cd /opt/activemq

# Licences: ActiveMQ's own (covering its bundled libraries) and the two extras we add.
mkdir -p /licenses/activemq /licenses/postgresql-jdbc /licenses/jmx-exporter
cp LICENSE NOTICE /licenses/activemq/
unzip -q -o lib/optional/postgresql-*.jar 'META-INF/LICENSE' 'META-INF/licenses/*' -d /tmp/pg
cp -r /tmp/pg/META-INF/. /licenses/postgresql-jdbc/
printf 'PostgreSQL JDBC driver %s\nSource code: https://github.com/pgjdbc/pgjdbc/tree/REL%s\n' \
  "$POSTGRESQL_JDBC_VERSION" "$POSTGRESQL_JDBC_VERSION" > /licenses/postgresql-jdbc/SOURCE
unzip -q -o /opt/jmx-exporter/jmx_prometheus_javaagent.jar 'META-INF/LICENSE*' 'META-INF/NOTICE*' -d /tmp/jmx || true
cp -r /tmp/jmx/META-INF/. /licenses/jmx-exporter/ 2>/dev/null || true
printf 'Prometheus JMX exporter %s (Apache-2.0)\nSource code: https://github.com/prometheus/jmx_exporter/tree/%s\n' \
  "$JMX_EXPORTER_VERSION" "$JMX_EXPORTER_VERSION" > /licenses/jmx-exporter/SOURCE

# Not needed in a container: the Tanuki service wrapper and native launchers, demos,
# examples, offline docs, the all-in-one client jar and the empty data folder.
rm -rf bin/linux-x86-32 bin/linux-x86-64 bin/macosx bin/wrapper.jar \
       examples webapps-demo docs activemq-all-*.jar data

# Our defaults: activemq.xml is a template the entrypoint renders; logs go to the console only.
cp /tmp/conf/activemq.xml /tmp/conf/log4j2.properties conf/
cp /tmp/conf/jmx-exporter.yml /opt/jmx-exporter/activemq.yml

# Web console: Apache binds it to 127.0.0.1 and only lets 127.0.0.1 and ::1 in. In a
# container that means nobody can reach it. Bind to all interfaces and let every client
# address through; login is still required, and the network decides who can connect.
# 5.19 and 6.2 configure Jetty in conf/jetty.xml, 6.3 and later in conf/jetty/*.xml.
for f in conf/jetty.xml conf/jetty/*.xml; do
  [ -f "$f" ] || continue
  sed -i \
    -e 's|<property name="host" value="127.0.0.1"/>|<property name="host" value="0.0.0.0"/>|' \
    -e 's|<value>127.0.0.1</value>|<value>0.0.0.0/0</value>|' \
    -e 's|<value>::1</value>|<value>::/0</value>|' \
    -e 's|<Item>127.0.0.1</Item>|<Item>0.0.0.0/0</Item>|' \
    -e 's|<Item>::1</Item>|<Item>::/0</Item>|' \
    "$f"
done
if [ -f conf/jetty-spring.properties ]; then
  printf '\n# upstreamyard: listen on all interfaces inside the container\njetty.http.host=0.0.0.0\n' \
    >> conf/jetty-spring.properties
fi
# Fail the build if Apache changes the Jetty layout and the patch above stops matching.
if grep -rqE '(value|Item)>(127\.0\.0\.1|::1)<|name="host" value="127\.0\.0\.1"' conf/jetty.xml conf/jetty 2>/dev/null; then
  echo "Web console is still restricted to localhost; update prepare-dist.sh" >&2
  exit 1
fi
grep -rqE '0\.0\.0\.0/0' conf/jetty.xml conf/jetty 2>/dev/null \
  || { echo "Web console IP allowlist not found; update prepare-dist.sh" >&2; exit 1; }

# Everything stays owned by root and read-only for the broker user.
chmod -R a+rX /opt/activemq /opt/jmx-exporter /licenses
