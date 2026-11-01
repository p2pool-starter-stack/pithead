package runtime

import (
	"encoding/json"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/domain"
)

func TestNativeInfrastructureSections(t *testing.T) {
	data := map[string]any{
		"monero_sync": map[string]any{"db_size": json.Number("85000000000")},
		"system":      map[string]any{"disk": map[string]any{"percent": json.Number("95")}},
	}
	metrics, err := domain.Build(domain.Input{LatestData: data})
	if err != nil {
		t.Fatal(err)
	}
	sections, err := infrastructureSections(data, metrics)
	if err != nil {
		t.Fatal(err)
	}
	if len(sections) != 5 {
		t.Fatalf("section count = %d", len(sections))
	}
	monero := sections["build_monero"].(map[string]any)
	sync := sections["build_sync"].(map[string]any)["monero"].(map[string]any)
	disk := sections["build_system"].(map[string]any)["disk"].(map[string]any)
	if monero["db_size"] != "85.0 GB" || sync["db_size"] != monero["db_size"] || disk["fill"] != "critical" {
		t.Fatalf("native sections = %#v", sections)
	}
}

func TestUnsupportedInfrastructureRefusesNativeState(t *testing.T) {
	data := map[string]any{"system": map[string]any{"cpu_percent": nil}}
	metrics, err := domain.Build(domain.Input{LatestData: data})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := infrastructureSections(data, metrics); err == nil {
		t.Fatal("invalid CPU input accepted")
	}
}
