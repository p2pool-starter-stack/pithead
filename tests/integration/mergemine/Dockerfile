# Merge-mining submission fixture (#2586): Tari's own validator plus a recording Tari node.
# Test-only; never part of a release or an appliance image.
#
# Two targets. `probe` (first, so `--target probe` never reaches the Rust stage) is Python and grpcio
# only: the recording node and the LocalNet read-back client for the acceptance leg (#2589). The
# default last target adds the validator fixture for the fork leg (#2586).
#
# The fixture is compiled as a member of Tari's workspace at the pinned commit, with Tari's own
# dependency script and the mainnet build target, so the checks it runs are the shipped node's code.
# The upstream tree is not modified; the only addition is the fixture crate as a workspace member.
# Pinned by digest (#135).
FROM debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0 AS probe
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libsqlite3-0 libssl3t64 python3 python3-grpcio \
    && rm -rf /var/lib/apt/lists/*
COPY fake_tari_node.py localnet_probe.py /usr/local/bin/

FROM rust:1.100.0-trixie@sha256:e84068000361bf3d4a5ba2b7647f62893528b1eb9f847d7a23b493f5ce8ea254 AS builder

# Tari v6.0.0: the tag object e817c0ab… points at this commit.
ARG TARI_COMMIT=97aa59ecfaf70d8334f14e71d8f7afd6bd40e5e3
ARG DEBIAN_FRONTEND=noninteractive
ENV TARI_NETWORK=mainnet TARI_TARGET_NETWORK=mainnet

WORKDIR /tari
RUN git init -q && git remote add origin https://github.com/tari-project/tari \
    && git fetch -q --depth 1 origin "$TARI_COMMIT" && git checkout -q FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$TARI_COMMIT"
RUN apt-get update && sh scripts/install_ubuntu_dependencies.sh && rm -rf /var/lib/apt/lists/*

COPY fixture p2pool_mm_fixture
RUN sed -i 's|^members = \[|members = [\n    "p2pool_mm_fixture",|' Cargo.toml \
    && cargo build --release -p p2pool_mm_fixture \
    && cp target/release/p2pool_mm_fixture /usr/local/bin/ \
    && rm -rf target

FROM probe
COPY --from=builder /usr/local/bin/p2pool_mm_fixture /usr/local/bin/
RUN ! ldd /usr/local/bin/p2pool_mm_fixture | grep 'not found'
