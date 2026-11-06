#!/bin/bash
# Entrypoint for docker-java-tron (java-tron 4.8.2.x).
# See README / .env for all environment variables.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# Started as root: make the data directory writable for the unprivileged user (one-time fix
# for data created by older images), then re-run this script without privileges.
if [ "$(id -u)" = 0 ]; then
  uid=$(id -u tron)
  for d in /data /data/database /data/index; do
    if [ -e "$d" ] && [ "$(stat -c %u "$d")" != "$uid" ]; then
      echo "Fixing ownership of /data for user tron (uid $uid); this can take a while on a large database..."
      chown -R tron:tron /data
      break
    fi
  done
  exec setpriv --reuid=tron --regid=tron --init-groups "$0" "$@"
fi

NETWORK="${NETWORK:-nile}"
JVM_HEAP_GB="${JVM_HEAP_GB:-24}"

HTTP_PORT="${HTTP_PORT:-8090}"
GRPC_PORT="${GRPC_PORT:-50051}"
JSONRPC_PORT="${JSONRPC_PORT:-8545}"
P2P_PORT="${P2P_PORT:-18888}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9527}"

JSONRPC_ENABLED="${JSONRPC_ENABLED:-true}"
PROMETHEUS_ENABLED="${PROMETHEUS_ENABLED:-true}"

KAFKA_SERVER="${KAFKA_SERVER:-kafka:19092}"
EVENT_PLUGIN_ENABLED="${EVENT_PLUGIN_ENABLED:-true}"
EVENT_START_SYNC_BLOCK_NUM="${EVENT_START_SYNC_BLOCK_NUM:-0}"

# Triggers pushed to Kafka (comma-separated). Each enabled trigger costs CPU on the node and
# disk on the broker — enable only what your consumers read.
EVENT_TOPICS="${EVENT_TOPICS:-block,transaction,contractevent,contractlog}"

# Event filters: comma-separated lists; empty = [""] (no filter, subscribe to everything).
EVENT_CONTRACT_ADDRESS="${EVENT_CONTRACT_ADDRESS:-}"
EVENT_CONTRACT_TOPIC="${EVENT_CONTRACT_TOPIC:-}"

LITE_NODE="${LITE_NODE:-false}"
LITE_OPEN_HISTORY="${LITE_OPEN_HISTORY:-false}"

# Optional: max TVM time (ms) for constant calls (triggerconstantcontract, eth_call, ...).
CONSTANT_CALL_TIMEOUT_MS="${CONSTANT_CALL_TIMEOUT_MS:-}"

# ---- validation (values are substituted into the config file below) ----
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_bool() { [ "$1" = true ] || [ "$1" = false ]; }

case "$NETWORK" in
  mainnet|nile) ;;
  *) die "NETWORK must be 'mainnet' or 'nile' (got '$NETWORK')" ;;
esac
for v in JVM_HEAP_GB HTTP_PORT GRPC_PORT JSONRPC_PORT P2P_PORT PROMETHEUS_PORT EVENT_START_SYNC_BLOCK_NUM; do
  is_uint "${!v}" || die "$v must be a non-negative integer (got '${!v}')"
done
for v in EVENT_PLUGIN_ENABLED JSONRPC_ENABLED PROMETHEUS_ENABLED LITE_NODE LITE_OPEN_HISTORY; do
  is_bool "${!v}" || die "$v must be 'true' or 'false' (got '${!v}')"
done
[[ "$KAFKA_SERVER" =~ ^[A-Za-z0-9._:,-]+$ ]] || die "KAFKA_SERVER must be host:port[,host:port...]"
for v in EVENT_CONTRACT_ADDRESS EVENT_CONTRACT_TOPIC; do
  [[ "${!v}" =~ ^[A-Za-z0-9_,\ ]*$ ]] || die "$v may only contain letters, digits, '_' and ','"
done
if [ -n "$CONSTANT_CALL_TIMEOUT_MS" ]; then
  is_uint "$CONSTANT_CALL_TIMEOUT_MS" && [ "$CONSTANT_CALL_TIMEOUT_MS" -gt 0 ] \
    || die "CONSTANT_CALL_TIMEOUT_MS must be a positive integer"
fi

if [ "$LITE_NODE" = "true" ] && [ "$LITE_OPEN_HISTORY" = "true" ]; then
  LITE_OPEN_HISTORY_VALUE="true"
else
  LITE_OPEN_HISTORY_VALUE="false"
fi

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

# Build a HOCON string array from a comma-separated list.
# Empty input -> [""] which java-tron treats as "match everything" (no filter).
build_hocon_list() {
  local csv="$1" out="" item
  [ -z "$csv" ] && { echo '[""]'; return; }
  IFS=',' read -ra _items <<< "$csv"
  for item in "${_items[@]}"; do
    item="$(trim "$item")"
    [ -z "$item" ] && continue
    if [ -z "$out" ]; then out="\"$item\""; else out="${out},\"$item\""; fi
  done
  if [ -z "$out" ]; then echo '[""]'; else echo "[${out}]"; fi
}

EVENT_CONTRACT_ADDRESS_LIST="$(build_hocon_list "$EVENT_CONTRACT_ADDRESS")"
EVENT_CONTRACT_TOPIC_LIST="$(build_hocon_list "$EVENT_CONTRACT_TOPIC")"

# Which triggers are enabled.
declare -A TRIGGER_ON=(
  [block]=false [transaction]=false [contractevent]=false [contractlog]=false
  [solidity]=false [solidityevent]=false [soliditylog]=false
)
IFS=',' read -ra _topics <<< "$EVENT_TOPICS"
for t in "${_topics[@]}"; do
  t="$(trim "$t")"
  [ -z "$t" ] && continue
  [ -n "${TRIGGER_ON[$t]+set}" ] || die "EVENT_TOPICS: unknown trigger '$t' (valid: ${!TRIGGER_ON[*]})"
  TRIGGER_ON[$t]=true
done

CONFIG=/data/config.conf
cp "/etc/tron/${NETWORK}.conf" "$CONFIG"

# Replace runtime placeholders (config templates ship with these markers)
SED_ARGS=(
  -e "s|__HTTP_PORT__|${HTTP_PORT}|g"
  -e "s|__GRPC_PORT__|${GRPC_PORT}|g"
  -e "s|__JSONRPC_PORT__|${JSONRPC_PORT}|g"
  -e "s|__JSONRPC_ENABLE__|${JSONRPC_ENABLED}|g"
  -e "s|__P2P_PORT__|${P2P_PORT}|g"
  -e "s|__PROMETHEUS_ENABLE__|${PROMETHEUS_ENABLED}|g"
  -e "s|__PROMETHEUS_PORT__|${PROMETHEUS_PORT}|g"
  -e "s|__KAFKA_SERVER__|${KAFKA_SERVER}|g"
  -e "s|__EVENT_ENABLE__|${EVENT_PLUGIN_ENABLED}|g"
  -e "s|__EVENT_START_SYNC_BLOCK_NUM__|${EVENT_START_SYNC_BLOCK_NUM}|g"
  -e "s|__EVENT_CONTRACT_ADDRESS__|${EVENT_CONTRACT_ADDRESS_LIST}|g"
  -e "s|__EVENT_CONTRACT_TOPIC__|${EVENT_CONTRACT_TOPIC_LIST}|g"
  -e "s|__LITE_OPEN_HISTORY__|${LITE_OPEN_HISTORY_VALUE}|g"
)
for t in "${!TRIGGER_ON[@]}"; do
  SED_ARGS+=(-e "s|__EVENT_TRIGGER_${t^^}__|${TRIGGER_ON[$t]}|g")
done
sed -i "${SED_ARGS[@]}" "$CONFIG"

if [ -n "$CONSTANT_CALL_TIMEOUT_MS" ]; then
  printf '\nvm.constantCallTimeoutMs = %s\n' "$CONSTANT_CALL_TIMEOUT_MS" >> "$CONFIG"
fi

if grep -qE '__[A-Z0-9_]+__' "$CONFIG"; then
  die "unreplaced placeholder in $CONFIG: $(grep -oE '__[A-Z0-9_]+__' "$CONFIG" | sort -u | tr '\n' ' ')"
fi

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

ENABLED_TOPICS=""
for t in block transaction contractevent contractlog solidity solidityevent soliditylog; do
  [ "${TRIGGER_ON[$t]}" = true ] && ENABLED_TOPICS+="$t "
done

echo "Starting java-tron ${NETWORK} as $(id -un): heap=${JVM_HEAP_GB}g http=${HTTP_PORT} grpc=${GRPC_PORT} jsonrpc=${JSONRPC_ENABLED} metrics=${PROMETHEUS_ENABLED} lite=${LITE_NODE}"
echo "Events: enabled=${EVENT_PLUGIN_ENABLED} kafka=${KAFKA_SERVER} topics=[${ENABLED_TOPICS% }] contractAddress=${EVENT_CONTRACT_ADDRESS_LIST} contractTopic=${EVENT_CONTRACT_TOPIC_LIST}"
if [ "$LITE_NODE" = "true" ]; then
  echo "Lite FullNode: mount a lite snapshot under /data before first start (https://developers.tron.network/docs/litefullnode)."
fi

exec java "${JVM_OPTS[@]}" -jar /usr/local/tron/FullNode.jar "${ARGS[@]}"
