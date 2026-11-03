# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

# Define XMRig Proxy version and SHA256 hash for binary verification
# Refer to https://github.com/xmrig/xmrig-proxy/releases for validation
ARG XMRIG_PROXY_VERSION=6.26.0
ARG XMRIG_PROXY_HASH=73cceb10be474ba8ce20faddb9d2c6af0cb50bce84e72f7d36a326f7147c01c4

RUN for attempt in 1 2 3; do apt-get update && break || { [ "$attempt" = 3 ] && exit 1; sleep "$((attempt * 5))"; }; done && apt-get install -y \
    wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download, verify integrity, and install the XMRig Proxy binary
RUN wget -O xmrig-proxy.tar.gz https://github.com/xmrig/xmrig-proxy/releases/download/v${XMRIG_PROXY_VERSION}/xmrig-proxy-${XMRIG_PROXY_VERSION}-linux-static-x64.tar.gz \
    && echo "${XMRIG_PROXY_HASH}  xmrig-proxy.tar.gz" | sha256sum -c - \
    && tar xzf xmrig-proxy.tar.gz \
    && mv xmrig-proxy-${XMRIG_PROXY_VERSION}/xmrig-proxy /usr/local/bin/xmrig-proxy \
    && chmod +x /usr/local/bin/xmrig-proxy \
    && rm -rf xmrig-proxy*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

COPY healthcheck.sh /usr/local/bin/xmrig-proxy-healthcheck.sh
RUN chmod 755 /usr/local/bin/xmrig-proxy-healthcheck.sh

RUN install -d -o ubuntu -g ubuntu /home/ubuntu
WORKDIR /home/ubuntu
USER ubuntu
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
