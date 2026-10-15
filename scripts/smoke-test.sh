#!/usr/bin/env bash
# Smoke test for the ActiveMQ image, run by CI before anything is published.
#  1. One broker (KahaDB, all transports, metrics): messages as the app user, logins
#     refused without or with wrong credentials, web console roles, STOMP login, metrics.
#  2. JDBC master/slave on PostgreSQL: two brokers, the standby takes over when the active
#     one is killed, and no message is lost.
# Usage: scripts/smoke-test.sh <image>   (cleans up its containers and network at the end;
#        set KEEP=1 to keep them for inspection)
set -euo pipefail

IMAGE=${1:?usage: $0 <image>}
NET=amq-smoke
ADMIN_PW='Adm1n=p@ss:w0rd'   # characters that need escaping in properties files
APP_PW='app-secret'

cleanup() {
  [ "${KEEP:-}" = 1 ] && return
  docker rm -f smoke-amq smoke-b1 smoke-b2 smoke-pg >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; for c in smoke-amq smoke-b1 smoke-b2; do docker logs "$c" 2>&1 | tail -30 || true; done; exit 1; }

wait_healthy() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" = healthy ] && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || fail "$1 exited"
    sleep 2
  done
  fail "$1 not healthy"
}
# The ActiveMQ CLI from the image under test. The start script pastes arguments into a
# "sh -c" string, so failover URLs need an extra pair of quotes.
cli() { docker run --rm --network "$NET" "$IMAGE" activemq "$@" 2>&1 || true; }
# expect_cli PATTERN ARGS...: runs the CLI and checks its output for PATTERN.
expect_cli() { local want=$1 out; shift; out=$(cli "$@"); grep -q -- "$want" <<< "$out"; }
# HTTP from inside a broker container (the image has no curl): prints the status code.
http() { # container port path [user:password]
  local auth=""
  [ -z "${4:-}" ] || auth="Authorization: Basic $(printf '%s' "$4" | base64 -w0)"$'\r\n'
  docker exec "$1" bash -c "exec 3<>/dev/tcp/127.0.0.1/$2; printf 'GET $3 HTTP/1.0\r\nHost: localhost\r\n${auth//$'\r\n'/\\r\\n}\r\n' >&3; cat <&3" \
    | head -1 | awk '{print $2}'
}

docker network create "$NET" >/dev/null

echo "== 1. Single broker"
docker run -d --name smoke-amq --network "$NET" \
  -e ACTIVEMQ_ADMIN_PASSWORD="$ADMIN_PW" -e ACTIVEMQ_APP_USER=app -e ACTIVEMQ_APP_PASSWORD="$APP_PW" \
  -e ACTIVEMQ_TRANSPORTS=openwire,amqp,stomp,mqtt,ws -e ACTIVEMQ_METRICS_ENABLED=true \
  "$IMAGE" >/dev/null
wait_healthy smoke-amq
for t in openwire amqp stomp mqtt ws; do
  docker logs smoke-amq 2>&1 | grep -q "Connector $t started" || fail "transport $t not started"
done
echo "All five transports started"

expect_cli "Produced: 5 messages" producer --brokerUrl tcp://smoke-amq:61616 --user app --password "$APP_PW" \
  --destination queue://smoke --messageCount 5 || fail "app user cannot send"
expect_cli "Consumed: 5 messages" consumer --brokerUrl tcp://smoke-amq:61616 --user app --password "$APP_PW" \
  --destination queue://smoke --messageCount 5 || fail "app user cannot receive"
echo "App user: sent and received 5 messages"
expect_cli "JMSSecurityException" producer --brokerUrl tcp://smoke-amq:61616 --destination queue://smoke --messageCount 1 || fail "anonymous connection accepted"
expect_cli "JMSSecurityException" producer --brokerUrl tcp://smoke-amq:61616 --user app --password wrong --destination queue://smoke --messageCount 1 || fail "wrong password accepted"
echo "Anonymous and wrong-password connections refused"

[ "$(http smoke-amq 8161 /admin/)" = 401 ] || fail "web console open without login"
[ "$(http smoke-amq 8161 /admin/ "admin:$ADMIN_PW")" = 200 ] || fail "admin cannot open the web console"
[ "$(http smoke-amq 8161 /admin/ "app:$APP_PW")" = 403 ] || fail "app user can open the web console"
echo "Web console: 401 without login, 200 for admin, 403 for the app user"

stomp=$(docker exec smoke-amq bash -c "exec 3<>/dev/tcp/127.0.0.1/61613; printf 'CONNECT\naccept-version:1.2\nhost:x\nlogin:app\npasscode:$APP_PW\n\n\0' >&3; timeout 3 head -1 <&3" || true)
[ "$stomp" = CONNECTED ] || fail "STOMP login failed: $stomp"
echo "STOMP login ok"

metrics=$(docker exec smoke-amq bash -c 'exec 3<>/dev/tcp/127.0.0.1/9404; printf "GET /metrics HTTP/1.0\r\n\r\n" >&3; cat <&3')
grep -q '^activemq_destination_enqueuecount{broker="localhost",destination="smoke",destination_type="Queue"} 5.0' <<< "$metrics" \
  || fail "queue metrics missing"
grep -q '^activemq_broker_slave{broker="localhost"} 0.0' <<< "$metrics" || fail "broker metrics missing"
grep -q '^jvm_memory_used_bytes' <<< "$metrics" || fail "JVM metrics missing"
echo "Prometheus metrics ok"

docker stop smoke-amq >/dev/null
docker logs smoke-amq 2>&1 | grep -q "is shutdown" || fail "broker did not shut down cleanly on SIGTERM"
echo "Clean shutdown on SIGTERM"

echo "== 2. JDBC master/slave on PostgreSQL"
docker run -d --name smoke-pg --network "$NET" -e POSTGRES_PASSWORD=pgpw -e POSTGRES_DB=activemq postgres:18 >/dev/null
for _ in $(seq 1 30); do docker exec smoke-pg pg_isready -U postgres -d activemq >/dev/null 2>&1 && break; sleep 2; done
for b in smoke-b1 smoke-b2; do
  docker run -d --name "$b" --hostname "$b" --network "$NET" \
    -e ACTIVEMQ_ADMIN_PASSWORD="$ADMIN_PW" -e ACTIVEMQ_APP_USER=app -e ACTIVEMQ_APP_PASSWORD="$APP_PW" \
    -e ACTIVEMQ_PERSISTENCE=jdbc -e ACTIVEMQ_JDBC_URL=jdbc:postgresql://smoke-pg:5432/activemq \
    -e ACTIVEMQ_JDBC_USER=postgres -e ACTIVEMQ_JDBC_PASSWORD=pgpw "$IMAGE" >/dev/null
  [ "$b" = smoke-b1 ] && wait_healthy smoke-b1
done
for _ in $(seq 1 30); do
  docker logs smoke-b2 2>&1 | grep -q "attempting to acquire exclusive lease" && break; sleep 2
done
docker logs smoke-b2 2>&1 | grep -q "attempting to acquire exclusive lease" || fail "standby is not waiting for the lease"
echo "smoke-b1 active, smoke-b2 waiting for the lease"

URL="'failover:(tcp://smoke-b1:61616,tcp://smoke-b2:61616)'"
expect_cli "Produced: 20 messages" producer --brokerUrl "$URL" --user app --password "$APP_PW" --destination queue://ha \
  --messageCount 20 --persistent true || fail "cannot send to the active broker"
docker kill smoke-b1 >/dev/null
wait_healthy smoke-b2
expect_cli "Consumed: 20 messages" consumer --brokerUrl "$URL" --user app --password "$APP_PW" --destination queue://ha \
  --messageCount 20 || fail "messages lost after failover"
echo "Failover ok: smoke-b2 took over, all 20 messages received"

echo "Smoke test passed"
