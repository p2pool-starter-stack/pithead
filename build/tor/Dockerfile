# Pinned to a named minor version by digest (#135, #373). The digest is authoritative; the tag
# names the Alpine minor line (3.24) so Dependabot's patch-update policy has a real version to track.
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Install Tor plus netcat, which the bootstrap healthcheck needs to talk to the control port.
# Deliberately NOT xxd: the healthcheck's `xxd -p -c 256` is served by busybox's own applet, so
# `apk add xxd` bought nothing but vim's CVE stream (#1372). --no-cache keeps the image small.
# --upgrade names the base's own openssl libs so they follow the distro's security repo: the
# digest-pinned base can lag a published fix until upstream rebuilds the image, and that lag
# closed the CVE gate base-wide on 2026-08-28 (CVE-2026-14456, #1438).
RUN apk add --no-cache --upgrade libcrypto3 libssl3 tor netcat-openbsd

COPY torrc.template /etc/tor/torrc.template
COPY entrypoint.sh /usr/local/bin/tor-entrypoint.sh
RUN chmod 644 /etc/tor/torrc.template && chmod 755 /usr/local/bin/tor-entrypoint.sh

COPY healthcheck.sh /usr/local/bin/tor-healthcheck.sh
RUN chmod 755 /usr/local/bin/tor-healthcheck.sh
COPY control-signal.sh /usr/local/bin/tor-control-signal.sh
RUN chmod 755 /usr/local/bin/tor-control-signal.sh

COPY recovery-diagnose.sh /usr/local/bin/tor-recovery-diagnose.sh
RUN chmod 755 /usr/local/bin/tor-recovery-diagnose.sh

RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor

USER tor

ENTRYPOINT ["/usr/local/bin/tor-entrypoint.sh"]
