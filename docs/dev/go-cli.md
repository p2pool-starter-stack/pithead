# Native CLI

The optional Go binary implements only `help`, `-h`, `--help`, `version`, `-V`,
`--version` and bare `status`. Additional arguments, command chains and every
other command retain the Bash implementation.

Run `make go-build` to build `go/bin/pithead` with Go 1.26.10. The module uses
only the standard library. Release bundles and the appliance rootfs build a
static binary with the digest-pinned Go image, trimmed paths, no VCS metadata
and an empty build ID. DIY installs receive the binary in the release bundle.
Appliance sync copies the binary from the booted rootfs into the writable CLI
tree and removes a stale binary when the booted rootfs omits it. An unsupported
architecture falls back to Bash.

The generated `pithead` remains the public entry point. It tries the native
binary for the exact supported argument shapes and continues in Bash if the
binary is missing, non-executable, broken, or declines the request. Set
`PITHEAD_IMPL=bash` to select Bash explicitly. Sourcing `pithead` still defines
the Bash functions without running either implementation.

The launcher's private child environment requests encoded native exit results
and a completion receipt on a separate descriptor, so a service health failure
is distinguishable from an executable failure. Native diagnostics use the original
stderr descriptor after startup; executable startup errors are suppressed during recovery.
Native status requires Docker, jq, curl, sleep, openssl, open output
descriptors, and either C/POSIX or a verified UTF-8 locale. Unsupported locales
and closed output descriptors stay in Bash. An executable that prints before failing can
leave that output visible before Bash recovers.

Direct `go/bin/pithead` execution uses `exec` for Bash fallback with the original
arguments, environment and descriptors. The public shell entry point also
preserves inherited ignored signals by keeping unsupported invocations in Bash.

Run the Linux checks through the pinned test image:

```bash
make test-container ARGS="make test-go test-go-parity test-go-shipping"
make test-container
make test-container ARGS="make test-patch-coverage COMPARE=origin/develop-v2.1.0"
```

The Go unit gate requires 80% statement coverage and runs the race detector.
Parity compares stdout bytes, stderr bytes and exit status against Bash using
synthetic service fixtures. Tests cover terminal colors, escape bytes, migration
holds, service failures, literal fallback arguments, stdin and inherited FD9.
The dashboard's existing 80% total and 90% patch gates remain in place.

SQLite, the Go dashboard, hybrid adapters, config, render and lifecycle packages
are outside this slice. No live service or appliance boot is exercised by these
fixtures. AMD64 execution, KVM, appliance boot, installed upgrade/recovery and
timing of the shipped launcher still require separate evidence.
