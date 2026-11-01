package config

import (
	"errors"
	"strings"
	"testing"
)

func TestRenderCaddyPrefix(t *testing.T) {
	input := CaddyInput{
		Secure:        "true",
		Host:          "192.0.2.10",
		HTTPAddresses: "http://pithead.local, http://192.0.2.10",
		BindAddresses: "192.0.2.10 127.0.0.1 ::1",
	}
	want := `{
    auto_https disable_redirects
}

http://pithead.local, http://192.0.2.10 {
    bind 192.0.2.10 127.0.0.1 ::1
    redir https://{host}{uri} 308
}

http:// {
    bind 192.0.2.10 127.0.0.1 ::1
    redir https://192.0.2.10{uri} 308
}

https:// {
    bind 192.0.2.10 127.0.0.1 ::1
    redir https://192.0.2.10{uri} 308
}

`
	got, err := RenderCaddyFragment("prefix", input)
	if err != nil || string(got) != want {
		t.Fatalf("RenderCaddyFragment(prefix) = %q, %v; want %q, nil", got, err, want)
	}

	input.HostPort = "8443"
	got, err = RenderCaddyFragment("prefix", input)
	if err != nil || string(got) != "{\n    auto_https disable_redirects\n}\n\n" {
		t.Fatalf("custom-port prefix = %q, %v", got, err)
	}

	input.Secure = "false"
	got, err = RenderCaddyFragment("prefix", input)
	if err != nil || len(got) != 0 {
		t.Fatalf("HTTP prefix = %q, %v; want empty", got, err)
	}
}

func TestRenderCaddyMain(t *testing.T) {
	input := CaddyInput{
		Secure:         "true",
		HTTPSAddresses: "https://pithead.local, https://192.0.2.10",
		BindAddresses:  "192.0.2.10 127.0.0.1 ::1",
		Auth:           "    basic_auth {\n        operator $2a$14$hash\n    }",
		TLSLine:        "    tls /pithead-tls/wizard.crt /pithead-tls/wizard.key",
		BootCapability: "0123456789abcdef",
	}
	want := `https://pithead.local, https://192.0.2.10 {
    tls /pithead-tls/wizard.crt /pithead-tls/wizard.key
    bind 192.0.2.10 127.0.0.1 ::1
    log {
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
    }
    @boot_health {
        remote_ip 127.0.0.1 ::1
        method GET
        expression {http.request.uri} == "/.pithead-boot-health"
        not header Authorization *
        header X-Pithead-Boot-Probe "0123456789abcdef"
    }
    route {
        log_append @boot_health <pithead_probe boot-health-v1
        rewrite @boot_health /
    basic_auth {
        operator $2a$14$hash
    }
        reverse_proxy 127.0.0.1:8000 {
            header_up X-Auth-User {http.auth.user.id}
            header_up -X-Pithead-Boot-Probe
        }
    }
}
`
	got, err := RenderCaddyFragment("main", input)
	if err != nil || string(got) != want {
		t.Fatalf("RenderCaddyFragment(main) = %q, %v; want %q, nil", got, err, want)
	}

	input = CaddyInput{HTTPAddresses: "http://pithead.local", BootCapability: "cap"}
	got, err = RenderCaddyFragment("main", input)
	if err != nil {
		t.Fatal(err)
	}
	text := string(got)
	if !strings.HasPrefix(text, "http://pithead.local {\n\n\n    log {") || strings.Contains(text, "log_append @boot_health") || !strings.HasSuffix(text, "}\n") {
		t.Fatalf("unauthenticated HTTP main has wrong shape: %q", text)
	}
}

func TestRenderCaddyOnionFragments(t *testing.T) {
	input := CaddyInput{
		BindAddresses: "127.0.0.1 ::1",
		Auth:          "    basic_auth {\n        operator $2a$14$hash\n    }",
		NetworkPrefix: "172.30.0",
		Onion:         "exampleexampleexampleexampleexampleexampleexampleexample.onion",
	}
	http, err := RenderCaddyFragment("onion-http", input)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(http), "\nhttp://172.30.0.1 {\n    bind 172.30.0.1\n    basic_auth {") || !strings.Contains(string(http), caddyLogBlock) || !strings.HasSuffix(string(http), "    }\n}\n") {
		t.Fatalf("HTTP onion fragment has wrong shape: %q", http)
	}

	https, err := RenderCaddyFragment("onion-https", input)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(https), "\nhttps://"+input.Onion+" {\n    tls internal\n    bind 172.30.0.1\n") || !strings.Contains(string(https), input.Auth) || !strings.HasSuffix(string(https), "    }\n}\n") {
		t.Fatalf("HTTPS onion fragment has wrong shape: %q", https)
	}
}

func TestRenderCaddyRejectsUnsupportedFragments(t *testing.T) {
	secret := "operator-secret"
	tests := []struct {
		section string
		input   CaddyInput
	}{
		{"unknown-" + secret, CaddyInput{}},
		{"onion-http", CaddyInput{Onion: secret}},
		{"onion-https", CaddyInput{Auth: secret}},
		{"onion-https", CaddyInput{Auth: secret, Onion: "placeholder"}},
	}
	for _, test := range tests {
		got, err := RenderCaddyFragment(test.section, test.input)
		if got != nil || !errors.Is(err, ErrUnsupportedCaddy) {
			t.Fatalf("RenderCaddyFragment(%q) = %q, %v; want nil, unsupported", test.section, got, err)
		}
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error exposes input: %q", err)
		}
	}
}
