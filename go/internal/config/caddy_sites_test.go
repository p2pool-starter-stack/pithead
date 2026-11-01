package config

import "testing"

func TestCaddySiteAddresses(t *testing.T) {
	tests := []struct {
		name      string
		secure    string
		port      string
		hosts     []string
		wantHTTP  string
		wantHTTPS string
	}{
		{
			name:      "HTTPS default port",
			secure:    "true",
			port:      "443",
			hosts:     []string{"pithead.local", "192.0.2.10"},
			wantHTTP:  "http://pithead.local, http://192.0.2.10",
			wantHTTPS: "https://pithead.local, https://192.0.2.10",
		},
		{
			name:      "HTTP default port",
			secure:    "false",
			port:      "80",
			hosts:     []string{"[2001:db8::1]"},
			wantHTTP:  "http://[2001:db8::1]",
			wantHTTPS: "https://[2001:db8::1]",
		},
		{
			name:      "custom port",
			secure:    "true",
			port:      "8443",
			hosts:     []string{"host-a", "host-a"},
			wantHTTP:  "http://host-a:8443, http://host-a:8443",
			wantHTTPS: "https://host-a:8443, https://host-a:8443",
		},
		{
			name:      "alternate secure value uses HTTP default",
			secure:    "TRUE",
			port:      "80",
			hosts:     []string{"host"},
			wantHTTP:  "http://host",
			wantHTTPS: "https://host",
		},
		{
			name:      "alternate secure value keeps HTTPS port",
			secure:    "yes",
			port:      "443",
			hosts:     []string{"host"},
			wantHTTP:  "http://host:443",
			wantHTTPS: "https://host:443",
		},
		{
			name:      "raw leading zero port",
			secure:    "false",
			port:      "080",
			hosts:     []string{"host"},
			wantHTTP:  "http://host:080",
			wantHTTPS: "https://host:080",
		},
		{
			name:      "raw host tokens",
			secure:    "true",
			port:      "443 ",
			hosts:     []string{"münchen.example", "space host", "line\nbreak", ""},
			wantHTTP:  "http://münchen.example:443 , http://space host:443 , http://line\nbreak:443 , http://:443 ",
			wantHTTPS: "https://münchen.example:443 , https://space host:443 , https://line\nbreak:443 , https://:443 ",
		},
		{
			name:      "empty port",
			secure:    "true",
			port:      "",
			hosts:     []string{"host"},
			wantHTTP:  "http://host",
			wantHTTPS: "https://host",
		},
		{
			name:      "empty hosts",
			secure:    "true",
			port:      "8443",
			wantHTTP:  "",
			wantHTTPS: "",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			http, https := CaddySiteAddresses(test.secure, test.port, test.hosts)
			if http != test.wantHTTP || https != test.wantHTTPS {
				t.Fatalf("CaddySiteAddresses() = %q, %q; want %q, %q", http, https, test.wantHTTP, test.wantHTTPS)
			}
		})
	}
}

func TestCaddySiteAddressesPreservesInvalidUTF8Bytes(t *testing.T) {
	host := string([]byte{0xff, 'h'})
	http, https := CaddySiteAddresses("true", "443", []string{host})
	if http != "http://"+host || https != "https://"+host {
		t.Fatalf("CaddySiteAddresses() changed host bytes: %q, %q", http, https)
	}
}
