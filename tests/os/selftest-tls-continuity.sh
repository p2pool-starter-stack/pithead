#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/pithead/26-appliance-tls-provisioning.sh
source "${PITHEAD_TLS_SOURCE:-$ROOT/lib/pithead/26-appliance-tls-provisioning.sh}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
appliance_tls_dir() { printf '%s' "$work/tls"; }
appliance_site_names() { printf '%s' "$fixture_names"; }
log() { :; }
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
key_digest() { openssl pkey -in "$work/tls/wizard.key" -pubout -outform DER 2>/dev/null | openssl dgst -sha256; }
fixture_names='fixture.invalid 192.0.2.20 fd00:3414::1 localhost'
original=$(appliance_mint_cert)
original_key=$(key_digest)
[ -n "$original" ] && [ -n "$original_key" ] || fail 'initial certificate and key unreadable'
fixture_names='localhost fd00:3414:0:0:0:0:0:1 192.0.2.20 fixture.invalid'
[ "$(appliance_mint_cert)" = "$original" ] || fail 'reordered canonical SANs rotated the certificate'
fixture_names='fixture.invalid localhost'
[ "$(appliance_mint_cert)" = "$original" ] || fail 'transient address absence rotated the certificate'
fixture_names='fixture.invalid 192.0.2.20 fd00:3414::1 localhost'
[ "$(appliance_mint_cert)" = "$original" ] || fail 'restored settled SANs rotated the certificate'
[ "$(key_digest)" = "$original_key" ] || fail 'restored settled SANs changed the key'
fixture_names="$fixture_names fd00:3414::2"
added=$(appliance_mint_cert)
[ "$added" != "$original" ] || fail 'genuinely new SAN did not rotate the certificate'
case "$(cert_san_string "$work/tls/wizard.crt")" in *IP:fd00:3414:0:0:0:0:0:2*) ;; *) fail 'new SAN is uncovered' ;; esac
[ "$(appliance_mint_cert)" = "$added" ] || fail 'new SAN certificate is unstable'
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/tls/wizard.key" >/dev/null 2>&1
repaired=$(appliance_mint_cert)
[ "$repaired" != "$added" ] || fail 'mismatched key was retained'
[ "$(appliance_mint_cert)" = "$repaired" ] || fail 'repaired pair is unstable'
printf broken >"$work/tls/wizard.crt"
repaired=$(appliance_mint_cert)
[ -n "$repaired" ] && [ "$(appliance_mint_cert)" = "$repaired" ] || fail 'corrupt certificate was retained'
rm "$work/tls/wizard.key"
[ "$(appliance_mint_cert)" != "$repaired" ] || fail 'missing key was retained'
printf 'TLS continuity self-test: PASS\n'
