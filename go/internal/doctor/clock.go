package doctor

import (
	"os/exec"
	"strings"
)

func ClockSyncStatus() (string, error) {
	command := exec.Command("timedatectl", "show", "-p", "NTPSynchronized", "--value")
	output, _ := command.Output()
	if strings.ContainsRune(string(output), '\x00') {
		return "", ErrUnsupportedProbeInput
	}
	switch strings.TrimRight(string(output), "\n") {
	case "yes":
		return "synced", nil
	case "no":
		return "unsynced", nil
	default:
		return "unknown", nil
	}
}

func ClockSync(appliance bool) (Finding, error) {
	syncStatus, err := ClockSyncStatus()
	if err != nil {
		return Finding{}, err
	}
	status, message := "info", "Could not verify system-clock sync (no timedatectl) — make sure NTP is running; mining is time-sensitive."
	switch syncStatus {
	case "synced":
		status, message = "ok", "System clock is NTP-synchronized."
	case "unsynced":
		status = "warn"
		message = "System clock is NOT NTP-synchronized — clock skew gets shares/blocks rejected. Enable time sync: 'sudo timedatectl set-ntp true' (or run chrony/systemd-timesyncd/ntpd)."
		if appliance {
			message = "System clock is NOT NTP-synchronized — clock skew gets shares and blocks rejected. There is no dashboard control that sets the clock."
		}
	}
	return Finding{ID: "clock-sync", Status: status, Message: message}, nil
}
