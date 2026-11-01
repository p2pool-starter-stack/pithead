package firewall

import (
	"errors"
	"os"
	"strings"
)

type TorSyncState struct {
	Prefix     string
	CloseChain string
	StateDir   string
	Monero     string
	Tari       string
	P2Pool     string
	XVBEnabled string
	XVBTor     string
}

func (state TorSyncState) IPs() ([]string, error) {
	prefix, err := syncGetter(state.Prefix)
	if err != nil {
		return nil, err
	}
	if prefix == "" {
		prefix = "172.28.0"
	}
	stateDir, err := syncGetter(state.StateDir)
	if err != nil {
		return nil, err
	}
	if strings.IndexByte(state.CloseChain, 0) >= 0 {
		return nil, ErrUnsupportedInput
	}

	var ips []string
	if state.CloseChain != "monero" {
		monero, err := syncGetter(state.Monero)
		if err != nil {
			return nil, err
		}
		if monero == "true" {
			open, err := syncMarkerOpen(syncMarker(stateDir, "monero.synced"))
			if err != nil {
				return nil, err
			}
			if open {
				ips = append(ips, prefix+".26")
			}
		}
	}

	stateDir, err = syncGetter(state.StateDir)
	if err != nil {
		return nil, err
	}
	if state.CloseChain != "tari" {
		tari, err := syncGetter(state.Tari)
		if err != nil {
			return nil, err
		}
		if tari == "true" {
			open, err := syncMarkerOpen(syncMarker(stateDir, "tari.synced"))
			if err != nil {
				return nil, err
			}
			if open {
				ips = append(ips, prefix+".27")
			}
		}
	}

	p2pool, err := syncGetter(state.P2Pool)
	if err != nil {
		return nil, err
	}
	if p2pool == "true" {
		ips = append(ips, prefix+".28")
	}
	xvb, err := syncGetter(state.XVBEnabled)
	if err != nil {
		return nil, err
	}
	if xvb == "true" {
		tor, err := syncGetter(state.XVBTor)
		if err != nil {
			return nil, err
		}
		if tor == "false" {
			ips = append(ips, prefix+".29")
		}
	}
	return ips, nil
}

func syncGetter(value string) (string, error) {
	if strings.IndexByte(value, 0) >= 0 {
		return "", ErrUnsupportedInput
	}
	return strings.TrimRight(value, "\n"), nil
}

func syncMarker(dir, name string) string {
	return dir + "/" + name
}

func syncMarkerOpen(path string) (bool, error) {
	_, err := os.Lstat(path)
	if err == nil {
		return false, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return true, nil
	}
	return false, ErrUnsupportedInput
}
