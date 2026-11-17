FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache --upgrade libcrypto3 libssl3 musl musl-utils zlib conntrack-tools tcpdump

ENTRYPOINT ["/usr/sbin/conntrack"]
