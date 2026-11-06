# docker-java-tron

Run a [java-tron](https://github.com/tronprotocol/java-tron) 4.8.2.x FullNode (Nile testnet or Mainnet) with the Kafka event plugin using a single `docker compose` command.

Based on the official guides:

- [Nile testnet — How to Run](https://nileex.io/run/getRunPage)
- [Deploying A Node](https://developers.tron.network/docs/deploy-the-fullnode-or-supernode)
- [Event Subscription](https://developers.tron.network/docs/event-subscription)
- [Lite FullNode](https://developers.tron.network/docs/litefullnode)
- [Toolkit](https://developers.tron.network/docs/node-maintenance-tool-toolkit)

## Quick start

```bash
cp .env.example .env   # edit TRON_DATA_PATH / KAFKA_DATA_PATH for your machine
mkdir -p data/tron data/kafka
docker compose up -d --build
```

`.env` is **not** committed to git (see `.gitignore`). Copy from `.env.example` on each machine and set your own paths.

### Data paths (`.env`)

| Variable | Default | Container mount |
|---|---|---|
| `TRON_DATA_PATH` | `./data/tron` | `/data` (must contain `database/`, `index/`) |
| `KAFKA_DATA_PATH` | `./data/kafka` | `/var/lib/kafka/data` |

Reuse an existing snapshot or node data:

```env
TRON_DATA_PATH=/path/to/output-directory
```

Set `TRON_DATA_PATH` to your extracted snapshot directory (`output-directory`). It must contain `database/` (and usually `index/`).

| Service | Container | Default ports (host) |
|---|---|---|
| java-tron FullNode | `tron-node` | HTTP `8090`, JSON-RPC `8545`, gRPC `50051`, Prometheus `9527`, P2P `18888` tcp+udp |
| Kafka (KRaft) | `kafka` | `9092` (host), `19092` (internal Docker network) |

Check the node:

```bash
curl -X POST http://localhost:8090/wallet/getnowblock

curl -X POST http://localhost:8545/jsonrpc -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

curl http://localhost:9527/metrics | head
```

Consume Kafka events:

```bash
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:19092 --topic block
```

Host Kafka clients connect to `localhost:9092` (or your custom `KAFKA_PORT`).

## Upgrading java-tron

java-tron releases are marked **Mandatory** or **Non-mandatory** in their release notes. Mandatory upgrades must be applied before the stated deadline or the node falls off the network.

1. Pick the release: [Mainnet](https://github.com/tronprotocol/java-tron/releases) · [Nile](https://github.com/tron-nile-testnet/nile-testnet/releases).
2. In `.env`, set `JAVA_TRON_VERSION` to the tag and `FULLNODE_SHA256` to the SHA-256 shown next to the jar on the release page (`FullNode.jar` for Mainnet, `FullNode-Nile-x64-*.jar` for Nile).
3. `docker compose build tron`, then `docker compose up -d tron`.

The image is tagged `docker-java-tron:<JAVA_TRON_VERSION>`, so the previous version stays on the machine: to roll back, restore the two values in `.env` and run `docker compose up -d tron` (no rebuild needed).

### What the build verifies

| Artifact | Check |
|---|---|
| `FullNode.jar` | SHA-256 pin (`FULLNODE_SHA256`) **and** GPG signature (`<jar>.sig`) against the release key in `keys/` |
| `Toolkit.jar` | SHA-256 pin and GPG signature (same Mainnet release key) |
| Oracle JDK 8 tarball | SHA-256 pin (`JDK_SHA256`) |
| Kafka event plugin | SHA-256 pin of the committed zip, plus a check that it is the Jackson (v3.0.0) build |

The build stops if any check fails. Release keys shipped in `keys/` (primary key fingerprints):

- Mainnet — `build@tron.network` — `07B2 3298 AEA4 E006 BD9A 42DE 785F B96D 2C7C 3CA5` ([source](https://github.com/tronprotocol/java-tron#integrity-check))
- Nile — `build@nileex.io` — `BBA2 FC19 D5F0 B54A B1EE 072B CA92 A550 1765 E1EC` ([source](https://github.com/tron-nile-testnet/nile-testnet/releases))

If a key is rotated or its signing subkey expires, refresh the file from a keyserver and confirm the fingerprint against the project's own page before committing it:

```bash
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 07B23298AEA4E006BD9A42DE785FB96D2C7C3CA5
gpg --export --armor 07B23298AEA4E006BD9A42DE785FB96D2C7C3CA5 > keys/tron-release.asc
```

Build args for special cases: `FULLNODE_SHA256=skip` (no pin, signature still checked), `VERIFY_GPG=false` (custom `FULLNODE_JAR_URL` without a `.sig`), `JDK_URL` (your own mirror of the JDK tarball), `TOOLKIT_VERSION=` (leave Toolkit out).

### Kafka data location (upgrading from an older version of this repo)

Older versions of `docker-compose.yml` did not set `KAFKA_LOG_DIRS`, so the broker wrote to `/tmp/kafka-logs` **inside the container** instead of `KAFKA_DATA_PATH`. Topics and consumer offsets were therefore lost whenever the container was recreated. Check where your broker keeps its data:

```bash
docker exec kafka sh -c 'ls /var/lib/kafka/data | wc -l; ls /tmp/kafka-logs 2>/dev/null | wc -l'
```

If the first number is `0` and the second is not, move the data out **before** the first `docker compose up` with this version (which recreates the container):

```bash
docker exec kafka du -sh /tmp/kafka-logs                     # needs this much free space at KAFKA_DATA_PATH
docker compose stop tron kafka
sudo docker cp kafka:/tmp/kafka-logs/. "$KAFKA_DATA_PATH"/   # the path from your .env; must be empty before the copy
sudo ls "$KAFKA_DATA_PATH" | wc -l                           # same count as the second number above; meta.properties is there
docker compose up -d --build
```

Do not run `docker compose up` before the copy has finished and the count matches: it replaces the old container, and the data inside it goes with it.

The copy keeps the cluster id (`meta.properties`), the topics and the committed consumer offsets. It is owned by root, which the broker cannot write to; the `kafka-init` service in `docker-compose.yml` hands the directory to the broker's user on every `docker compose up`, so no manual `chown` is needed. If you start the broker some other way and it fails with `AccessDeniedException`, run `sudo chown -R 1000:1000 "$KAFKA_DATA_PATH"`.

## Configuration (.env)

### Network & memory

| Variable | Default | Description |
|---|---|---|
| `TRON_DATA_PATH` | `./data/tron` | Host path → `/data` (blockchain data) |
| `KAFKA_DATA_PATH` | `./data/kafka` | Host path → Kafka logs |
| `NETWORK` | `nile` | `nile` or `mainnet` |
| `JAVA_TRON_VERSION` | `GreatVoyage-Nile-v4.8.2.4-PQ1-build1` | Release tag downloaded at build time (Mainnet: `GreatVoyage-v4.8.2.4`) |
| `FULLNODE_SHA256` | SHA-256 of the default Nile jar | Must match the jar of `JAVA_TRON_VERSION` |
| `JVM_HEAP_GB` | `24` | Max JVM heap. Leave RAM for the OS page cache — LevelDB depends on it |
| `MEM_LIMIT` | `32g` | Container memory limit (≥ heap + 8G) |

### Ports and exposure

| Variable | Default | Description |
|---|---|---|
| `HTTP_PORT` | `8090` | HTTP API (`/wallet/*`) |
| `GRPC_PORT` | `50051` | gRPC API |
| `JSONRPC_PORT` | `8545` | JSON-RPC (`/jsonrpc`, eth-compatible) |
| `PROMETHEUS_PORT` | `9527` | Prometheus metrics (`/metrics`) |
| `P2P_PORT` | `18888` | P2P TCP + UDP |
| `API_BIND_IP` | `0.0.0.0` | Host address for the HTTP / JSON-RPC / gRPC / Prometheus ports |
| `JSONRPC_ENABLED` | `true` | Set `false` if you do not use JSON-RPC |
| `PROMETHEUS_ENABLED` | `true` | Set `false` to turn the metrics exporter off |
| `KAFKA_PORT` | `9092` | Kafka host port (external clients) |
| `KAFKA_BIND_IP` | `0.0.0.0` | Host address for the Kafka external listener |
| `KAFKA_INTERNAL_PORT` | `19092` | Kafka internal port (tron → kafka) |
| `KAFKA_ADVERTISED_HOST` | `localhost` | Hostname advertised to external Kafka clients |

Example — run HTTP on 18090 and Kafka on 29092:

```env
HTTP_PORT=18090
KAFKA_PORT=29092
KAFKA_INTERNAL_PORT=29093
KAFKA_ADVERTISED_HOST=localhost
```

Then `docker compose up -d` remaps ports automatically.

### Event plugin (Kafka)

| Variable | Default | Description |
|---|---|---|
| `EVENT_PLUGIN_ENABLED` | `true` | Sets `event.subscribe.enable` |
| `EVENT_TOPICS` | `block,transaction,contractevent,contractlog` | Triggers pushed to Kafka. Also available: `solidity`, `solidityevent`, `soliditylog` |
| `EVENT_START_SYNC_BLOCK_NUM` | `0` | >0 = sync historical events from block height (framework V2.0) |
| `EVENT_CONTRACT_ADDRESS` | _(empty)_ | Comma-separated base58 contract addresses to filter on. Empty = all contracts |
| `EVENT_CONTRACT_TOPIC` | _(empty)_ | Comma-separated topic hashes to filter on. Empty = all topics |
| `KAFKA_LOG_RETENTION_MS` | `604800000` | Message retention (7 days) |
| `KAFKA_LOG_RETENTION_BYTES` | `-1` | Optional size cap **per partition** |
| `KAFKA_VERSION` | `3.9.2` | `apache/kafka` image tag |

Every enabled trigger costs CPU on the node (ABI decoding for `contractevent`) and disk on the broker. List only what your consumers read:

```env
# a consumer that only reads transactions
EVENT_TOPICS=transaction
```

`vm.supportConstant = true` is set so constant/view (`triggerConstantContract`) calls work on the FullNode.

Both filters accept comma-separated lists and default to `[""]` (no filter → subscribe to everything):

```env
# only stream events from two contracts, any topic
EVENT_CONTRACT_ADDRESS=TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t,TXpw8XeWYeTUd4quDskoUqeQPowRh4jY65
EVENT_CONTRACT_TOPIC=
```

### Other options

| Variable | Default | Description |
|---|---|---|
| `CONSTANT_CALL_TIMEOUT_MS` | _(empty)_ | `vm.constantCallTimeoutMs` (4.8.2+): max TVM time for constant calls. Empty = java-tron default |
| `HEALTH_MAX_LAG_SEC` | `300` | Container is unhealthy when the head block is older than this. `0` = only check that the API answers |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | `50m` / `5` | Rotation of the containers' stdout logs |
| `EXTRA_ARGS` | _(empty)_ | Extra `FullNode.jar` command-line arguments |

### Lite FullNode

| Variable | Default | Description |
|---|---|---|
| `LITE_NODE` | `false` | Informational flag; lite mode is determined by the database snapshot |
| `LITE_OPEN_HISTORY` | `false` | Sets `openHistoryQueryWhenLiteFN` — enable history query APIs on lite node |

Lite FullNode uses the same startup command as a FullNode; the difference is the **database**. A lite snapshot contains only the latest chain state plus the most recent 65,536 blocks ([docs](https://developers.tron.network/docs/litefullnode)).

1. Download a lite snapshot (Nile: [database.nileex.io](https://database.nileex.io/), Mainnet: [public backup data](https://developers.tron.network/docs/main-net-database-snapshots)).
2. Set `LITE_NODE=true` in `.env` (optional, for logging).
3. Mount the snapshot into `/data` before first start (same as full snapshot restore below).
4. Optionally set `LITE_OPEN_HISTORY=true` if you need history query APIs (data before snapshot height remains unavailable).

### Mainnet example

```env
NETWORK=mainnet
JAVA_TRON_VERSION=GreatVoyage-v4.8.2.4
FULLNODE_SHA256=709423e8d14ccba391daeef7aa78bb5f41a1b69559cc867346beacbd6aae39c9
```

## Security notes

- **The node APIs have no authentication.** HTTP, JSON-RPC, gRPC and Prometheus are published on `API_BIND_IP`; Kafka's external listener (PLAINTEXT) on `KAFKA_BIND_IP`. Set them to `127.0.0.1` or a private interface address, or keep them behind a firewall. Remember that Docker publishes ports ahead of the host's `INPUT` rules — filter in the `DOCKER-USER` chain. Only P2P (`18888` tcp+udp) needs to be reachable from the internet.
- **Unprivileged process.** The entrypoint starts as root only to fix ownership of the data directory, then runs java-tron as the `tron` user (uid `10001`). Both containers run with `no-new-privileges` and all capabilities dropped (the node keeps only the four needed for that ownership step). The first start after upgrading from an older image does a one-time `chown` of the data directory, which can take a few minutes on a full Mainnet database.
- **Only the FullNode listeners are published.** The Solidity/PBFT listeners (HTTP `8092`, gRPC `50061`/`50071`) are reachable only from containers on the same Docker network. `/walletsolidity` and the `WalletSolidity` gRPC service are not served on the FullNode ports; publish those listeners yourself if you need them.
- **Do not put keys in this node.** `localwitness` is empty; this image is meant for a non-witness FullNode.

## Toolkit

`Toolkit.jar` ships in the image for database maintenance (`db lite`, `db archive`, `db convert`, …). Stop the node first — the database cannot be opened by two processes:

```bash
docker compose stop tron
docker compose run --rm --no-deps --user 10001 --entrypoint java tron \
  -jar /usr/local/tron/Toolkit.jar db lite -o split -t snapshot --fn-data-path /data --dataset-path /data/lite
```

See the [Toolkit guide](https://developers.tron.network/docs/node-maintenance-tool-toolkit) for all commands.

## Config philosophy

Configs in `configs/nile.conf` and `configs/mainnet.conf` are **minimal**: only values that differ from java-tron built-in defaults ([reference.conf](https://github.com/tronprotocol/java-tron/blob/develop/common/src/main/resources/reference.conf)).

What we keep in config files:

| Section | Why |
|---|---|
| `storage.merkleRoot` (Nile) | Network-specific data integrity check |
| `storage.txCache.initOptimization` | Faster startup (as in the official Mainnet config) |
| `storage.defaultM` / `defaultL` | LevelDB `maxOpenFiles` 500 / 1000, the production values recommended by java-tron ([TIP-343](https://github.com/tronprotocol/tips/blob/master/tip-343.md)) |
| `node.p2p.version` | Distinguishes Mainnet (`11111`) vs Nile (`201910292`) |
| Ports, JSON-RPC, Prometheus | Set at runtime via env vars |
| `rate.limiter.apiNonBlocking` | Reject immediately on overload instead of queueing threads (4.8.2+) |
| `seed.node` / `genesis.block` | Network identity — no sensible default |
| `block` / `committee` (Nile) | Testnet-specific consensus parameters |
| `event.subscribe` | Kafka plugin path, server, topics |

Everything else (gRPC threads, flow control, rate limits, JSON-RPC limits, …) uses java-tron defaults.

## Performance notes

- **JVM**: Oracle JDK 8 (x86_64) + CMS GC + tcmalloc (`LD_PRELOAD`), per the [TRON deployment guide](https://tronprotocol.github.io/documentation-en/using_javatron/installing_javatron/#jvm-parameter-optimization-for-mainnet-fullnode-deployment).
- **Heap vs page cache**: LevelDB reads through the OS page cache. A heap that takes most of the RAM slows the node down; check `gc.log` before raising `JVM_HEAP_GB`.
- **ulimits**: `nofile=65535` in compose (required by the LevelDB `maxOpenFiles` settings).
- **Event plugin**: Kafka `release_v3.0.0` (JDK 8), framework V2.0 (`event.subscribe.version = 1`). Disable triggers nobody consumes (`EVENT_TOPICS`).

Hardware ([official guidance](https://github.com/tronprotocol/java-tron#hardware-requirements)): Mainnet FullNode 16+ cores, 32GB+ RAM, 3.5TB+ high-performance SSD (4TB recommended), or 200GB for a Lite FullNode. Nile 8+ cores, 16GB+ RAM, 200GB+ SSD.

## Sync from a database snapshot (recommended)

```bash
docker compose down
docker run --rm -v "$(pwd)/data/tron:/to" -v docker-java-tron_tron-data:/from \
  ubuntu:24.04 bash -c "cp -a /from/. /to/"   # only if migrating from an old named volume
docker compose up -d
```

Edit `configs/nile.conf` / `configs/mainnet.conf` for advanced overrides, then `docker compose up -d --build`.

## Data layout

Blockchain data lives at `TRON_DATA_PATH` (default `./data/tron`), mounted to `/data` in the container:

- `database/`, `index/` — chain data
- `config.conf` — regenerated on every start
- `logs/` — java-tron logs
- `gc.log*` — GC logs

Kafka data lives at `KAFKA_DATA_PATH` (default `./data/kafka`).

The `data/` directory is gitignored — do not commit blockchain or Kafka data to the repo.

## Stopping safely

```bash
docker compose stop        # node first, then Kafka
docker compose stop tron   # node only
```

`java` runs as PID 1 in the container, so Docker's SIGTERM reaches the node directly — the same
`kill -15` that java-tron's own `start.sh --stop` sends. The node then stops its API and P2P
services, closes the event plugin and closes every database. Docker waits up to 5 minutes for
this (`stop_grace_period`; upstream's script waits 60 s) before it falls back to SIGKILL. Kafka
gets 2 minutes. `docker compose up -d`, `restart` and `down` use the same grace periods.

Check that a stop was clean:

```bash
docker inspect -f '{{.State.ExitCode}}' tron-node   # 143 = exited on SIGTERM; 137 = killed
tail -n 1 "$TRON_DATA_PATH"/logs/tron.log           # ******** close end ********
```

Never `kill -9` / `docker kill` the node, and stop the stack yourself before rebooting the
host — do not count on the host's shutdown to wait for the full grace period. A container that
hits `MEM_LIMIT` is also killed without warning, so keep headroom above `JVM_HEAP_GB`.

### Events around a restart

- **Every restart replays a few blocks.** java-tron keeps blocks that are not yet solidified in
  memory, so after a restart — even a clean one — it processes the last ~20 blocks again and
  publishes their events a second time. Consumers must be idempotent.
- **An unclean stop can lose events.** Events that had not reached Kafka when the process was
  killed are not published again for blocks that were already written to disk. To backfill,
  set `EVENT_START_SYNC_BLOCK_NUM` to the first missing block and run `docker compose up -d tron`:
  the node re-publishes everything from that block up to the latest solidified block, then
  continues live. Set it back to `0` afterwards, otherwise every restart replays from that
  block again.
