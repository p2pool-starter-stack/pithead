package firewall

import "strings"

func (config TorConfig) syncRulesMatch(out string) (bool, error) {
	for _, suffix := range []string{"26", "27", "28", "29"} {
		ip := config.Prefix + "." + suffix
		actual, dropSeen := 0, false
		for _, line := range strings.Split(out, "\n") {
			if strings.Contains(line, " -s "+config.Subnet+" ") && strings.Contains(line, " -j DROP") {
				dropSeen = true
			}
			if !strings.Contains(line, ip) || !strings.Contains(line, " -j ACCEPT") {
				continue
			}
			valid, err := egressSyncAccept(line, ip)
			if err != nil {
				return false, err
			}
			if !valid || dropSeen {
				return false, nil
			}
			actual++
		}
		expected := 0
		for _, active := range strings.Split(config.Active, "\n") {
			if ip == active {
				expected = 1
				break
			}
		}
		if actual != expected {
			return false, nil
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if !strings.Contains(line, EgressTag) {
			continue
		}
		for _, name := range []string{"sort", "tr", "paste"} {
			if err := requireTool(name); err != nil {
				return false, err
			}
		}
		canonical, valid, err := egressCanonical(line)
		if err != nil || !valid {
			return false, err
		}
		matched := false
		for _, rule := range config.rules() {
			expected, valid, err := egressCanonical("-A DOCKER-USER -m comment --comment " + EgressTag + " " + rule)
			if err != nil {
				return false, err
			}
			if valid && canonical == expected {
				matched = true
				break
			}
		}
		if !matched {
			return false, nil
		}
	}
	return true, nil
}

func (config TorConfig) rules() []string {
	rules := []string{
		"-m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT",
		"-s " + config.Prefix + ".25 -j ACCEPT",
	}
	for _, destination := range []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"} {
		rules = append(rules, "-s "+config.Subnet+" -d "+destination+" -j ACCEPT")
	}
	for _, ip := range strings.Split(config.Active, "\n") {
		if ip != "" {
			rules = append(rules, "-s "+ip+" -j ACCEPT")
		}
	}
	return append(rules,
		"-s "+config.Subnet+" -p tcp -m conntrack --ctstate ESTABLISHED -j REJECT --reject-with tcp-reset",
		"-s "+config.Subnet+" -j DROP")
}
