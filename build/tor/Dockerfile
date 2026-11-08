# Pinned to a named minor version by digest (#135, #373). The digest is authoritative; the tag
# names the Alpine minor line (3.24) so Dependabot's patch-update policy has a real version to track.
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache --upgrade libcrypto3 libssl3 musl musl-utils tor netcat-openbsd

# Copy the Tor config TEMPLATE + the entrypoint that renders it: the bridge subnet prefix is
# substituted at container start (#180). The rendered torrc lands in /tmp (the unprivileged 'tor'
# user can't write /etc/tor).
COPY torrc.template /etc/tor/torrc.template
COPY entrypoint.sh /usr/local/bin/tor-entrypoint.sh
RUN chmod +x /usr/local/bin/tor-entrypoint.sh

# Control-port bootstrap healthcheck (see docker-compose.yml healthcheck)
COPY healthcheck.sh /usr/local/bin/tor-healthcheck.sh
RUN chmod +x /usr/local/bin/tor-healthcheck.sh
COPY control-signal.sh /usr/local/bin/tor-control-signal.sh
RUN chmod +x /usr/local/bin/tor-control-signal.sh

COPY recovery-diagnose.sh /usr/local/bin/tor-recovery-diagnose.sh
RUN chmod +x /usr/local/bin/tor-recovery-diagnose.sh

# Create the data directory and ensure the 'tor' user has ownership
# This is critical because we switch to a non-root user below
RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor

# Switch to the non-root 'tor' user for enhanced security
USER tor

# Render torrc from the template (subnet-prefix substitution), then exec Tor — see entrypoint.sh.
ENTRYPOINT ["/usr/local/bin/tor-entrypoint.sh"]
