package onion

func Missing(value string) bool {
	return value == "" || value == "placeholder"
}

func Status(program, address, clientAuth string) string {
	if Missing(address) {
		return ""
	}
	if clientAuth == "true" {
		return "http://" + address + " (client-auth ON + login; get your client key with '" + program + " onion-client-key')"
	}
	return "http://" + address + " (login required)"
}
