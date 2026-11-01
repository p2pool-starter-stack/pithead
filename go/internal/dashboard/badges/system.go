package badges

import "errors"

func appendSystemBadges(badges []any, data map[string]any, config settings) ([]any, error) {
	system, err := nestedObject(data, "system")
	if err != nil {
		return nil, err
	}
	disk, err := nestedObject(system, "disk")
	if err != nil {
		return nil, err
	}
	diskRaw := member(disk, "percent", nil)
	diskPercent := 0.0
	if truthy(diskRaw) {
		diskPercent, err = number(diskRaw)
		if err != nil {
			return nil, err
		}
	}
	if diskPercent >= config.diskCritical {
		badges = append(badges, badge("⚠ Disk "+fixed(diskPercent, 0)+"% full", "bad", "The data disk is almost full — free space now; a full disk can corrupt the Monero database."))
	} else if diskPercent >= config.diskWarn {
		badges = append(badges, badge("Disk "+fixed(diskPercent, 0)+"% full", "warn", "The data disk is filling up — free space or move a data_dir before it runs out."))
	}
	hugepages := member(system, "hugepages", nil)
	status := "Unknown"
	if truthy(hugepages) {
		items, ok := hugepages.([]any)
		if !ok || len(items) == 0 {
			return nil, errors.New("expected hugepages array")
		}
		status, ok = items[0].(string)
		if !ok {
			return nil, errors.New("expected hugepages status string")
		}
	}
	if status == "Disabled" {
		badges = append(badges, badge("⚠ HugePages off", "warn", "HugePages aren't reserved — RandomX hashrate is capped until they are. Run setup's tuning (or edit GRUB) and reboot to apply."))
	}
	memory, err := nestedObject(system, "memory")
	if err != nil {
		return nil, err
	}
	totalRaw := member(memory, "total_gb", nil)
	total := 0.0
	if truthy(totalRaw) {
		total, err = number(totalRaw)
		if err != nil {
			return nil, err
		}
	}
	if total > 0 && total < config.lowRAMFloor {
		badges = append(badges, badge("⚠ Low RAM ("+fixed(total, 0)+" GB)", "warn", "Under "+general(config.lowRAMFloor)+" GB of usable RAM for what this machine runs locally — syncing (Tari especially) is memory-heavy and can OOM. Add RAM for a stable node."))
	}
	availableRaw, found := memory["available_gb"]
	if found && availableRaw != nil {
		available, err := number(availableRaw)
		if err != nil {
			return nil, err
		}
		if available > 0 && available < config.lowRAMAvail {
			badges = append(badges, badge("⚠ Memory pressure ("+fixed(available, 1)+" GB free)", "warn", "Under "+general(config.lowRAMAvail)+" GB of memory is actually available right now — the next spike can OOM a container. Check which service is growing on the System panel."))
		}
	}
	if avx2, ok := system["avx2"].(bool); ok && !avx2 {
		badges = append(badges, badge("⚠ No AVX2", "warn", "This CPU lacks AVX2 — RandomX mining will be significantly slower. A hardware limit; nothing to change at runtime."))
	}
	return badges, nil
}
