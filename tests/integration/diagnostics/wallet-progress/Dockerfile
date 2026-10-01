ARG RUNTIME_REPOSITORY=pithead-wallet-probe-base
ARG RUNTIME_TAG=job-owned
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3 AS probe-build
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential cmake pkg-config patch \
    libboost-all-dev libssl-dev libzmq3-dev libsodium-dev libunbound-dev libevent-dev \
    libunwind-dev liblzma-dev libreadline-dev libhidapi-dev libusb-1.0-0-dev libudev-dev \
    && rm -rf /var/lib/apt/lists/*
# Ubuntu's static libunbound requires libevent; pinned upstream finds only unbound.
# Exercise that dependency before the expensive source compilation.
RUN printf '#include <unbound.h>\nint main() { ub_ctx_delete(ub_ctx_create()); }\n' \
        | c++ -x c++ - -x none -o /unbound-link-test \
            /usr/lib/"$(gcc -print-multiarch)"/libunbound.a \
            /usr/lib/"$(gcc -print-multiarch)"/libevent.a -lssl -lcrypto -pthread \
    && /unbound-link-test
WORKDIR /source
# v0.18.5.1, including its exact gitlinked dependencies. Never fetch a moving tag.
RUN git init && git remote add origin https://github.com/monero-project/monero.git \
    && git fetch --depth 1 origin 4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5 \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = 4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5 \
    && git submodule update --init --recursive --depth 1
COPY numeric-progress.h probe-test.cpp /probe/
RUN c++ -std=c++11 -Wall -Wextra -Werror -pthread /probe/probe-test.cpp -o /probe/test \
    && /probe/test 2>/probe/actual \
    && printf 'wallet_numeric_progress kind=2 count=3774000\nwallet_numeric_progress kind=3 count=18446744073709551615\n' > /probe/expected \
    && cmp /probe/expected /probe/actual
COPY numeric-progress.patch /probe/
RUN patch --fuzz=0 -p1 < /probe/numeric-progress.patch \
    && cp /probe/numeric-progress.h src/wallet/numeric-progress.h \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSTATIC=ON \
        -DBUILD_TESTS=OFF -DBUILD_GUI_DEPS=OFF -DSTACK_TRACE=OFF -DARCH=default \
        -DUNBOUND_LIBRARIES="/usr/lib/$(gcc -print-multiarch)/libunbound.a;/usr/lib/$(gcc -print-multiarch)/libevent.a" \
    && cmake --build build --target wallet_rpc_server --parallel 2
FROM ${RUNTIME_REPOSITORY}:${RUNTIME_TAG}
COPY --from=probe-build /source/build/bin/monero-wallet-rpc /usr/local/bin/monero-wallet-rpc
# Ubuntu supplies libudev dynamically. Preserve the pinned wallet's HID support.
COPY --from=probe-build /usr/lib/x86_64-linux-gnu/libudev.so.1 /usr/lib/x86_64-linux-gnu/libudev.so.1
# Fail the build for missing runtime libraries; do not deploy an unexecutable probe.
RUN monero-wallet-rpc --version
LABEL org.pithead.wallet-probe.source=4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5
