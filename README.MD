# docker-java-tron

Run a [java-tron](https://github.com/tronprotocol/java-tron) 4.8.2 FullNode (Nile testnet or Mainnet) with the Kafka event plugin using a single `docker compose` command.

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
| java-tron FullNode | `tron-node` | HTTP `8090`, JSON-RPC `8545`, gRPC `50051`, P2P `18888` tcp+udp |
| Kafka (KRaft) | `kafka` | `9092` (host), `19092` (internal Docker network) |

Check the node:

```bash
curl -X POST http://localhost:8090/wallet/getnowblock

curl -X POST http://localhost:8545/jsonrpc -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Consume Kafka events:

```bash
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:19092 --topic block
```

Host Kafka clients connect to `localhost:9092` (or your custom `KAFKA_PORT`).

## Configuration (.env)

### Network & memory

| Variable | Default | Description |
|---|---|---|
| `TRON_DATA_PATH` | `./data/tron` | Host path → `/data` (blockchain data) |
| `KAFKA_DATA_PATH` | `./data/kafka` | Host path → Kafka logs |
| `NETWORK` | `nile` | `nile` or `mainnet` |
| `JAVA_TRON_VERSION` | `GreatVoyage-Nile-v4.8.2-PQ1-build1` | Release tag downloaded at build time |
| `JVM_HEAP_GB` | `24` | Max JVM heap (~40% of host RAM recommended) |
| `MEM_LIMIT` | `32g` | Container memory limit (≥ heap + 8G) |

### Custom ports

| Variable | Default | Description |
|---|---|---|
| `HTTP_PORT` | `8090` | HTTP API (`/wallet/*`) |
| `GRPC_PORT` | `50051` | gRPC API |
| `JSONRPC_PORT` | `8545` | JSON-RPC (`/jsonrpc`, eth-compatible) |
| `P2P_PORT` | `18888` | P2P TCP + UDP |
| `KAFKA_PORT` | `9092` | Kafka host port (external clients) |
| `KAFKA_INTERNAL_PORT` | `19092` | Kafka internal port (tron → kafka) |
| `KAFKA_ADVERTISED_HOST` | `localhost` | Hostname advertised to external Kafka clients |
| `KAFKA_LOG_RETENTION_MS` | `604800000` | Message retention (7 days) |

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
| `EVENT_PLUGIN_ENABLED` | `true` | Sets `event.subscribe.enable` (4.8.2 replaces deprecated `--es`) |
| `EVENT_START_SYNC_BLOCK_NUM` | `0` | >0 = sync historical events from block height (framework V2.0) |

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

To create a lite snapshot from a FullNode, use the [Toolkit `db lite`](https://developers.tron.network/docs/node-maintenance-tool-toolkit) command.

### Mainnet example

```env
NETWORK=mainnet
JAVA_TRON_VERSION=GreatVoyage-v4.8.1.1
```

## Config philosophy (java-tron 4.8.2)

Configs in `configs/nile.conf` and `configs/mainnet.conf` are **minimal**: only network-specific values that differ from java-tron built-in defaults.

Per the [official config.conf](https://github.com/tronprotocol/java-tron/blob/develop/framework/src/main/resources/config.conf):

> *"You can customize the configuration for each database. Otherwise, the database settings will use their defaults."*

**Verified**: a minimal Nile config containing only `storage.merkleRoot`, `node.p2p.version`, ports, `seed.node`, and `genesis.block` starts successfully and creates the database — all other settings (LevelDB, gRPC threads, rate limits, etc.) use java-tron 4.8.2 defaults.

What we keep in config files (cannot be defaulted):

| Section | Why required |
|---|---|
| `storage.merkleRoot` (Nile) | Network-specific data integrity check |
| `node.p2p.version` | Distinguishes Mainnet (`11111`) vs Nile (`201910292`) |
| Ports | Overridden at runtime via env vars |
| `seed.node` / `genesis.block` | Network identity — no sensible default |
| `block` / `committee` (Nile) | Testnet-specific consensus parameters |
| `event.subscribe` | Kafka plugin path, server, topics |

What we omit (java-tron defaults apply):

- `net.type` — deprecated in 4.8.2, no effect
- LevelDB tuning (`default`/`defaultM`/`defaultL`) — commented out in official config; enable via TIP-343 if sync is slow
- gRPC thread count, flow control, rate limiter — all have documented defaults
- Prometheus metrics — disabled by default (`node.metrics.prometheus.enable = false`)

## Performance notes

- **JVM**: Oracle JDK 8 (x86_64) + CMS GC + tcmalloc (`LD_PRELOAD`), per [TRON deployment guide](https://developers.tron.network/docs/deploy-the-fullnode-or-supernode).
- **ulimits**: `nofile=65535` in compose (needed if you enable LevelDB `maxOpenFiles` tuning).
- **Event plugin**: Kafka `release_v3.0.0` (JDK 8), framework V2.0 (`event.subscribe.version = 1`).

Hardware: Mainnet 16+ cores, 32GB+ RAM, SSD 2.5TB+. Nile 8+ cores, 16GB+ RAM, 200GB+ SSD.

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
- `gc.log*` — GC logs

Kafka data lives at `KAFKA_DATA_PATH` (default `./data/kafka`).

The `data/` directory is gitignored — do not commit blockchain or Kafka data to the repo.

## Stopping safely

```bash
docker compose stop tron   # SIGTERM, 5 min grace for LevelDB
```

Never `kill -9` the node.
