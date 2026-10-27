# Project donations

Pithead accepts one-off XMR transfers at the address in the [README](../README.md#-donate).

Hashpower donation is under development and unavailable. The shipped destination
fields are empty; this adds no setting, mining route or network connection.

The destination belongs to the image, outside operator configuration. Its source is
`dashboard/mining_dashboard/config/donation.json`; only
`dashboard/mining_dashboard/config/donation_destination.py` loads it. The loader
reads no environment variables or operator config. Tests may supply a fixture path.
A missing, unreadable or malformed destination returns `available: false` with a
field-specific reason that omits the supplied value.

A destination needs a recipient of 1–40 characters, a 95-character primary Monero
address, an endpoint with a port from 1 to 65535, and an `onion` or `clearnet` kind.
Onion endpoints use a 56-character base32 host followed by `.onion` and no TLS
fingerprint. Clearnet endpoints require a 64-character hexadecimal TLS fingerprint.
The Python loader checks address shape; the stack test uses the existing
`monero_address_type` checksum gate.

Changing the destination requires an owner-approved PR. Update the SHA-256 pin in
`dashboard/tests/config/test_donation_destination.py` in that PR and align every
project address in the README, this guide and [privacy guide](privacy.md).
The dashboard provenance test checks every byte of the file. The repository-wide
reader and documentation checks run with the checksum test through `make test-tools`,
where the complete source checkout is available. While the shipped address is
empty, the checksum and documentation drift checks explicitly report that they
skip it; the checksum fixture still runs.
