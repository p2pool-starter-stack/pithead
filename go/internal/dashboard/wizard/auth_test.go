package wizard

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

func TestPythonUpperMatchesPython311UnicodeTable(t *testing.T) {
	hash := sha256.New()
	var length [4]byte
	for r := rune(0); r <= 0x10ffff; r++ {
		if r >= 0xd800 && r <= 0xdfff {
			continue
		}
		upper := []byte(pythonUpper(string(r)))
		binary.BigEndian.PutUint32(length[:], uint32(len(upper)))
		hash.Write(length[:])
		hash.Write(upper)
	}
	actual := hex.EncodeToString(hash.Sum(nil))
	const expected = "a32755f043cb749867fd6c8d9995becbdbcff01627c7848de5881ffa8ac92e6a"
	if actual != expected {
		t.Fatalf("uppercase table hash = %s, want %s", actual, expected)
	}
}

func TestCanonicalTokenMatchesPythonUpperAndWhitespace(t *testing.T) {
	cases := map[string]string{
		"  pit-x7km2q  ":        "X7KM2Q",
		"\x1cpit-token\x1f":     "TOKEN",
		"\u00a0pit-token\u3000": "TOKEN",
		"pit-stra\u00dfe":       "STRASSE",
		"pit-\ufb03":            "FFI",
		"pit-\u1f80":            "\u1f08\u0399",
		"pit-\u019b":            "\u019b",
		"pit-\U00010d70":        "\U00010d70",
	}
	for input, expected := range cases {
		if actual := canonicalToken(input); actual != expected {
			t.Errorf("canonicalToken(%q) = %q, want %q", input, actual, expected)
		}
	}
}

func TestCookiePolicyAndTypeErrors(t *testing.T) {
	cases := []struct {
		name        string
		token       string
		cookie      string
		want        bool
		wantTypeErr bool
	}{
		{name: "empty token short circuits unicode", cookie: "\u00df"},
		{name: "equal", token: "pit-TOKEN", cookie: "pit-TOKEN", want: true},
		{name: "raw case differs", token: "pit-TOKEN", cookie: "PIT-TOKEN"},
		{name: "unicode token", token: "pit-\u00df", cookie: "pit-\u00df", wantTypeErr: true},
		{name: "unicode cookie", token: "pit-TOKEN", cookie: "pit-\u00df", wantTypeErr: true},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			actual, err := cookieMatches(test.token, test.cookie)
			if (err != nil) != test.wantTypeErr {
				t.Fatalf("error = %v", err)
			}
			if actual != test.want {
				t.Fatalf("match = %v, want %v", actual, test.want)
			}
		})
	}
}

func TestLoginPolicy(t *testing.T) {
	success, err := loginToken(authRequest{
		Token: "pit-Stra\u00dfe", Supplied: "  STRASSE ", Failures: 3, MaxFailures: 5,
	})
	if err != nil || success != (authLogin{Accepted: true, Failures: 3, Status: 302}) {
		t.Fatalf("success = %+v, error = %v", success, err)
	}
	failure, err := loginToken(authRequest{
		Token: "pit-TOKEN", Supplied: "wrong", Failures: 3, MaxFailures: 5,
	})
	if err != nil || failure != (authLogin{Failures: 4, Status: 403}) {
		t.Fatalf("failure = %+v, error = %v", failure, err)
	}
	locked, err := loginToken(authRequest{
		Token: "pit-TOKEN", Supplied: "wrong", Failures: 4, MaxFailures: 5,
	})
	if err != nil || locked != (authLogin{Failures: 5, Status: 429}) {
		t.Fatalf("locked = %+v, error = %v", locked, err)
	}
	empty, err := loginToken(authRequest{Supplied: "\u03c0", Failures: 0, MaxFailures: 5})
	if err != nil || empty != (authLogin{Failures: 1, Status: 403}) {
		t.Fatalf("empty = %+v, error = %v", empty, err)
	}
	spaces, err := loginToken(authRequest{Token: " ", Supplied: "\u3000", Failures: 2, MaxFailures: 5})
	if err != nil || spaces != (authLogin{Accepted: true, Failures: 2, Status: 302}) {
		t.Fatalf("spaces = %+v, error = %v", spaces, err)
	}
}

func TestLoginCanonicalUnicodeTypeError(t *testing.T) {
	_, err := loginToken(authRequest{Token: "pit-\u03c0", Supplied: "pit-\u03c0", MaxFailures: 5})
	if err == nil || err.Error() != authTypeErrorMessage {
		t.Fatalf("error = %v", err)
	}
}

func TestRunAuthJSONLines(t *testing.T) {
	input := strings.Join([]string{
		`{"operation":"canon","token":" pit-x7km2q "}`,
		`{"operation":"cookie","token":"pit-token","cookie":"pit-token"}`,
		`{"operation":"login","token":"pit-token","supplied":"wrong","failures":4,"max_failures":5}`,
		`{"operation":"cookie","token":"pit-\u03c0","cookie":"pit-\u03c0"}`,
		`{"operation":"unknown"}`,
		`{"operation":`,
	}, "\n") + "\n"
	var output bytes.Buffer
	if err := RunAuth(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	var responses []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(output.String()), "\n") {
		var response map[string]any
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 6 || responses[0]["value"] != "X7KM2Q" || responses[1]["value"] != true {
		t.Fatalf("responses = %#v", responses)
	}
	login := responses[2]["value"].(map[string]any)
	if login["failures"] != float64(5) || login["status"] != float64(429) {
		t.Fatalf("login = %#v", login)
	}
	errorValue := responses[3]["error"].(map[string]any)
	if errorValue["kind"] != "TypeError" || errorValue["message"] != authTypeErrorMessage {
		t.Fatalf("error = %#v", errorValue)
	}
	errorValue = responses[4]["error"].(map[string]any)
	if errorValue["kind"] != "ValueError" {
		t.Fatalf("unsupported error = %#v", errorValue)
	}
	errorValue = responses[5]["error"].(map[string]any)
	if errorValue["kind"] != "OSError" {
		t.Fatalf("decode error = %#v", errorValue)
	}
}
