# Pinned by digest (#135) so the ubuntu:24.04 tag can't be silently re-pointed.
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

RUN for attempt in 1 2 3; do apt-get update && break || { [ "$attempt" = 3 ] && exit 1; sleep "$((attempt * 5))"; }; done && apt-get install -y \
    bzip2 ca-certificates curl gettext-base jq \
    && rm -rf /var/lib/apt/lists/*

# Define Monero version and SHA256 hash for binary verification
# Refer to https://www.getmonero.org/downloads/hashes.txt for validation
ARG MONERO_VERSION=v0.18.5.1
ARG MONERO_HASH=22a7dda7b0cb699fdd6b7674c3b4a4465b337cc98a54983523b759e1e7cc9958

# Download, verify integrity, and install the Monero daemon (monerod) plus monero-wallet-rpc.
# monero-wallet-rpc ships in the SAME CLI tarball (already verified by the hash above), so the
# view-only payout-confirmation wallet (#381) reuses this image with no new download or pin.
COPY download.sh /usr/local/bin/download-monero
RUN sh /usr/local/bin/download-monero "${MONERO_HASH}" 300 monero.tar.bz2 \
    "https://downloads.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2" \
    "https://dlsrc.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2" \
    && tar xvjf monero.tar.bz2 \
    && mv monero-*-linux-gnu-*/monerod /usr/local/bin/monerod \
    && mv monero-*-linux-gnu-*/monero-wallet-rpc /usr/local/bin/monero-wallet-rpc \
    && chmod +x /usr/local/bin/monerod /usr/local/bin/monero-wallet-rpc \
    && rm -rf monero*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

COPY wallet-entrypoint.sh /usr/local/bin/wallet-entrypoint.sh
COPY wallet-healthcheck.sh /usr/local/bin/wallet-healthcheck.sh
RUN chmod 755 /usr/local/bin/wallet-entrypoint.sh /usr/local/bin/wallet-healthcheck.sh

COPY healthcheck.sh /usr/local/bin/monerod-healthcheck.sh
RUN chmod 755 /usr/local/bin/monerod-healthcheck.sh

COPY peers.sh /usr/local/bin/monerod-peers.sh
RUN chmod 755 /usr/local/bin/monerod-peers.sh

RUN install -d -o ubuntu -g ubuntu /home/ubuntu /home/ubuntu/wallets
WORKDIR /home/ubuntu
USER ubuntu
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
