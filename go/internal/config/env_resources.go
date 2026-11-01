package config

import (
	"errors"
	"strconv"
)

var ErrUnsupportedResources = errors.New("unsupported environment resource settings")

func PrepThreads(cores string) (string, error) {
	count, err := memoryFact(cores)
	if cores == "" || err != nil || count < -9223372036854775806 {
		return "", ErrUnsupportedResources
	}
	if count <= 6 {
		return "4", nil
	}
	if count >= 10 {
		return "8", nil
	}
	return strconv.FormatInt(count-2, 10), nil
}

func OutPeersValid(value string) (bool, error) {
	if value == "" {
		return false, nil
	}
	for _, current := range value {
		if current < '0' || current > '9' {
			return false, nil
		}
	}
	peers, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return false, ErrUnsupportedResources
	}
	return peers >= 8 && peers <= 1024, nil
}
