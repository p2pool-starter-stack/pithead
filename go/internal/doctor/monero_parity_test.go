//go:build parity

package doctor

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestMoneroParitySyncBodies(t *testing.T) {
	for _, body := range []string{
		`{"status":"OK","synchronized":true}`,
		`{"status":"OK","synchronized":false,"target_height":0}`,
		`{"status":"BUSY","synchronized":true}`,
		`{"status":"OK","synchronized":"true"}`,
		`{"status":"OK","synchronized":1}`,
		`{}`, `null`, `[]`, `true`, "   ",
	} {
		t.Run(fmt.Sprintf("case-%d", len(body))+"/"+body, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			input.write(t, "info.value", body)
			compareMonero(t, input, "sync")
		})
	}
}

func TestMoneroParitySyncGates(t *testing.T) {
	for _, name := range []string{"stopped", "no-curl", "no-jq", "empty", "line-only", "partial-info", "partial-header", "helper-failed", "running-partial"} {
		t.Run(name, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			switch name {
			case "stopped":
				input.write(t, "running.value", "")
			case "no-curl", "no-jq":
				if err := os.Remove(filepath.Join(input.dir, name[3:])); err != nil {
					t.Fatal(err)
				}
			case "empty":
				input.write(t, "info.value", "")
			case "line-only":
				input.write(t, "info.value", "\n\n")
			case "partial-info":
				input.write(t, "info.code", "7")
			case "partial-header":
				input.write(t, "header.code", "7")
			case "helper-failed":
				input.write(t, "peers.code", "3")
			case "running-partial":
				input.write(t, "running.code", "1")
			}
			compareMonero(t, input, "sync")
		})
	}
}

func TestMoneroParityConfigAndSurface(t *testing.T) {
	for _, name := range []string{"default-url", "auth", "getter-lines", "password-only", "url-slash", "appliance"} {
		t.Run(name, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			switch name {
			case "default-url":
				input.URL = ""
			case "auth":
				input.User, input.Password = "fixture-user", "synthetic-placeholder"
			case "getter-lines":
				input.User, input.Password, input.URL = "fixture-user\n\n", "synthetic-placeholder\n", "http://rpc.invalid\n\n"
			case "password-only":
				input.Password = "synthetic-placeholder"
			case "url-slash":
				input.URL += "/"
			case "appliance":
				input.Appliance = true
				input.write(t, "info.value", `{"status":"OK","synchronized":false}`)
				input.write(t, "peers.value", `{"outgoing":0,"incoming":2}`)
			}
			compareMonero(t, input, "sync")
		})
	}
}

func TestMoneroParityPeerCounts(t *testing.T) {
	for _, body := range []string{
		`{"outgoing":8,"incoming":2,"white":5,"grey":6}`,
		`{"outgoing":0,"incoming":0}`, `{"outgoing":-1,"incoming":2}`,
		`{"outgoing":"8","incoming":2}`, `{"outgoing":8,"incoming":null}`,
		`{"outgoing":true,"incoming":2}`, `{}`, `null`, `[]`, `false`, "",
	} {
		t.Run(body, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			input.write(t, "peers.value", body)
			compareMonero(t, input, "counts")
		})
	}
}

func TestMoneroParityTipInputs(t *testing.T) {
	for _, value := range []string{"199900", "198200", "198199", "200100", "1", "9999999999", "0", "-1", "10000000000", `"199900"`, "true", "null", `"$(printf fixture)"`} {
		t.Run(value, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			input.write(t, "header.value", `{"result":{"block_header":{"timestamp":`+value+`}}}`)
			compareMonero(t, input, "peers")
		})
	}
}

func TestMoneroParityPeerFindings(t *testing.T) {
	for _, name := range []string{"zero", "no-helper", "no-helper-stale", "appliance-zero", "appliance-no-helper-stale", "raw-args", "empty-url"} {
		t.Run(name, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			switch name {
			case "zero", "appliance-zero":
				input.write(t, "peers.value", `{"outgoing":0,"incoming":2}`)
			case "no-helper", "no-helper-stale", "appliance-no-helper-stale":
				input.write(t, "peers.code", "3")
			case "raw-args":
				input.User, input.Password, input.URL = "fixture-user\n", "synthetic-placeholder\n", "http://rpc.invalid\n"
			case "empty-url":
				input.URL = ""
			}
			if name == "no-helper-stale" || name == "appliance-no-helper-stale" {
				input.write(t, "header.value", `{"result":{"block_header":{"timestamp":198199}}}`)
			}
			input.Appliance = name == "appliance-zero" || name == "appliance-no-helper-stale"
			compareMonero(t, input, "peers")
		})
	}
}
