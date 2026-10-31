package doctor

import "strings"

const networkDocsURL = "https://github.com/p2pool-starter-stack/pithead/blob/main"

type Stratum struct {
	Bind, Port, EnvBind, EnvPort string
	EnvPresent                   bool
}

func (stratum Stratum) EffectiveBind() (string, error) {
	return stratum.effective(stratum.Bind, stratum.EnvBind, "0.0.0.0")
}

func (stratum Stratum) EffectivePort() (string, error) {
	return stratum.effective(stratum.Port, stratum.EnvPort, "3333")
}

func (stratum Stratum) effective(explicit, getter, fallback string) (string, error) {
	if strings.ContainsRune(explicit, 0) {
		return "", ErrUnsupportedProbeInput
	}
	if explicit != "" {
		return explicit, nil
	}
	if stratum.EnvPresent {
		value, err := probeValue(getter)
		if err != nil {
			return "", err
		}
		if value != "" {
			return value, nil
		}
	}
	return fallback, nil
}
