package preview

import "testing"

func TestEnvChangedKeys(t *testing.T) {
	tests := []struct {
		name, first, second, want string
	}{
		{"added-removed-changed", "A=1\nB=2\nD=4\n", "A=1\nB=3\nC=4\n", "B\nC\nD\n"},
		{"duplicates", "A=1\nA=1\n", "A=1\n", "A\n"},
		{"leading-space-and-equals", "  A=old=value", "\tA=new=value", "A\n"},
		{"empty", "", "", ""},
		{"empty-record", "\n", "", "\n"},
		{"unterminated", "A=1", "A=2", "A\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := EnvChangedKeys([]byte(test.first), []byte(test.second))
			if !ok || string(got) != test.want {
				t.Fatalf("got %q, %v; want %q", got, ok, test.want)
			}
		})
	}
}

func TestEnvChangedKeysRejectsNUL(t *testing.T) {
	if got, ok := EnvChangedKeys([]byte("A=1\x00B=2"), nil); ok || got != nil {
		t.Fatalf("got %q, %v", got, ok)
	}
}
