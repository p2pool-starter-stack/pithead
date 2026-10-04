# Derive a public view key from a canonical private scalar, not an Ed25519 seed.
# Python is required when confirmation is enabled: an unavailable validator fails closed.
# The secret travels in the child environment, never argv or output. This is validation,
# not signing; the arithmetic is variable-time and must not be used to spend funds.
payout_public_view_key() { # <monero|tari> <private-view-key>
    PITHEAD_VIEW_SCALAR="$2" python3 - "$1" <<'PYEOF' 2>/dev/null
import os
import sys

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
I = 19681161376707505956807079304988542015446066515923890162744021073123829784752
INV = 54469307008909316920995813868745141605393597292927456921205312896311721017578


def absolute(x):
    x %= P
    return (-x if x & 1 else x) % P


def sqrt_ratio(u, v):
    r = u * pow(v, 3, P) * pow(u * pow(v, 7, P) % P, (P - 5) // 8, P) % P
    check = v * r * r % P
    if check in ((-u) % P, (-u * I) % P):
        r = r * I % P
    return absolute(r)


def add(p, q):
    x, y, z, t = p
    X, Y, Z, T = q
    a = (y - x) * (Y - X) % P
    b = (y + x) * (Y + X) % P
    c = 2 * D * t * T % P
    d = 2 * z * Z % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return e * f % P, g * h % P, f * g % P, e * h % P


secret = bytes.fromhex(os.environ.pop("PITHEAD_VIEW_SCALAR"))
k = int.from_bytes(secret, "little")
if len(secret) != 32 or not 0 < k < L:
    sys.exit(1)
y = 4 * pow(5, P - 2, P) % P
x = sqrt_ratio(y * y - 1, D * y * y + 1)
point = (0, 1, 1, 0)
base = (x, y, 1, x * y % P)
for bit in range(253):
    if (k >> bit) & 1:
        point = add(point, base)
    base = add(base, base)
x, y, z, t = point
if sys.argv[1] == "monero":
    inv_z = pow(z, P - 2, P)
    x, y = x * inv_z % P, y * inv_z % P
    encoded = y | ((x & 1) << 255)
elif sys.argv[1] == "tari":
    # RFC 9496 sections 4.2 and 4.3.2: encode the Edwards representative as Ristretto.
    u1, u2 = (z + y) * (z - y) % P, x * y % P
    invsqrt = sqrt_ratio(1, u1 * u2 * u2 % P)
    den1, den2 = invsqrt * u1 % P, invsqrt * u2 % P
    z_inv = den1 * den2 * t % P
    den = den2
    if (t * z_inv % P) & 1:
        x, y, den = y * I % P, x * I % P, den1 * INV % P
    if (x * z_inv % P) & 1:
        y = -y % P
    encoded = absolute(den * (z - y))
else:
    sys.exit(1)
print(encoded.to_bytes(32, "little").hex())
PYEOF
}

validate_payout_keys() {
    local address_keys derived explicit
    if [ -n "$MONERO_VIEW_KEY" ]; then
        address_keys=$(MONERO_ADDRESS_KEY_ONLY=1 monero_address_type "$MONERO_WALLET")
        derived=$(payout_public_view_key monero "$MONERO_VIEW_KEY") ||
            error "Cannot validate monero.view_key: python3 must be available and the key must be a nonzero canonical private scalar."
        [ "$derived" = "$address_keys" ] || error "monero.view_key does not belong to monero.wallet_address: the public view key differs."
    fi
    if [ -n "$TARI_VIEW_KEY" ]; then
        address_keys=$(TARI_ADDRESS_KEY_ONLY=1 tari_address_type "$TARI_WALLET")
        case "${#address_keys}" in
        66) error "Tari payout confirmation needs a dual-key address, which Tari Universe gives by default. A single-key address carries no public view key to check tari.view_key against. Mining payouts to single-key addresses remain supported." ;;
        130) ;;
        *) error "Cannot decode tari.wallet_address for payout confirmation; python3 must be available." ;;
        esac
        derived=$(payout_public_view_key tari "$TARI_VIEW_KEY") ||
            error "Cannot validate tari.view_key: python3 must be available and the key must be a nonzero canonical private scalar."
        [ "$derived" = "${address_keys:2:64}" ] || error "tari.view_key does not belong to tari.wallet_address: the public view key differs."
        explicit="$TARI_SPEND_PUBLIC_KEY"
        TARI_SPEND_PUBLIC_KEY="${address_keys:66:64}"
        [ -z "$explicit" ] || [ "$explicit" = "$TARI_SPEND_PUBLIC_KEY" ] ||
            error "tari.spend_public_key disagrees with tari.wallet_address. Leave it empty to derive the public spend key from the address."
    fi
}
