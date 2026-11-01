package firewall

func egressRuleShadows(line, subnet string) (bool, error) {
	tokens, ok, err := egressTokenise(line)
	if err != nil {
		return false, err
	}
	if !ok {
		return true, nil
	}
	want := byte(0)
	seen := false
	negated := false
	previousBang := false
	foreignNetwork := ""
	target := ""
	for _, token := range tokens {
		if want != 0 {
			if want == 's' {
				foreignNetwork = token.Text
			} else {
				target = token.Text
			}
			want = 0
			previousBang = false
			continue
		}
		if token.Quoted {
			previousBang = false
			continue
		}
		switch token.Text {
		case "!":
			previousBang = true
		case "-s", "--source", "--src":
			if seen {
				return true, nil
			}
			seen = true
			negated = previousBang
			want = 's'
			previousBang = false
		case "-j", "--jump", "-g", "--goto":
			want = 'j'
			previousBang = false
		default:
			previousBang = false
		}
	}
	if want != 0 {
		return true, nil
	}
	switch target {
	case "DROP", "REJECT", "LOG", "NFLOG":
		return false, nil
	}
	if !seen {
		return true, nil
	}
	valid, err := egressValidCIDR(foreignNetwork)
	if err != nil {
		return false, err
	}
	if !valid {
		return true, nil
	}
	valid, err = egressValidCIDR(subnet)
	if err != nil {
		return false, err
	}
	if !valid {
		return true, nil
	}
	if negated {
		contained, err := egressCIDRContains(foreignNetwork, subnet)
		if err != nil {
			return false, err
		}
		return !contained, nil
	}
	overlaps, err := egressCIDROverlaps(foreignNetwork, subnet)
	if err != nil {
		return false, err
	}
	return overlaps, nil
}
