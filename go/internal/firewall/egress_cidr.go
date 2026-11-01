package firewall

import (
	"math"
	"strconv"
	"strings"
)

type egressCIDR struct {
	address uint32
	prefix  uint8
}

func egressValidCIDR(value string) (bool, error) {
	_, valid, err := parseEgressCIDR(value, false)
	return valid, err
}

func egressCIDROverlaps(first, second string) (bool, error) {
	one, valid, err := parseEgressCIDR(first, true)
	if err != nil || !valid {
		return false, err
	}
	two, valid, err := parseEgressCIDR(second, true)
	if err != nil || !valid {
		return false, err
	}
	prefix := one.prefix
	if two.prefix < prefix {
		prefix = two.prefix
	}
	mask := egressMask(prefix)
	return one.address&mask == two.address&mask, nil
}

func egressCIDRContains(container, member string) (bool, error) {
	outer, valid, err := parseEgressCIDR(container, true)
	if err != nil || !valid {
		return false, err
	}
	inner, valid, err := parseEgressCIDR(member, true)
	if err != nil || !valid {
		return false, err
	}
	if outer.prefix > inner.prefix {
		return false, nil
	}
	mask := egressMask(outer.prefix)
	return outer.address&mask == inner.address&mask, nil
}

func parseEgressCIDR(value string, arithmetic bool) (egressCIDR, bool, error) {
	if strings.IndexByte(value, 0) >= 0 || strings.Contains(value, "\n") {
		return egressCIDR{}, false, ErrUnsupportedInput
	}
	ip := value
	prefixText := "32"
	if slash := strings.IndexByte(value, '/'); slash >= 0 {
		ip = value[:slash]
		prefixText = value[slash+1:]
	}
	if arithmetic && len(prefixText) > 1 && prefixText[0] == '0' {
		return egressCIDR{}, false, ErrUnsupportedInput
	}
	prefix, numeric, err := egressDecimal(prefixText)
	if err != nil || !numeric || prefix > 32 {
		return egressCIDR{}, false, err
	}
	parts := strings.Split(ip, ".")
	if len(parts) == 5 && parts[4] == "" {
		parts = parts[:4]
	} else if len(parts) == 6 && parts[4] == "" && parts[5] == "" {
		if arithmetic {
			return egressCIDR{}, false, ErrUnsupportedInput
		}
		parts = parts[:4]
	}
	if len(parts) != 4 {
		return egressCIDR{}, false, nil
	}
	var address uint32
	for _, part := range parts {
		octet, numeric, err := egressDecimal(part)
		if err != nil || !numeric || octet > 255 {
			return egressCIDR{}, false, err
		}
		address = address<<8 | uint32(octet)
	}
	return egressCIDR{address: address, prefix: uint8(prefix)}, true, nil
}

func egressDecimal(value string) (uint64, bool, error) {
	if value == "" {
		return 0, false, nil
	}
	for index := range value {
		if value[index] < '0' || value[index] > '9' {
			return 0, false, nil
		}
	}
	number, err := strconv.ParseUint(value, 10, 64)
	if err != nil || number > math.MaxInt64 {
		return 0, false, ErrUnsupportedInput
	}
	return number, true, nil
}

func egressMask(prefix uint8) uint32 {
	if prefix == 0 {
		return 0
	}
	return ^uint32(0) << (32 - prefix)
}
