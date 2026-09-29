#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
initial="$here/phases/install.sh"
reinstall="$here/phases/install-reinstall.sh"
# The committed install precedes reinstall; Fresh Start runs after the data
# verdict but before wipe=all erases the target used by its two boots.
line() { sed -n "/$2/=" "$1" | head -1; }
[ "$(line "$initial" '_phase_install_commit || return')" -lt "$(line "$initial" '_phase_install_reinstall || return')" ]
[ "$(line "$reinstall" 'wipe=data KEPT both chains')" -lt "$(line "$reinstall" '_phase_install_fresh_start || return')" ]
[ "$(line "$reinstall" '_phase_install_fresh_start || return')" -lt "$(line "$reinstall" 'wipe=all — the data partition')" ]
grep -Fq 'source "$SCRIPT_DIR/phases/install-fresh-start.sh"' "$initial"
echo 'Fresh Start install sequence: PASS'
