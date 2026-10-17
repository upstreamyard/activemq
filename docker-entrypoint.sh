#!/bin/bash
# Starts Apache ActiveMQ Classic in the foreground.
#   (no arguments)  render the configuration to /tmp/activemq/conf and run the broker
#   anything else   run that command instead (e.g. bash, or: activemq producer ...)
#
# Configuration = the defaults in /opt/activemq/conf, then every file mounted in
# /etc/activemq on top (same names replace the defaults), then the files generated from
# ACTIVEMQ_* environment variables for whatever was not mounted. See README.md.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # "&" in ${var//x/y} stays literal

if [ $# -gt 0 ]; then
  exec "$@"
fi

DEFAULT_CONF=$ACTIVEMQ_HOME/conf
OVERRIDE_DIR=/etc/activemq
RUNTIME=/tmp/activemq
export ACTIVEMQ_CONF=$RUNTIME/conf
export ACTIVEMQ_TMP=$RUNTIME/tmp
# Outside the data volume: a PID file left over from the last run would make the start
# script believe the broker is already running.
export ACTIVEMQ_PIDFILE=$RUNTIME/activemq.pid

die() { echo "ERROR: $*" >&2; exit 1; }

# VAR_FILE=/path reads the value of VAR from a file (e.g. a mounted Kubernetes Secret).
for var in ACTIVEMQ_ADMIN_PASSWORD ACTIVEMQ_APP_PASSWORD ACTIVEMQ_JDBC_PASSWORD; do
  file_var="${var}_FILE"
  if [ -n "${!file_var:-}" ]; then
    [ -z "${!var:-}" ] || die "set either $var or $file_var, not both"
    [ -r "${!file_var}" ] || die "$file_var: cannot read ${!file_var}"
    printf -v "$var" '%s' "$(cat "${!file_var}")"
  fi
done

# ---------- Assemble the config folder ----------
umask 077
rm -rf "$RUNTIME"
mkdir -p "$ACTIVEMQ_CONF" "$ACTIVEMQ_TMP"
cp -r "$DEFAULT_CONF/." "$ACTIVEMQ_CONF/"
chmod -R u+w "$ACTIVEMQ_CONF"

mounted() { [ -e "$OVERRIDE_DIR/$1" ]; }
if [ -d "$OVERRIDE_DIR" ]; then
  # -L follows the symlinks of ConfigMap and Secret volumes; their ..data folders are skipped.
  while IFS= read -r -d '' entry; do
    cp -rL "$entry" "$ACTIVEMQ_CONF/"
    echo "Config: using mounted $OVERRIDE_DIR/$(basename "$entry")"
  done < <(find "$OVERRIDE_DIR" -mindepth 1 -maxdepth 1 ! -name '..*' -print0)
fi

# ---------- Users ----------
# Java properties values: escape backslashes and a leading space.
prop_value() { local v=${1//\\/\\\\}; [[ $v == " "* ]] && v="\\$v"; printf '%s' "$v"; }
check_user() { [[ $1 =~ ^[A-Za-z0-9._@-]+$ ]] || die "$2 may only contain letters, digits and . _ @ - (got '$1')"; }
check_password() { LC_ALL=C; [[ $1 =~ ^[[:print:]]+$ ]] || die "$2 must be printable ASCII"; }

ADMIN_USER=${ACTIVEMQ_ADMIN_USER:-admin}
APP_USER=${ACTIVEMQ_APP_USER:-}
if mounted users.properties; then
  echo "Users: from mounted users.properties and groups.properties"
else
  [ -n "${ACTIVEMQ_ADMIN_PASSWORD:-}" ] || die "ACTIVEMQ_ADMIN_PASSWORD is not set. The broker requires a login; set it (or ACTIVEMQ_ADMIN_PASSWORD_FILE), or mount your own users.properties and groups.properties in $OVERRIDE_DIR."
  check_user "$ADMIN_USER" ACTIVEMQ_ADMIN_USER
  check_password "$ACTIVEMQ_ADMIN_PASSWORD" ACTIVEMQ_ADMIN_PASSWORD
  {
    printf '%s=%s\n' "$ADMIN_USER" "$(prop_value "$ACTIVEMQ_ADMIN_PASSWORD")"
    if [ -n "$APP_USER" ]; then
      [ -n "${ACTIVEMQ_APP_PASSWORD:-}" ] || die "ACTIVEMQ_APP_USER is set but ACTIVEMQ_APP_PASSWORD is not"
      check_user "$APP_USER" ACTIVEMQ_APP_USER
      [ "$APP_USER" != "$ADMIN_USER" ] || die "ACTIVEMQ_APP_USER must differ from ACTIVEMQ_ADMIN_USER"
      check_password "$ACTIVEMQ_APP_PASSWORD" ACTIVEMQ_APP_PASSWORD
      printf '%s=%s\n' "$APP_USER" "$(prop_value "$ACTIVEMQ_APP_PASSWORD")"
    fi
  } > "$ACTIVEMQ_CONF/users.properties"
  mounted groups.properties || {
    printf 'admins=%s\n' "$ADMIN_USER"
    printf 'users=%s\n' "$APP_USER"
  } > "$ACTIVEMQ_CONF/groups.properties"
  # 5.19 checks web console logins against jetty-realm.properties instead (user: password, role).
  if [ -f "$ACTIVEMQ_CONF/jetty-realm.properties" ] && ! mounted jetty-realm.properties; then
    [[ $ACTIVEMQ_ADMIN_PASSWORD != *,* && ${ACTIVEMQ_APP_PASSWORD:-} != *,* ]] \
      || die "ActiveMQ 5.x: passwords must not contain a comma (web console user file format)"
    {
      printf '%s: %s, admin\n' "$ADMIN_USER" "$(prop_value "$ACTIVEMQ_ADMIN_PASSWORD")"
      [ -z "$APP_USER" ] || printf '%s: %s, user\n' "$APP_USER" "$(prop_value "$ACTIVEMQ_APP_PASSWORD")"
    } > "$ACTIVEMQ_CONF/jetty-realm.properties"
  fi
  echo "Users: admin user '$ADMIN_USER'${APP_USER:+, application user '$APP_USER'}"
fi

# ---------- credentials.properties (placeholders used by activemq.xml) ----------
PERSISTENCE=${ACTIVEMQ_PERSISTENCE:-kahadb}
if ! mounted credentials.properties; then
  {
    # The release's defaults are system/manager; replace them with the admin login.
    printf 'activemq.username=%s\n' "$ADMIN_USER"
    printf 'activemq.password=%s\n' "$(prop_value "${ACTIVEMQ_ADMIN_PASSWORD:-}")"
    if [ "$PERSISTENCE" = jdbc ]; then
      printf 'activemq.jdbc.url=%s\n' "$(prop_value "${ACTIVEMQ_JDBC_URL:-}")"
      printf 'activemq.jdbc.username=%s\n' "$(prop_value "${ACTIVEMQ_JDBC_USER:-}")"
      printf 'activemq.jdbc.password=%s\n' "$(prop_value "${ACTIVEMQ_JDBC_PASSWORD:-}")"
    fi
  } > "$ACTIVEMQ_CONF/credentials.properties"
fi

# ---------- activemq.xml ----------
xml_escape() { local v=${1//&/&amp;}; v=${v//</&lt;}; v=${v//>/&gt;}; v=${v//\"/&quot;}; printf '%s' "$v"; }

if mounted activemq.xml; then
  for var in ACTIVEMQ_BROKER_NAME ACTIVEMQ_TRANSPORTS ACTIVEMQ_PERSISTENCE ACTIVEMQ_JDBC_URL \
             ACTIVEMQ_SCHEDULER_ENABLED ACTIVEMQ_STORE_LIMIT ACTIVEMQ_TEMP_LIMIT ACTIVEMQ_WEB_CONSOLE; do
    [ -z "${!var:-}" ] || echo "WARNING: $var is ignored because activemq.xml is mounted" >&2
  done
  health_port=61616
else
  opts='maximumConnections=1000&amp;wireFormat.maxFrameSize=10485760'
  connectors=""
  IFS=',' read -ra transports <<< "${ACTIVEMQ_TRANSPORTS:-openwire}"
  for t in "${transports[@]}"; do
    t=${t//[[:space:]]/}
    case "$t" in
      openwire) uri="tcp://0.0.0.0:61616" ;;
      amqp)     uri="amqp://0.0.0.0:5672" ;;
      stomp)    uri="stomp://0.0.0.0:61613" ;;
      mqtt)     uri="mqtt://0.0.0.0:1883" ;;
      ws)       uri="ws://0.0.0.0:61614" ;;
      "")       continue ;;
      *)        die "ACTIVEMQ_TRANSPORTS: unknown transport '$t' (use openwire, amqp, stomp, mqtt, ws)" ;;
    esac
    connectors+="            <transportConnector name=\"$t\" uri=\"$uri?$opts\"/>"$'\n'
    [ -n "${health_port:-}" ] || { health_port=${uri##*:}; }
  done
  [ -n "$connectors" ] || die "ACTIVEMQ_TRANSPORTS: no transport enabled"

  datasource=""
  case "$PERSISTENCE" in
    kahadb)
      adapter='            <kahaDB directory="${activemq.data}/kahadb"/>'
      ;;
    jdbc)
      [ -n "${ACTIVEMQ_JDBC_URL:-}" ] || die "ACTIVEMQ_PERSISTENCE=jdbc needs ACTIVEMQ_JDBC_URL (e.g. jdbc:postgresql://postgres:5432/activemq)"
      # The lease holder ID must be unique per broker, or a waiting broker takes over the
      # lease of the running one. The hostname (the pod name in Kubernetes) is unique.
      datasource="    <bean id=\"jdbc-ds\" class=\"org.apache.commons.dbcp2.BasicDataSource\" destroy-method=\"close\">
        <property name=\"driverClassName\" value=\"$(xml_escape "${ACTIVEMQ_JDBC_DRIVER:-org.postgresql.Driver}")\"/>
        <property name=\"url\" value=\"\${activemq.jdbc.url}\"/>
        <property name=\"username\" value=\"\${activemq.jdbc.username}\"/>
        <property name=\"password\" value=\"\${activemq.jdbc.password}\"/>
        <property name=\"poolPreparedStatements\" value=\"true\"/>
    </bean>"
      adapter="            <jdbcPersistenceAdapter dataSource=\"#jdbc-ds\" lockKeepAlivePeriod=\"5000\">
                <locker>
                    <lease-database-locker lockAcquireSleepInterval=\"10000\" leaseHolderId=\"$(xml_escape "$(hostname)")\"/>
                </locker>
            </jdbcPersistenceAdapter>"
      ;;
    *) die "ACTIVEMQ_PERSISTENCE: use kahadb or jdbc (got '$PERSISTENCE')" ;;
  esac

  case "${ACTIVEMQ_WEB_CONSOLE:-true}" in
    true)
      # 6.3 and later split Jetty's config into jetty-spring.xml and conf/jetty/.
      if [ -f "$ACTIVEMQ_CONF/jetty-spring.xml" ]; then jetty='    <import resource="jetty-spring.xml"/>'
      else jetty='    <import resource="jetty.xml"/>'; fi ;;
    false) jetty="" ;;
    *) die "ACTIVEMQ_WEB_CONSOLE: use true or false" ;;
  esac

  case "${ACTIVEMQ_SCHEDULER_ENABLED:-false}" in
    true|false) ;; *) die "ACTIVEMQ_SCHEDULER_ENABLED: use true or false" ;;
  esac

  xml=$(<"$ACTIVEMQ_CONF/activemq.xml")
  xml=${xml//@BROKER_NAME@/$(xml_escape "${ACTIVEMQ_BROKER_NAME:-localhost}")}
  xml=${xml//@SCHEDULER@/${ACTIVEMQ_SCHEDULER_ENABLED:-false}}
  xml=${xml//@STORE_LIMIT@/$(xml_escape "${ACTIVEMQ_STORE_LIMIT:-100 gb}")}
  xml=${xml//@TEMP_LIMIT@/$(xml_escape "${ACTIVEMQ_TEMP_LIMIT:-50 gb}")}
  xml=${xml//@TRANSPORT_CONNECTORS@/${connectors%$'\n'}}
  xml=${xml//@PERSISTENCE_ADAPTER@/$adapter}
  xml=${xml//@DATASOURCE@/$datasource}
  xml=${xml//@JETTY_IMPORT@/$jetty}
  printf '%s\n' "$xml" > "$ACTIVEMQ_CONF/activemq.xml"
  echo "Broker: transports ${ACTIVEMQ_TRANSPORTS:-openwire}, persistence $PERSISTENCE, web console ${ACTIVEMQ_WEB_CONSOLE:-true}"
fi

# The healthcheck probes this port: the first transport, or 61616 with a mounted activemq.xml.
echo "${ACTIVEMQ_HEALTHCHECK_PORT:-$health_port}" > "$RUNTIME/healthcheck-port"

# ---------- Java options ----------
# The start script uses ACTIVEMQ_OPTS instead of its own defaults when it is set, so the
# defaults are repeated here; a user-supplied ACTIVEMQ_OPTS is appended.
java_opts="${ACTIVEMQ_OPTS_MEMORY:--XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=60.0}"
java_opts+=" -XX:+ExitOnOutOfMemoryError -Djava.util.logging.config.file=logging.properties"
java_opts+=" -Djava.security.auth.login.config=$ACTIVEMQ_CONF/login.config"
case "${ACTIVEMQ_METRICS_ENABLED:-false}" in
  true)
    java_opts+=" -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=${ACTIVEMQ_METRICS_PORT:-9404}:${ACTIVEMQ_METRICS_CONFIG:-/opt/jmx-exporter/activemq.yml}"
    echo "Metrics: Prometheus endpoint on :${ACTIVEMQ_METRICS_PORT:-9404}/metrics" ;;
  false) ;;
  *) die "ACTIVEMQ_METRICS_ENABLED: use true or false" ;;
esac
export ACTIVEMQ_OPTS="$java_opts ${ACTIVEMQ_OPTS:-}"

umask 022
# "console" runs the broker in the foreground. The start script launches Java through
# "sh -c", and that sh would die on SIGTERM without passing it on, so the JVM got killed
# instead of shutting the broker down. Send stop signals to the JVM itself and wait for it.
# The log passes through a reader that records when the broker is a master/slave standby
# (waiting for the store lock or the database lease), for the broker-state command.
watch_log() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      *"attempting to acquire exclusive lease"*|*"is now in slave mode"*) echo standby > "$RUNTIME/state" ;;
    esac
  done
}
"$ACTIVEMQ_HOME/bin/activemq" console > >(watch_log) 2>&1 &
launcher=$!
forward() {
  local java
  java=$(pgrep -P "$launcher" -x java || true)
  kill -"$1" "${java:-$launcher}" 2>/dev/null || true
}
trap 'forward TERM' TERM
trap 'forward INT' INT
rc=0
while :; do
  wait "$launcher" && rc=0 || rc=$?
  kill -0 "$launcher" 2>/dev/null || break
done
exit "$rc"
