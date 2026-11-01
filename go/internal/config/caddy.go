package config

import "errors"

var ErrUnsupportedCaddy = errors.New("unsupported Caddy render")

type CaddyInput struct {
	Secure         string
	HostPort       string
	Host           string
	HTTPAddresses  string
	HTTPSAddresses string
	BindAddresses  string
	Auth           string
	TLSLine        string
	BootCapability string
	NetworkPrefix  string
	Onion          string
}

const caddyLogBlock = `    log {
        output file /var/log/caddy/access.log {
            roll_size 4MiB
            roll_keep 2
            mode 0644
        }
        format filter {
            wrap json
            fields {
                request>headers>X-Pithead-Boot-Probe delete
            }
        }
    }`

func RenderCaddyFragment(section string, input CaddyInput) ([]byte, error) {
	var output string
	switch section {
	case "prefix":
		output = renderCaddyPrefix(input)
	case "main":
		output = renderCaddyMain(input)
	case "onion-http":
		if input.Auth == "" {
			return nil, ErrUnsupportedCaddy
		}
		output = renderCaddyOnionHTTP(input)
	case "onion-https":
		if input.Auth == "" || input.Onion == "" || input.Onion == "placeholder" {
			return nil, ErrUnsupportedCaddy
		}
		output = renderCaddyOnionHTTPS(input)
	default:
		return nil, ErrUnsupportedCaddy
	}
	return []byte(output), nil
}

func renderCaddyPrefix(input CaddyInput) string {
	if input.Secure != "true" {
		return ""
	}
	global := "{\n    auto_https disable_redirects\n}\n\n"
	if input.HostPort != "" && input.HostPort != "443" {
		return global
	}
	bind := caddyBindLine(input.BindAddresses)
	return global + input.HTTPAddresses + " {\n" + bind + `
    redir https://{host}{uri} 308
}

http:// {
` + bind + "\n    redir https://" + input.Host + `{uri} 308
}

https:// {
` + bind + "\n    redir https://" + input.Host + `{uri} 308
}

`
}

func renderCaddyMain(input CaddyInput) string {
	addresses := input.HTTPAddresses
	tls := ""
	if input.Secure == "true" {
		addresses = input.HTTPSAddresses
		tls = input.TLSLine
	}
	bootMarker := ""
	if input.Auth != "" {
		bootMarker = "        log_append @boot_health <pithead_probe boot-health-v1"
	}
	return addresses + " {\n" + tls + "\n" + caddyBindLine(input.BindAddresses) + "\n" + caddyLogBlock + `
    @boot_health {
        remote_ip 127.0.0.1 ::1
        method GET
        expression {http.request.uri} == "/.pithead-boot-health"
        not header Authorization *
        header X-Pithead-Boot-Probe "` + input.BootCapability + `"
    }
    route {
` + bootMarker + `
        rewrite @boot_health /
` + input.Auth + `
        reverse_proxy 127.0.0.1:8000 {
            header_up X-Auth-User {http.auth.user.id}
            header_up -X-Pithead-Boot-Probe
        }
    }
}
`
}

func renderCaddyOnionHTTP(input CaddyInput) string {
	return "\nhttp://" + input.NetworkPrefix + ".1 {\n" + caddyOnionBindLine(input) + "\n" + input.Auth + "\n" + caddyLogBlock + `
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
        header_up -X-Pithead-Boot-Probe
    }
}
`
}

func renderCaddyOnionHTTPS(input CaddyInput) string {
	return "\nhttps://" + input.Onion + " {\n    tls internal\n" + caddyOnionBindLine(input) + "\n" + input.Auth + "\n" + caddyLogBlock + `
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
        header_up -X-Pithead-Boot-Probe
    }
}
`
}

func caddyBindLine(addresses string) string {
	if addresses == "" {
		return ""
	}
	return "    bind " + addresses
}

func caddyOnionBindLine(input CaddyInput) string {
	if input.BindAddresses == "" {
		return ""
	}
	return "    bind " + input.NetworkPrefix + ".1"
}
