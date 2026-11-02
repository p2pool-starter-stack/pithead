package wizard

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func prepareReference() *ConfigValue {
	return opDict(
		opField("monero", opDict(opField("wallet_address", opString("")))),
		opField("xvb", opDict(opField("enabled", opBool(true)), opField("url", opString("")), opField("donor_id", opString("")))),
		opField("dashboard", opDict()),
		opField("workers", opDict(opField("list", opList()))),
	)
}

func legacyDefaultValues() *ConfigValue {
	return opDict(
		opField("enabled", opBool(true)),
		opField("url", opString("legacy-endpoint")),
		opField("donor_id", opString("auto")),
	)
}

func TestPrepareConfigMigratesAliasesFiltersWorkersAndPreservesOrder(t *testing.T) {
	worker := opDict(
		opField("name", opString("shed")),
		opField("secret_extension", opString("do-not-render")),
		opField("host", opString("rig.example.com")),
	)
	cfg := opDict(
		opField("config_version", opString("1.0")),
		opField("xmrig_proxy", opDict(opField("url", opString("custom")), opField("ignored", opString("credential-value")))),
		opField("dashboard", opDict(opField("workers", opList(worker)))),
		opField("monero", opDict(opField("wallet_address", opString("private-wallet")), opField("unknown", opString("private-value")))),
		opField("unknown", opString("private-top-level")),
	)
	prepared, changes, err := PrepareConfig(cfg, prepareReference(), legacyDefaultValues(), false)
	if err != nil {
		t.Fatal(err)
	}
	if keys := opKeys(prepared); !reflect.DeepEqual(keys, []string{"dashboard", "monero", "xvb", "workers"}) {
		t.Fatalf("keys = %#v", keys)
	}
	wantChanges := []string{
		"xmrig_proxy.url → xvb.url",
		"xmrig_proxy.ignored removed",
		"dashboard.workers → workers.list",
		"monero.unknown removed",
		"unknown removed",
		"workers.list[].secret_extension removed",
	}
	if !reflect.DeepEqual(changes, wantChanges) {
		t.Fatalf("changes = %#v", changes)
	}
	monero, _ := prepared.Field("monero")
	wallet, walletPresent := monero.Field("wallet_address")
	if !walletPresent || wallet.Text != "private-wallet" {
		t.Fatalf("wallet = %#v", wallet)
	}
	workers, _ := prepared.Field("workers")
	workerList, _ := workers.Field("list")
	if keys := opKeys(workerList.Items[0]); !reflect.DeepEqual(keys, []string{"name", "host"}) {
		t.Fatalf("worker keys = %#v", keys)
	}
	joined := strings.Join(changes, " ")
	for _, secret := range []string{"credential-value", "private-value", "private-top-level", "do-not-render"} {
		if strings.Contains(joined, secret) {
			t.Fatalf("change summary leaked %q", secret)
		}
	}
	if _, exists := cfg.Field("config_version"); !exists {
		t.Fatal("preparation mutated input")
	}
}

func TestPrepareConfigConflictOrderAndStrictLegacyDefaults(t *testing.T) {
	cfg := opDict(
		opField("dashboard", opDict(opField("workers", opList(opString("old"))))),
		opField("workers", opDict(opField("list", opList(opString("new"))))),
		opField("xmrig_proxy", opDict(
			opField("enabled", opInt("1")),
			opField("url", opString("legacy-endpoint")),
			opField("donor_id", opString("auto")),
		)),
		opField("xvb", opDict(
			opField("enabled", opBool(false)),
			opField("url", opString("custom")),
			opField("donor_id", opString("mine")),
		)),
	)
	_, _, err := PrepareConfig(cfg, prepareReference(), legacyDefaultValues(), true)
	var validation ValidationError
	if !errors.As(err, &validation) {
		t.Fatalf("error = %v", err)
	}
	want := "removed 1.x keys differ from their replacements (workers.list and dashboard.workers; xvb.enabled and xmrig_proxy.enabled)"
	if err.Error() != want {
		t.Fatalf("error = %q", err)
	}
}

func TestPrepareConfigUsesPythonNumericEqualityForConflicts(t *testing.T) {
	cfg := opDict(
		opField("xmrig_proxy", opDict(opField("enabled", opInt("0")))),
		opField("xvb", opDict(opField("enabled", opBool(false)))),
	)
	prepared, _, err := PrepareConfig(cfg, prepareReference(), legacyDefaultValues(), true)
	if err != nil {
		t.Fatal(err)
	}
	xvb, _ := prepared.Field("xvb")
	enabled, _ := xvb.Field("enabled")
	if enabled.Kind != "bool" || enabled.Bool {
		t.Fatalf("canonical value = %#v", enabled)
	}
}

func TestPrepareConfigKeepsMalformedKnownValues(t *testing.T) {
	cfg := opDict(
		opField("monero", opInt("7")),
		opField("workers", opDict(opField("list", opList(opInt("1"), opString("bad"))))),
	)
	prepared, changes, err := PrepareConfig(cfg, prepareReference(), legacyDefaultValues(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !prepared.Equal(cfg) || len(changes) != 0 {
		t.Fatalf("prepared=%#v changes=%#v", prepared, changes)
	}
}

func TestPrepareConfigMalformedLegacyShapes(t *testing.T) {
	for _, malformed := range []*ConfigValue{opList(), opInt("0"), opString("bad")} {
		prepared, changes, err := PrepareConfig(
			opDict(opField("xmrig_proxy", malformed)),
			prepareReference(),
			legacyDefaultValues(),
			false,
		)
		if err != nil {
			t.Fatal(err)
		}
		xvb, exists := prepared.Field("xvb")
		if !exists || !xvb.Equal(malformed) || !reflect.DeepEqual(changes, []string{"xmrig_proxy → xvb"}) {
			t.Fatalf("prepared=%#v changes=%#v", prepared, changes)
		}
	}
}

func TestPrepareConfigRejectsNonObjects(t *testing.T) {
	_, _, err := PrepareConfig(opList(), prepareReference(), legacyDefaultValues(), false)
	var validation ValidationError
	if !errors.As(err, &validation) || err.Error() != "config must be an object" {
		t.Fatalf("error = %v", err)
	}
}
