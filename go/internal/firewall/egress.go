package firewall

import (
	"regexp"
	"strings"
)

type TorConfig struct {
	Prefix string
	Subnet string
	Active string
}

func TorEnforced(config TorConfig) (int, error) {
	engine, err := Engine()
	if err != nil {
		return 0, err
	}
	if engine == "podman" {
		nft, err := tool("nft")
		if err != nil {
			return 0, err
		}
		if nft == "" {
			return 0, ErrUnsupportedInput
		}
		return torNFTEnforced(config)
	}
	iptables, err := tool("iptables")
	if err != nil {
		return 0, err
	}
	if iptables == "" {
		return 2, nil
	}
	if err := executable(iptables); err != nil {
		return 0, err
	}
	sudo, err := tool("sudo")
	if err != nil {
		return 0, err
	}
	if sudo == "" {
		return 3, nil
	}
	if _, ok, err := command(sudo, "-n", "iptables", "-S"); err != nil {
		return 0, err
	} else if !ok {
		return 3, nil
	}
	out, ok, err := command(sudo, "-n", "iptables", "-S", "DOCKER-USER")
	if err != nil {
		return 0, err
	}
	if !ok {
		return 1, nil
	}
	if err := requireTool("grep"); err != nil {
		return 0, err
	}
	if !lineMatch(out, regexp.MustCompile(EgressTag+`.* -j DROP`)) {
		return 1, nil
	}
	config, err = config.values()
	if err != nil {
		return 0, err
	}
	matched, err := config.syncRulesMatch(out)
	if err != nil {
		return 0, err
	}
	if !matched {
		return 1, nil
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "-N") || strings.HasPrefix(line, "-P") {
			continue
		}
		if taggedEgressDrop(line) {
			break
		}
		if strings.Contains(line, EgressTag) {
			continue
		}
		shadows, err := egressRuleShadows(line, config.Subnet)
		if err != nil {
			return 0, err
		}
		if shadows {
			return 5, nil
		}
	}
	forward, ok, err := command(sudo, "-n", "iptables", "-S", "FORWARD")
	if err != nil {
		return 0, err
	}
	if !ok {
		return 4, nil
	}
	canonical, _, err := egressCanonical("-A FORWARD -j DOCKER-USER")
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(forward, "\n") {
		if !strings.HasPrefix(line, "-A FORWARD ") {
			continue
		}
		value, valid, err := egressCanonical(line)
		if err != nil {
			return 0, err
		}
		if valid && value == canonical {
			return 0, nil
		}
		shadows, err := egressRuleShadows(line, config.Subnet)
		if err != nil {
			return 0, err
		}
		if shadows {
			return 4, nil
		}
	}
	return 4, nil
}

func taggedEgressDrop(line string) bool {
	_, after, tagged := strings.Cut(line, EgressTag)
	return tagged && strings.Contains(after, " -j DROP")
}

func (config TorConfig) values() (TorConfig, error) {
	for _, value := range []*string{&config.Prefix, &config.Subnet, &config.Active} {
		if strings.ContainsRune(*value, 0) {
			return TorConfig{}, ErrUnsupportedInput
		}
		*value = strings.TrimRight(*value, "\n")
	}
	if strings.ContainsAny(config.Prefix+config.Subnet, "\r\n") {
		return TorConfig{}, ErrUnsupportedInput
	}
	if config.Prefix == "" {
		config.Prefix = "172.28.0"
	}
	if config.Subnet == "" {
		config.Subnet = "172.28.0.0/24"
	}
	return config, nil
}
