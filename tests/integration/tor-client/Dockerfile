# Independent Tor client for black-box onion-reachability tests (tier-4).
#
# Shares NOTHING with the stack: its own tor daemon, its own circuits, its own image. It reaches the
# stack's published onion over the REAL Tor network exactly as a remote user's Tor Browser would —
# so a green result proves the whole inbound path (tor hidden service -> Caddy -> client-auth ->
# dashboard) works from outside the trust boundary, using none of the stack's own tooling.
#
# Base pinned by digest (supply-chain policy, #282). Not a release image — built on the bench by the
# tier-4 harness, never pushed.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# tor: the client daemon. curl: speaks SOCKS5 natively (--socks5-hostname resolves the .onion
# through Tor). ca-certificates: validate the onion's HTTPS chain when we don't pass -k.
# --upgrade names the base's own openssl libs so they follow the distro's security repo, exactly as
# build/tor/Dockerfile has since #1438: a digest-pinned base can lag a published fix until upstream
# rebuilds the image. 3.21 was unaffected; this base carries openssl 3.5.7-r0 and CVE-2026-14456 is
# fixed in 3.5.8-r0, which reds the test-image CVE gate. Measured: 2 HIGH without this line, 0 with.
RUN apk add --no-cache --upgrade libcrypto3 libssl3 tor curl ca-certificates

COPY probe.sh /usr/local/bin/probe.sh
RUN chmod 0755 /usr/local/bin/probe.sh

# Drop privileges — the probe needs no root (tor runs fine as an unprivileged user with a tmpdir).
USER tor
ENTRYPOINT ["/usr/local/bin/probe.sh"]
