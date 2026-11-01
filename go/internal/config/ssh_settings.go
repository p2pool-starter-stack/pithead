package config

import "strings"

type SSHSettingsInput struct {
	Release   bool
	ConfigSet string
	Carried   string
}

func ParseSSHSettings(raw []byte, input SSHSettingsInput) (string, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" || document.root.object == nil {
		return "", ErrUnsupportedValidation
	}
	_, hasSSH := objectValue(document.root, "ssh")
	if input.Release && hasSSH {
		if input.ConfigSet == "1" && input.Carried != "1" {
			return "ssh.enabled is unavailable on a release image; build a debug image for SSH.", nil
		}
		return "", nil
	}
	enabled, err := accessScalar(document.root, "ssh.enabled", "false")
	if err != nil || enabled != "true" {
		return "", err
	}
	key, err := accessScalar(document.root, "ssh.authorized_key", "")
	if err != nil {
		return "", err
	}
	if strings.HasPrefix(key, "ssh-") || strings.HasPrefix(key, "ecdsa-") || strings.HasPrefix(key, "sk-") {
		return "", nil
	}
	return "ssh.enabled is true but ssh.authorized_key is not a public key (expected it to start with ssh-, ecdsa- or sk-). Paste the PUBLIC key (e.g. ~/.ssh/id_ed25519.pub).", nil
}
