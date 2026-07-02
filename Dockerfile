# syntax=docker/dockerfile:1
#
# java-tron FullNode image — x86_64 (amd64), Oracle JDK 8 (TRON's supported JDK on x64).
# Includes the Kafka event plugin (release_v3.0.0, JDK 8 build) and tcmalloc.
#
# Build args:
#   NETWORK            nile | mainnet          (default: nile)
#   JAVA_TRON_VERSION  release tag to download (default: latest Nile tag)
#   FULLNODE_JAR_URL   optional direct URL overriding the computed one

FROM ubuntu:24.04 AS jdk8
ENV JDK_TAR=jdk-8u202-linux-x64.tar.gz \
    JDK_MD5=0029351f7a946f6c05b582100c7d45b7
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    wget -q -P /usr/local "https://github.com/frekele/oracle-java/releases/download/8u202-b08/${JDK_TAR}" && \
    echo "${JDK_MD5} /usr/local/${JDK_TAR}" | md5sum -c && \
    tar -zxf "/usr/local/${JDK_TAR}" -C /usr/local && \
    rm "/usr/local/${JDK_TAR}"

FROM jdk8 AS build
ARG NETWORK=nile
ARG JAVA_TRON_VERSION=GreatVoyage-Nile-v4.8.2-PQ1-build1
ARG FULLNODE_JAR_URL=

WORKDIR /src
RUN set -e; \
    if [ -n "$FULLNODE_JAR_URL" ]; then \
        URL="$FULLNODE_JAR_URL"; \
    elif [ "$NETWORK" = "nile" ]; then \
        TAG="$(echo "$JAVA_TRON_VERSION" | sed 's/.*-v//' | tr '[:upper:]' '[:lower:]')"; \
        URL="https://github.com/tron-nile-testnet/nile-testnet/releases/download/${JAVA_TRON_VERSION}/FullNode-Nile-x64-${TAG}.jar"; \
    else \
        URL="https://github.com/tronprotocol/java-tron/releases/download/${JAVA_TRON_VERSION}/FullNode.jar"; \
    fi; \
    echo "Downloading FullNode.jar: $URL"; \
    wget -q "$URL" -O /src/FullNode.jar

# Sanity check: Kafka plugin must be the release_v3.0.0 (Jackson) build, not master (fastjson)
COPY ./plugins/plugin-kafka-3.0.0-jdk8.zip /src/plugin-kafka.zip
RUN apt-get update && apt-get install -y --no-install-recommends unzip binutils && \
    rm -rf /var/lib/apt/lists/* && \
    unzip -l /src/plugin-kafka.zip | grep -q jackson-databind && \
    ! unzip -p /src/plugin-kafka.zip classes/org/tron/eventplugin/KafkaSenderImpl.class | strings | grep -q fastjson

FROM ubuntu:24.04 AS runtime
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgoogle-perftools4 curl && \
    rm -rf /var/lib/apt/lists/*

COPY --from=jdk8 /usr/local/jdk1.8.0_202/jre /usr/local/jre
ENV JAVA_HOME=/usr/local/jre \
    PATH=/usr/local/jre/bin:$PATH \
    LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4 \
    TCMALLOC_RELEASE_RATE=10

COPY --from=build /src/FullNode.jar /usr/local/tron/FullNode.jar
COPY --from=build /src/plugin-kafka.zip /usr/local/tron/plugins/plugin-kafka.zip
COPY ./configs/nile.conf ./configs/mainnet.conf /etc/tron/
COPY ./docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 8090 HTTP API | 8545 JSON-RPC | 50051 gRPC | 18888 P2P | 9527 Prometheus
EXPOSE 8090 8545 50051 18888 18888/udp 9527

WORKDIR /data
VOLUME /data

ENTRYPOINT ["docker-entrypoint.sh"]
