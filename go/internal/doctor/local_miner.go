package doctor

import "strings"

func (memory Memory) LocalMiner(enabled string) ([]Finding, error) {
	if !memory.Appliance {
		return nil, nil
	}
	if strings.ContainsRune(enabled, 0) {
		return nil, ErrUnsupportedProbeInput
	}
	if strings.TrimRight(enabled, "\n") != "true" {
		return nil, nil
	}
	if strings.ContainsRune(memory.Marker, 0) {
		return nil, ErrUnsupportedProbeInput
	}
	pages, supported := decisionPages(memory.marker())
	if !supported {
		return nil, ErrUnsupportedProbeInput
	}
	number, valid := decimal(pages)
	if !valid {
		return nil, ErrUnsupportedProbeInput
	}
	if number > 0 && number < hugePages {
		return []Finding{{"local-miner-hugepages", "warn", "Local mining opt-in is ON, but this machine's reduced HugePages reservation cannot also fit a co-located miner — the built-in RigForge worker is not started. Use a 16 GB machine for the built-in miner."}}, nil
	}
	return nil, nil
}
