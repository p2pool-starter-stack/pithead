package status

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/onion"
)

const docsURL = "https://github.com/p2pool-starter-stack/pithead/blob/main"

func (r *Runner) onionStatus() string {
	if r.get("DASHBOARD_ONION_ENABLED") != "true" {
		return ""
	}
	address := r.get("DASHBOARD_ONION_ADDRESS")
	if onion.Missing(address) {
		return ""
	}
	return onion.Status(r.Program, address, r.get("DASHBOARD_ONION_CLIENT_AUTH"))
}

func (r *Runner) announceStratumAuth() {
	password := r.get("PROXY_STRATUM_PASSWORD")
	if password == "" {
		r.log("Stratum password: none set (any password is accepted)")
		return
	}
	r.log("Stratum password: " + password)
	r.log("Stratum authentication is ON: every rig must connect with pass \"" + password + "\" (set it as the xmrig/RigForge stratum password). See " + docsURL + "/docs/workers.md#authentication.")
}

func (r *Runner) announceStratumTLS() {
	enabled := os.Getenv("STRATUM_TLS")
	if enabled == "" {
		enabled = r.get("PROXY_STRATUM_TLS")
	}
	dir := os.Getenv("PROXY_TLS_DIR")
	if dir == "" {
		dir = r.get("PROXY_TLS_DIR")
	}
	cert := filepath.Join(dir, "cert.pem")
	if enabled != "true" || dir == "" {
		return
	}
	info, err := os.Stat(r.path(cert))
	if err != nil || !info.Mode().IsRegular() {
		return
	}
	out, err := r.output("openssl", "x509", "-in", cert, "-noout", "-fingerprint", "-sha256")
	if err != nil || out == "" {
		return
	}
	if fields := strings.Split(out, "="); len(fields) > 1 {
		out = fields[1]
	}
	fingerprint := strings.ToLower(strings.ReplaceAll(out, ":", ""))
	if fingerprint == "" {
		return
	}
	r.log("Stratum TLS is ON: rigs may connect with TLS on the same stratum port (cleartext still accepted). Pin this fingerprint on each rig (pools[].tls-fingerprint): " + fingerprint)
}
