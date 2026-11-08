# Monero LMDB tools

The **Monero LMDB tools** workflow builds a Linux x86_64 archive of `mdb_copy`
and `mdb_stat` from the LMDB implementation shipped in the supported Monero source.
It does not install tools or prepare a chain snapshot.

## Source and build

The source pin is Monero `v0.18.5.1`, commit
`4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5`. The builder verifies the complete
source archive against SHA-256
`4fdd15401af04e1ce84dcae40c8c114320d1cc9b449db25c0d57efa4b4054881`
before reading its LMDB files. A mismatch with the supported version in
`build/monero/Dockerfile` fails the build. Update both pins together when changing
the supported Monero implementation; a matching version string alone is not
permission to use another source archive.

The workflow runs on Ubuntu 22.04 with GCC and the standard Linux pthread locks.
The binaries link glibc dynamically, with an Ubuntu 22.04 / glibc 2.35 build
baseline; they require the x86_64 glibc loader and compatible runtime libraries.
They do not use the distribution's LMDB library. Provenance records the actual
compiler, linker, build OS, glibc, flags, source-file digests and Pithead source
commit, plus the GitHub runner image version and GCC, cc1, linker and libc file
digests. CI runner package updates can change binary digests; this is a recorded
build, not a claim of byte-for-byte reproducibility across runner revisions.

## Download and verification

Open the successful **Monero LMDB tools** workflow run for the reviewed Pithead
commit. Download its `monero-lmdb-linux-x86_64` artifact. GitHub artifacts expire
after 30 days; run the workflow again for a retained source commit when needed.
The artifact contains a tar archive and its SHA-256 file. In the downloaded directory:

```bash
sha256sum -c monero-lmdb-linux-x86_64.tar.gz.sha256
mkdir verified-lmdb-tools
tar -xzf monero-lmdb-linux-x86_64.tar.gz -C verified-lmdb-tools
cd verified-lmdb-tools
sha256sum -c SHA256SUMS
```

Inspect `provenance.json` for the reviewed Pithead commit and supported Monero
commit. `SHA256SUMS` covers both binaries, the LMDB `LICENSE` and `COPYRIGHT`,
`provenance.json`, `proof.json` and the complete compiled LMDB source files in
`liblmdb/`, including their original copyright and permission notices. The outer digest covers the tar archive;
digests detect changes but do not replace review of the producing workflow and
its source commit.

## Disposable consistency proof

Before uploading, CI compiles a separate writer/reader fixture against the same
verified LMDB sources. It creates a disposable environment with version-2 locks,
1,024 records and a transaction-wide generation. Each record contains 256 words
whose expected values depend on its key and that generation.

While a separate writer commits new generations, the packaged copier makes six
ordinary and six compact copies. The independent reader opens every copy through
LMDB, checks the entry count and every word in one read transaction, and verifies
that its generation falls between independently observed source generations.
The source must advance during the copy series and remain readable after the
writer exits. The packaged `mdb_stat -ef` must read each copy and the active source.
Negative controls reject a committed inconsistent record set and an invalid
database. The workflow checks the ELF architecture, glibc loader and payload
digests, and publishes only after all assertions pass. `proof.json` retains the
observed generations and completed checks.

The pure builder tests run through `make test-tools`. They reject wrong source
digests, symbolic-link source members, unsupported build targets and incomplete
source identities, and check extraction boundaries and checksum coverage.

## Operational boundary

Installation, capacity checks, reservations, source identity, active consumers,
permissions, snapshot custody and capture are separate owner-operated work.
Do not bypass LMDB locks, delete a live lock file or ordinary-file-copy a running
database. A successful disposable proof does not authorize using these tools on
an active service or establish a real-chain snapshot's consistency or suitability.
No service is stopped, restarted or installed by this workflow.
