# syntax=docker/dockerfile:1
#
# java-tron FullNode image — x86_64 (amd64), Oracle JDK 8 (TRON's supported JDK on x64).
# Includes the Kafka event plugin (release_v3.0.0, JDK 8 build), Toolkit.jar and tcmalloc.
# Every downloaded artifact is checked (SHA-256 pin + GPG signature) before it is used.
#
# Build args:
#   NETWORK            nile | mainnet          (default: nile)
#   JAVA_TRON_VERSION  release tag to download (default: latest Nile tag)
#   FULLNODE_SHA256    SHA-256 of that FullNode jar, from the release page ("skip" = no pin)
#   FULLNODE_JAR_URL   optional direct URL overriding the computed one
#   VERIFY_GPG         true | false            (default: true; needs <jar url>.sig)
#   TOOLKIT_VERSION    java-tron release tag for Toolkit.jar ("" = do not include it)
#   JDK_URL            where to fetch the JDK tarball (point it at your own mirror if you keep one)

FROM ubuntu:24.04 AS jdk8
ARG JDK_URL=https://github.com/frekele/oracle-java/releases/download/8u202-b08/jdk-8u202-linux-x64.tar.gz
ARG JDK_SHA256=9a5c32411a6a06e22b69c495b7975034409fa1652d03aeb8eb5b6f59fd4594e0
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    wget -q "${JDK_URL}" -O /tmp/jdk.tar.gz && \
    echo "${JDK_SHA256}  /tmp/jdk.tar.gz" | sha256sum -c - && \
    tar -zxf /tmp/jdk.tar.gz -C /usr/local && \
    rm /tmp/jdk.tar.gz

FROM jdk8 AS build
RUN apt-get update && apt-get install -y --no-install-recommends gnupg unzip binutils && \
    rm -rf /var/lib/apt/lists/*

COPY ./keys/ /src/keys/
COPY ./scripts/fetch-verified.sh /usr/local/bin/fetch-verified.sh
RUN chmod +x /usr/local/bin/fetch-verified.sh

ARG NETWORK=nile
ARG JAVA_TRON_VERSION=GreatVoyage-Nile-v4.8.2.4-PQ1-build1
ARG FULLNODE_SHA256=b62fb08e647b1336749a2da1bfa37447377e26c80fd85540fabea5b2de23dc41
ARG FULLNODE_JAR_URL=
ARG VERIFY_GPG=true

# Release signing keys (primary key fingerprints), as published by each project:
#   mainnet  build@tron.network  https://github.com/tronprotocol/java-tron#integrity-check
#   nile     build@nileex.io     https://github.com/tron-nile-testnet/nile-testnet/releases
ARG TRON_KEY_FPR=07B23298AEA4E006BD9A42DE785FB96D2C7C3CA5
ARG NILE_KEY_FPR=BBA2FC19D5F0B54AB1EE072BCA92A5501765E1EC

WORKDIR /out
RUN set -e; \
    if [ "$NETWORK" = "nile" ]; then \
        TAG="$(echo "$JAVA_TRON_VERSION" | sed 's/.*-v//' | tr '[:upper:]' '[:lower:]')"; \
        URL="https://github.com/tron-nile-testnet/nile-testnet/releases/download/${JAVA_TRON_VERSION}/FullNode-Nile-x64-${TAG}.jar"; \
        KEY=/src/keys/nile-release.asc; FPR="$NILE_KEY_FPR"; \
    else \
        URL="https://github.com/tronprotocol/java-tron/releases/download/${JAVA_TRON_VERSION}/FullNode.jar"; \
        KEY=/src/keys/tron-release.asc; FPR="$TRON_KEY_FPR"; \
    fi; \
    [ -z "$FULLNODE_JAR_URL" ] || URL="$FULLNODE_JAR_URL"; \
    if [ "$VERIFY_GPG" = "true" ]; then \
        fetch-verified.sh "$URL" /out/FullNode.jar "$FULLNODE_SHA256" "$KEY" "$FPR"; \
    else \
        echo "WARNING: GPG verification disabled (VERIFY_GPG=$VERIFY_GPG)" >&2; \
        fetch-verified.sh "$URL" /out/FullNode.jar "$FULLNODE_SHA256"; \
    fi

# Toolkit.jar (db lite / db archive / db convert ...). Published only with mainnet releases;
# it works on the database of either network.
ARG TOOLKIT_VERSION=GreatVoyage-v4.8.2.4
ARG TOOLKIT_SHA256=d1da524e974a44e44a99c014fdd44bdc06d0b2c8f00794a6886e62ab15d39971
RUN set -e; \
    if [ -n "$TOOLKIT_VERSION" ]; then \
        fetch-verified.sh \
            "https://github.com/tronprotocol/java-tron/releases/download/${TOOLKIT_VERSION}/Toolkit.jar" \
            /out/Toolkit.jar "$TOOLKIT_SHA256" /src/keys/tron-release.asc "$TRON_KEY_FPR"; \
    fi

# Kafka event plugin: built from tronprotocol/event-plugin release_v3.0.0 (upstream publishes no
# binaries). Pin the committed file and check it is the Jackson build, not master (fastjson).
ARG PLUGIN_SHA256=73b7fa6c62ef93e907fb60791f4f3034f21275d2db35b2fcc3c358c9da5fc00e
COPY ./plugins/plugin-kafka-3.0.0-jdk8.zip /out/plugins/plugin-kafka.zip
RUN echo "${PLUGIN_SHA256}  /out/plugins/plugin-kafka.zip" | sha256sum -c - && \
    unzip -l /out/plugins/plugin-kafka.zip | grep -q jackson-databind && \
    ! unzip -p /out/plugins/plugin-kafka.zip classes/org/tron/eventplugin/KafkaSenderImpl.class | strings | grep -q fastjson

FROM ubuntu:24.04 AS runtime
ARG TRON_UID=10001
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgoogle-perftools4 curl && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -g "${TRON_UID}" tron && \
    useradd -u "${TRON_UID}" -g tron -M -d /data -s /usr/sbin/nologin tron

COPY --from=jdk8 /usr/local/jdk1.8.0_202/jre /usr/local/jre
ENV JAVA_HOME=/usr/local/jre \
    PATH=/usr/local/jre/bin:$PATH \
    LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4 \
    TCMALLOC_RELEASE_RATE=10

COPY --from=build /out/ /usr/local/tron/
COPY ./configs/nile.conf ./configs/mainnet.conf /etc/tron/
COPY ./docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY ./scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
# java-tron unpacks the plugin zip next to it at startup, so that directory must be writable.
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh && \
    chown -R tron:tron /usr/local/tron/plugins

ARG JAVA_TRON_VERSION=GreatVoyage-Nile-v4.8.2.4-PQ1-build1
LABEL org.opencontainers.image.title="docker-java-tron" \
      org.opencontainers.image.version="${JAVA_TRON_VERSION}"

# 8090 HTTP API | 8545 JSON-RPC | 50051 gRPC | 18888 P2P | 9527 Prometheus
EXPOSE 8090 8545 50051 18888 18888/udp 9527

WORKDIR /data
VOLUME /data

ENTRYPOINT ["docker-entrypoint.sh"]
