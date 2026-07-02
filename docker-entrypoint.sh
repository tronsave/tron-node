#!/bin/bash
# Entrypoint for docker-java-tron (java-tron 4.8.2).
# See README / .env for all environment variables.
set -euo pipefail

NETWORK="${NETWORK:-nile}"
JVM_HEAP_GB="${JVM_HEAP_GB:-24}"

HTTP_PORT="${HTTP_PORT:-8090}"
GRPC_PORT="${GRPC_PORT:-50051}"
JSONRPC_PORT="${JSONRPC_PORT:-8545}"
P2P_PORT="${P2P_PORT:-18888}"

KAFKA_SERVER="${KAFKA_SERVER:-kafka:19092}"
EVENT_PLUGIN_ENABLED="${EVENT_PLUGIN_ENABLED:-true}"
EVENT_START_SYNC_BLOCK_NUM="${EVENT_START_SYNC_BLOCK_NUM:-0}"

LITE_NODE="${LITE_NODE:-false}"
LITE_OPEN_HISTORY="${LITE_OPEN_HISTORY:-false}"

case "$NETWORK" in
  mainnet|nile) ;;
  *) echo "ERROR: NETWORK must be 'mainnet' or 'nile' (got '$NETWORK')" >&2; exit 1 ;;
esac

case "$EVENT_PLUGIN_ENABLED" in true|false) EVENT_ENABLE="$EVENT_PLUGIN_ENABLED" ;;
  *) echo "ERROR: EVENT_PLUGIN_ENABLED must be 'true' or 'false'" >&2; exit 1 ;;
esac

if [ "$LITE_NODE" = "true" ] && [ "$LITE_OPEN_HISTORY" = "true" ]; then
  LITE_OPEN_HISTORY_VALUE="true"
else
  LITE_OPEN_HISTORY_VALUE="false"
fi

CONFIG=/data/config.conf
cp "/etc/tron/${NETWORK}.conf" "$CONFIG"

# Replace runtime placeholders (config templates ship with these markers)
sed -i \
  -e "s|__HTTP_PORT__|${HTTP_PORT}|g" \
  -e "s|__GRPC_PORT__|${GRPC_PORT}|g" \
  -e "s|__JSONRPC_PORT__|${JSONRPC_PORT}|g" \
  -e "s|__P2P_PORT__|${P2P_PORT}|g" \
  -e "s|__KAFKA_SERVER__|${KAFKA_SERVER}|g" \
  -e "s|__EVENT_ENABLE__|${EVENT_ENABLE}|g" \
  -e "s|__EVENT_START_SYNC_BLOCK_NUM__|${EVENT_START_SYNC_BLOCK_NUM}|g" \
  -e "s|__LITE_OPEN_HISTORY__|${LITE_OPEN_HISTORY_VALUE}|g" \
  "$CONFIG"

XMS_GB=$(( JVM_HEAP_GB * 3 / 4 ))
[ "$XMS_GB" -lt 1 ] && XMS_GB=1
JVM_OPTS=(
  -Xms${XMS_GB}g -Xmx${JVM_HEAP_GB}g
  -XX:ReservedCodeCacheSize=256m
  -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m
  -XX:MaxDirectMemorySize=1G
  -XX:+UseConcMarkSweepGC -XX:NewRatio=3
  -XX:+CMSScavengeBeforeRemark -XX:+ParallelRefProcEnabled
  -XX:+UseCMSInitiatingOccupancyOnly -XX:CMSInitiatingOccupancyFraction=70
  -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/data
  -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:/data/gc.log
  -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=100M
)

ARGS=(-c "$CONFIG" -d /data)
if [ -n "${EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  ARGS+=(${EXTRA_ARGS})
fi

echo "Starting java-tron ${NETWORK}: heap=${JVM_HEAP_GB}g http=${HTTP_PORT} grpc=${GRPC_PORT} kafka=${KAFKA_SERVER} event=${EVENT_ENABLE} lite=${LITE_NODE}"
if [ "$LITE_NODE" = "true" ]; then
  echo "Lite FullNode: mount a lite snapshot under /data before first start (https://developers.tron.network/docs/litefullnode)."
fi

exec java "${JVM_OPTS[@]}" -jar /usr/local/tron/FullNode.jar "${ARGS[@]}"
