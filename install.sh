#!/usr/bin/env bash
# Pithead curl installer (#77 phase 1) — thin by design: check the host, fetch and verify the
# release bundle, delegate to `pithead setup`. All provisioning logic stays in the bundle, so
# what this script does is auditable in one screen:
#
#   curl -fsSL https://raw.githubusercontent.com/p2pool-starter-stack/pithead/main/install.sh | bash
#
# Env overrides: PITHEAD_VERSION=vX.Y.Z (default: latest release), PITHEAD_DIR=<install dir>
# (default: ./pithead-<version>), PITHEAD_ALLOW_ANY_DISTRO=1 to skip the apt-family check.
set -euo pipefail

REPO="p2pool-starter-stack/pithead"
COSIGN_PIN_URL="https://github.com/sigstore/cosign/releases/download/v2.6.3/cosign-linux-amd64"
COSIGN_PIN_SHA256="7c78a7f2efc00088bd788a758db6e0928e79f3e0eb83eb5d3c499ed98da4c4f4"
fail() {
    echo "[install] ERROR: $*" >&2
    exit 1
}
note() { echo "[install] $*"; }

# --- Host checks. amd64 + AVX2 are hard requirements (xmrig-proxy has no arm64 build; RandomX
# prep needs AVX2) — fail here, not hours into a sync.
[ "$(uname -s)" = "Linux" ] || fail "Pithead runs on Linux (found $(uname -s)). See docs/getting-started.md."
[ "$(uname -m)" = "x86_64" ] || fail "Pithead is x86_64-only (found $(uname -m)) — xmrig-proxy has no arm64 build."
# AVX2 is performance, not a requirement — RandomX runs without it, just slower, and `doctor`
# treats it the same way. A hard gate here would turn away exactly the repurposed hardware this
# stack is often deployed on (the project's own release box is a pre-AVX Westmere Xeon).
grep -qw avx2 /proc/cpuinfo ||
    note "This CPU lacks AVX2 — RandomX will run, but slower. Proceeding; 'pithead doctor' repeats this."
if [ "${PITHEAD_ALLOW_ANY_DISTRO:-0}" != "1" ]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || fail "Cannot read /etc/os-release. Set PITHEAD_ALLOW_ANY_DISTRO=1 to proceed anyway."
    case "${ID:-} ${ID_LIKE:-}" in
    *debian* | *ubuntu*) ;;
    *) fail "'./pithead setup' installs dependencies with apt (found ${PRETTY_NAME:-unknown}). Set PITHEAD_ALLOW_ANY_DISTRO=1 and install docker/jq/openssl yourself." ;;
    esac
fi
for dep in curl tar sha256sum; do
    command -v "$dep" >/dev/null 2>&1 || fail "'$dep' is required to install. apt install $dep, then re-run."
done

TAG="${PITHEAD_VERSION:-}"
if [ -z "$TAG" ]; then
    TAG=$(curl -fsSL --proto =https --proto-redir =https "https://api.github.com/repos/$REPO/releases/latest" |
        grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    [ -n "$TAG" ] || fail "Could not resolve the latest release tag from the GitHub API."
fi
DIR="${PITHEAD_DIR:-$PWD/pithead-$TAG}"
[ -e "$DIR" ] && fail "$DIR already exists — pick another PITHEAD_DIR or remove it."
note "Installing Pithead $TAG into $DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --proto =https --proto-redir =https -o "$TMP/pithead.tar.gz" "https://github.com/$REPO/releases/download/$TAG/pithead.tar.gz" ||
    fail "Bundle download failed for $TAG."
if curl -fsSL --proto =https --proto-redir =https -o "$TMP/ingredients.md" "https://github.com/$REPO/releases/download/$TAG/ingredients-$TAG.md" 2>/dev/null; then
    WANT=$(grep -m1 -oE 'bundle sha256: `[a-f0-9]{64}`' "$TMP/ingredients.md" | grep -oE '[a-f0-9]{64}' || true)
    if [ -n "$WANT" ]; then
        GOT=$(sha256sum "$TMP/pithead.tar.gz" | cut -d' ' -f1)
        [ "$GOT" = "$WANT" ] || fail "Bundle sha256 mismatch: manifest $WANT, downloaded $GOT. Refusing to install."
        note "Bundle sha256 verified against the release manifest."
    else
        note "Release manifest carries no bundle sha256 (pre-v1.15 release) — trusting the HTTPS download."
    fi
else
    note "No release manifest found — trusting the HTTPS download."
fi

signed_release() {
    [[ $1 =~ ^v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$ ]] || return 0
    ((10#${BASH_REMATCH[1]} * 1000000000000 + 10#${BASH_REMATCH[2]} * 1000000 + 10#${BASH_REMATCH[3]} >= 1000018000001))
}
if curl -fsSL --proto =https --proto-redir =https -o "$TMP/pithead.tar.gz.sig" "https://github.com/$REPO/releases/download/$TAG/pithead.tar.gz.sig" 2>/dev/null; then
    curl -fsSL --proto =https --proto-redir =https -o "$TMP/cosign.pub" "https://raw.githubusercontent.com/$REPO/main/cosign.pub" ||
        fail "The release carries a signature but the pinned key could not be fetched from the repo."
    COSIGN=$(command -v cosign || true)
    if [ -z "$COSIGN" ]; then
        note "cosign not installed — fetching the pinned cosign v2.6.3 into a temporary folder to check the signature."
        curl -fsSL --proto =https --proto-redir =https -o "$TMP/cosign" "$COSIGN_PIN_URL" ||
            fail "Could not download the pinned cosign to check the bundle signature. Install cosign, or run the installer again."
        [ "$(sha256sum "$TMP/cosign" | cut -d' ' -f1)" = "$COSIGN_PIN_SHA256" ] ||
            fail "The downloaded cosign does not match its pinned sha256. Refusing to install."
        chmod 700 "$TMP/cosign"
        COSIGN="$TMP/cosign"
        "$COSIGN" version >/dev/null 2>&1 ||
            fail "The downloaded cosign could not run (is the temporary folder mounted noexec?). Install cosign, or set TMPDIR to a folder that allows running programs."
    fi
    "$COSIGN" verify-blob --key "$TMP/cosign.pub" --signature "$TMP/pithead.tar.gz.sig" \
        --insecure-ignore-tlog=true "$TMP/pithead.tar.gz" >/dev/null 2>&1 ||
        fail "Bundle signature verification FAILED — the download does not match the release key. Refusing to install."
    note "Bundle signature verified (cosign, repo-pinned key)."
else
    signed_release "$TAG" && fail "Release $TAG should carry a signature, but the signature could not be downloaded. Refusing to install. If this was a network error, run the installer again."
    note "No bundle signature on this release (pre-signing era) — sha256/HTTPS are the trust anchors."
fi

mkdir -p "$DIR"
tar -xzf "$TMP/pithead.tar.gz" --strip-components=1 -C "$DIR"
[ -x "$DIR/pithead" ] || fail "Extracted bundle has no pithead executable — corrupt download?"
note "Extracted. Handing off to './pithead setup' (interactive)."
cd "$DIR"
if [ ! -t 0 ]; then
    { exec <"${PITHEAD_TTY:-/dev/tty}"; } 2>/dev/null || fail "Setup is interactive but no terminal is available (stdin is a pipe and /dev/tty cannot be opened). Run: cd $DIR && ./pithead setup"
fi
exec ./pithead setup "$@"
