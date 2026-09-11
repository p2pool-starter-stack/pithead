# Passive flow recorder for the tier-4 batteries (#2059 follow-up). Test scaffolding: built on a
# bench by the harness, never pushed, never shipped. The release bundle (scripts/release/bundle.sh
# make_bundle) and the appliance image (os/rootfs/Dockerfile) are both strict ALLOWLISTS of named
# paths, so nothing under tests/ can reach either — see tests/stack/release for the assertion that
# keeps it that way.
#
# Why a container at all, rather than apt-installing conntrack on the bench: a pinned image is the
# only form of this dependency that our existing supply-chain tooling can actually see. Dependabot
# has no apt ecosystem, and trivy scans images, not bench hosts. As an image this gets base-digest
# bumps (.github/dependabot.yml) and CVE scanning (.github/workflows/ci.yml) like every other
# surface. The same reasoning is why it is pinned by digest rather than by tag.
#
# Base deliberately IDENTICAL to tests/integration/tor-client/Dockerfile: reusing that exact digest
# means one fewer distinct base for dependabot to track and for trivy to scan, and it is already
# vetted in this tree.
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

# conntrack-tools: `conntrack -E` streams connection EVENTS from the kernel. Event mode rather than
# `-L` table polling is the whole point — a table snapshot misses any flow that opens and closes
# between two polls, which is exactly the shape of a DNS leak or a single probe dial, and is the
# blind spot that bench-verify-egress.sh's /proc/net/tcp sampling already has. Nothing is proven by
# a second instrument with the first one's weakness.
#
# tcpdump: not used by the verdict. It is here for the diagnosis step after a red, where the
# question stops being "did something unexpected leave" and becomes "what was in it".
RUN apk add --no-cache conntrack-tools tcpdump

# Runs with --network host and NET_ADMIN/NET_RAW on the bench: conntrack reads the HOST's
# connection table, which is the vantage point the whole design rests on. No USER drop here, unlike
# tor-client — reading the kernel conntrack table needs the capability, and dropping to an
# unprivileged user after it would only be theatre.
ENTRYPOINT ["/usr/sbin/conntrack"]
