s/(--rpc-login|--http-access-token|--tls-fingerprint)[= ][^ ]+/\1 [redacted]/g
s/(--wallet[ =])[^-[:space:]][^[:space:]]*/\1[redacted-address]/g
s/(--merge-mine[ =][^[:space:]]+[[:space:]]+)[^-[:space:]][^[:space:]]*/\1[redacted-address]/g
s/[a-z2-7]{56}\.onion/[redacted].onion/g
s/(^|[^0-9A-Za-z])([48][1-9A-HJ-NP-Za-km-z]{94}([1-9A-HJ-NP-Za-km-z]{11})?)([^0-9A-Za-z]|$)/\1[redacted-address]\4/g
s/(^|[^0-9A-Za-z])([48][1-9A-HJ-NP-Za-km-z]{94}([1-9A-HJ-NP-Za-km-z]{11})?)([^0-9A-Za-z]|$)/\1[redacted-address]\4/g
