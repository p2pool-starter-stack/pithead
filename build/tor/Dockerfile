# Pinned to a named minor version by digest (#135, #373). The digest is authoritative; the tag
# names the Alpine minor line (3.24) so Dependabot's patch-update policy has a real version to track.
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

ARG TOR_VERSION=0.4.9.17-r0
RUN apk add --no-cache --upgrade libcrypto3 libssl3 musl musl-utils "tor=${TOR_VERSION}" netcat-openbsd \
    && tor --version | grep -F "Tor version ${TOR_VERSION%-r*}."

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
