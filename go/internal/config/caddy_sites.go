package config

import "strings"

func CaddySiteAddresses(secure, port string, hosts []string) (string, string) {
	if secure == "true" && port == "443" || secure != "true" && port == "80" {
		port = ""
	}
	suffix := ""
	if port != "" {
		suffix = ":" + port
	}
	http := make([]string, len(hosts))
	https := make([]string, len(hosts))
	for index, host := range hosts {
		http[index] = "http://" + host + suffix
		https[index] = "https://" + host + suffix
	}
	return strings.Join(http, ", "), strings.Join(https, ", ")
}
