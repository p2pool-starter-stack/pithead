# Committed-head Linux and artifact verification

This verification uses commit
`32d11cd4e18285e8067a7d46d4718ec02d3739ee` on 2026-11-02. It adds no native
slice or application change. The [merge-readiness results](results-merge-readiness.md)
retain the dashboard coverage, default patch gate, GNU-first lint, Go CI and G7
evidence incorporated in that commit.

## Runtime image

The existing production target and supplementary image test run against the
clean committed working tree:

```bash
docker build --target go-production --build-context pithead-go=go \
  -t pithead-dashboard:go-3811-32d11cd4 dashboard
python3 tests/go-parity/test_go_image.py pithead-dashboard:go-3811-32d11cd4
```

The host's default Buildx configuration cannot write its activity directory.
That attempt exits 1 before a usable image is produced. A disposable builder
with private configuration completes the same production target and named
context, then loads it with `docker buildx build --load`. The image test exits 0.
The tested Linux ARM64 image ID is
`sha256:ae336ed52329508f9cac27032af344ac51ae8a01acf987784a01e07af49e0aad`.

| Selection | Database | Result |
|---|---|---|
| Python | Existing | Passed; sixteen tables |
| Go | Existing | Passed; sixteen tables |
| Go | Legacy | Passed; migration preserves data, sixteen tables |
| Go | Corrupt | Passed; quarantine and replacement, sixteen tables |

These cases enforce the selected PID-1 executable, state/miner HTTP contracts,
graceful shutdown and native Go SQLite ownership by making Python SQLite opens
fatal in the Go containers. All three Compose selector-independence cases pass.
The containers use no network or published ports, a read-only root and temporary
data. This is a Linux ARM64 local image result; the test is a porter addition.
It does not establish a published image, appliance boot or live fleet result.

## Image vulnerability gate

Pinned Trivy 0.73.0 scans that same ARM64 image with CI's `vuln` scanner,
`HIGH,CRITICAL` severity, `--ignore-unfixed`, `.config/trivyignore` and exit code 1
on findings. Its fresh private database was downloaded at
`2026-11-02T17:22:29.379141Z`, with database update time
`2026-11-02T13:15:56.44112656Z`. The scan exits 0 and reports no fixable
HIGH/CRITICAL findings, including the packaged Go dashboard. This does not
establish an AMD64 or published-image scan.

## Native artifacts

```bash
docker buildx build --platform linux/amd64 --file go/Dockerfile \
  --target artifacts --output type=local,dest=.go-cache/shipping-real-native go
```

The disposable builder exports both statically linked x86-64 ELF commands from
the digest-pinned Go 1.26.10 toolchain. Module verification passes. This proves
Linux AMD64 compilation and export; the commands are not executed on AMD64.
The release publish workflow and complete signed bundle are not run.

| Command | Bytes | SHA-256 |
|---|---|---|
| `pithead` | 5211058 | `8535eb443aac7d41f8643e149f97b8da7b4772dea75dc36d696b968c22ddc58b` |
| `dashboard` | 18701434 | `992223b34151b9f193a48a702519167066e71625ea54c194b4314ecfdae84e34` |

## Linux oracle setup failures

The first non-root reference stack attempt completes the five shell blocks with
8043 passing and ten failing assertions. It does not reach the remaining
standalone targets and is not a full gate pass:

| Block | Passed | Failed |
|---|---|---|
| 1 | 2507 | 4 |
| 2 | 1900 | 2 |
| 3 | 329 | 0 |
| 4 | 277 | 0 |
| 5 | 3030 | 4 |

The runner lacks Go, `envsubst`, `sudo`, `iptables` and `systemctl`. Two bridge
address assertions also fail: network isolation alone does not repair them;
the runner's `awk` lacks the interval-expression behavior used by the filter.
The corrected runner requires GNU awk along with the other GNU tools. The catalogue
failure omits `container-engine-boot` and `control-units`, whose systemd-dependent
registration paths match the frozen reference. These are runner deficiencies;
no test, fixture or application source is changed to repair them.

The runner script also changed through a live bind while executing, corrupting
its final wrapper exit to 127. That attempt supplies no accepted overall verdict.
Subsequent attempts copy an immutable script into the disposable filesystem,
prepare tools and locked dependencies before network disconnection, and execute
the original suite as a non-root user. A first Go-selected setup also stops
before tests because its image lacks the Go compiler.

With the tools corrected, the original Caddy bridge fragment passes 14
assertions, the Monero entrypoint fragment passes two, the doctor appliance
fragment passes seventy, and the real root/page boundary assertion passes.
The Go module-raise self-test also passes. These are runner preflight checks,
not a full Go-selected suite verdict.

Using real installed `systemctl` and `iptables`, the unchanged
`tests/stack/lifecycle/pull-policy.sh` still reports ten passes and three failures.
The frozen starting commit `a73ffced33800de9435779a9cabef53864455acb` reproduces
the same result in the same non-root, network-isolated runner. Each failure
receives `lan-guard:boot-unit-left` and `egress-apply:iptables-insert-failed`
warnings because this container has neither a working systemd daemon nor firewall
privileges. Temporary global success fakes were removed; no fake-backed result
is accepted as normal-gate proof.
Full Linux and privileged parity remain unproven; the preflight and failed
attempts do not replace the normal gate.

## Wizard-spool prerequisite control

An ad hoc run of `tests/stack/appliance/test-appliance-wizard-spool.sh` initially
reports 101 passes and three restore failures. It omitted `build_val_sandbox`,
which supplies the required wallet fixture. A deliberate empty-wallet control
reproduces the same failures and byte-identical four-helper dispatch trace.
The preceding missing-`VERSION` diagnostic is benign in both selections.
No production or test change is indicated by that setup failure.

With the original prerequisites, an immutable runner sources the unchanged
fragment in a network-isolated Linux ARM64 container as UID 1000:

```bash
make go-build pithead
env BASH_ENV="$PWD/tests/go-parity/env.sh" \
  PITHEAD_IMPL=go PITHEAD_GO_BINARY="$PWD/go/bin/pithead" bash -c '
set -uo pipefail
source tests/stack/lib.sh
build_val_sandbox
source tests/stack/appliance/test-appliance-wizard-spool.sh
test "$FAIL" -eq 0
'
```

The reference arm uses the same runner without the Go adapter/selection.

| Selection | Passed | Failed | Go helper dispatches |
|---|---|---|---|
| Reference | 104 | 0 | 0 |
| Go | 104 | 0 | 63 |

Both exit 0. The counting run additionally installs an exec-preserving spy and
uses a non-`PITHEAD_` log variable so harness cleanup cannot erase it. It records dispatches, including two wallet
helper calls; it does not measure the 0/1/125 outcome distribution. The 63 calls
must not be described as 63 native successes. This proves selected fragment
parity with observable handoffs; existing native/fallback guards remain separate.
The earlier reported count of 84 was an arithmetic error; the final trace sums
to 63.

The original fragment SHA-256 is
`550e8b3190c2140ad9f11337958f4a628e940ffce60d5e16595bf1ebd04b230a`;
the immutable runner SHA-256 is
`e0c37376cb400228ff9f7774d613a1e371300f8b6f4629e4cfb2381692595198`.
No existing test or fixture differs from the frozen starting commit.

## Private evidence

Raw logs and exit records remain under the ignored `.go-cache/logs/` directory.
They are retained locally, not published artifacts.

| Evidence file | SHA-256 |
|---|---|
| `shipping-image-build-32d11cd4.log` (default builder failure) | `53a20f4b9d58358bbbb1b273857f6703ff723e89f8b001e35733f77b0fbae94b` |
| `shipping-image-build-32d11cd4-disposable.log` | `a929b1334fa53a882439d0c61adc1a423c06558570e15d0c3daaed237b7d7760` |
| `shipping-image-build-32d11cd4-load.log` | `670e9d7a6e6b9fe1285b0d999d0be99eb2ce905b626d7fa48bb14a47d13577d5` |
| `shipping-image-smoke-32d11cd4.log` | `d60c7ceab020d4af63101b1f4d49edb3d97f1178aa1a63e18d3ddd7db17c908d` |
| `shipping-native-amd64-32d11cd4.log` | `0c078f89d01113bc9662baa9d689dedcb53a3dcbde8020fb83f2ddfaa22623e9` |
| `shipping-exit-metadata-32d11cd4.txt` | `fa728dd103659c5248ac91910a7233b810a14774c9088bc203f6a0da30f01425` |
| `trivy-dashboard-32d11cd4-recheck.log` | `687e2c038c669881154aa4679fd1fca18a185cafc90fd948bf83b2cdcd3abbee` |
| `trivy-verdict-32d11cd4.txt` | `99f9990581ee890e33c60026c6c9515b919e9c1de899b23b4ed6c39377bec1df` |
| `wizard-spool-final.meta` | `630df3586b866944a1714987149a9ecb89760b9a6351b23c7231a1b236952c9b` |
| `wizard-spool-reference-final.log` | `6ee04b4156592d304186fb761c63383580aab78045f2817af1193be99f3300c5` |
| `wizard-spool-go-final.log` | `1ff39dd07417bf816d462c86268d28be888707b1e3791b03be2aea3ab77a8cbd` |
| `wizard-spool-go-final-calls.log` | `1fa69b5b02d2a6784bd7650179f04c8f6ba987dc28b9e73f9b0cb3cbfe9ad11f` |
| `stack-linux-arm64-pull-policy-base.log` | `e19a85a04aea8dee37a9c5c5031ed94a3971822a2d5fd8e0ef196cd6ef44ff36` |
| `stack-linux-arm64-pull-policy-base.meta` | `87e398b77d58ca3ffc6eb51fb069e1b7d2c9d6caaa628857bc61655bdd4cab67` |

## Fleet admission boundary

Read-only checks at 17:11Z find the pushed branch still at
`b59724b35c8c9c33c4ca15e161ba2299b482c312`. The bench submission contract
requires the requested full commit to be pushed. No job is submitted for the
unavailable newer commit, and no old-head result is attributed to it.

The live tier catalogue's `tier4-e2e` options forbid unknown properties and
contain no CLI or dashboard implementation selector. A normal targeted job
would therefore need explicit native-selection evidence in its returned logs
before it could establish native runtime parity. Reading service health or
capabilities is not a tier pass. No live stack or fleet configuration is changed.
