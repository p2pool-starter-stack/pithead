package help

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestWriteMatchesBashHelp(t *testing.T) {
	var got bytes.Buffer
	if err := Write(&got, "pithead"); err != nil {
		t.Fatal(err)
	}

	if got.Len() != 15078 {
		t.Fatalf("length = %d, want 15078", got.Len())
	}
	if sum := fmt.Sprintf("%x", sha256.Sum256(got.Bytes())); sum != "de3460833bdc65922af204f8accf55d6294f38e633420e41eef8f3f1f40424c5" {
		t.Fatalf("sha256 = %s", sum)
	}
}

func TestWriteTreatsProgramAsLiteralText(t *testing.T) {
	program := `bin/$DOCS_URL/%s/\$0`
	var got bytes.Buffer
	if err := Write(&got, program); err != nil {
		t.Fatal(err)
	}

	text := got.String()
	if count := strings.Count(text, program); count != 3 {
		t.Fatalf("program occurrences = %d, want 3", count)
	}
	if count := strings.Count(text, DocsURL); count != 2 {
		t.Fatalf("docs URL occurrences = %d, want 2", count)
	}
}

func TestWriteReturnsWriterError(t *testing.T) {
	want := errors.New("write failed")
	if err := Write(errorWriter{want}, "pithead"); !errors.Is(err, want) {
		t.Fatalf("error = %v, want %v", err, want)
	}
}

type errorWriter struct {
	err error
}

func (w errorWriter) Write([]byte) (int, error) {
	return 0, w.err
}
