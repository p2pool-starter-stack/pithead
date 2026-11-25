package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"github.com/p2pool-starter-stack/pithead/go/internal/address"
	"github.com/p2pool-starter-stack/pithead/go/internal/payoutkeys"
)

const (
	helperAddress = "payout-keys-address"
	helperDerive  = "payout-keys-derive"
)

func main() {
	switch os.Getenv("PITHEAD_GO_HELPER") {
	case helperAddress:
		os.Exit(runAddressHelper(os.Stdin, os.Stdout))
	case helperDerive:
		os.Exit(runDeriveHelper(os.Stdin, os.Stdout))
	}
	handoff()
}

func runAddressHelper(stdin io.Reader, stdout io.Writer) int {
	fields, ok := readFields(stdin, 3)
	if !ok || (fields[0] != "monero" && fields[0] != "tari") {
		return 1
	}
	if fields[1] != "0" && fields[1] != "1" {
		return 1
	}
	verdict := address.Monero(fields[2], true, fields[1] == "1")
	if fields[0] == "tari" {
		verdict = address.Tari(fields[2], true, fields[1] == "1")
	}
	return writeField(stdout, verdict)
}

func runDeriveHelper(stdin io.Reader, stdout io.Writer) int {
	fields, ok := readFields(stdin, 2)
	if !ok {
		return 1
	}
	derived, ok := payoutkeys.Derive(fields[0], fields[1])
	if !ok {
		return 1
	}
	return writeField(stdout, derived)
}

func readFields(stdin io.Reader, count int) ([]string, bool) {
	reader := bufio.NewReader(stdin)
	fields := make([]string, 0, count)
	for range count {
		field, err := reader.ReadBytes(0)
		if err != nil || len(field) == 0 || field[len(field)-1] != 0 {
			return nil, false
		}
		fields = append(fields, string(field[:len(field)-1]))
	}
	if trailing, err := reader.Peek(1); len(trailing) > 0 || err != io.EOF {
		return nil, false
	}
	return fields, true
}

func writeField(stdout io.Writer, field string) int {
	if _, err := fmt.Fprintf(stdout, "%s\x00", field); err != nil {
		return 1
	}
	return 0
}

func handoff() {
	reference := os.Getenv("PITHEAD_GO_REFERENCE")
	if reference == "" {
		executable, err := os.Executable()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		reference = filepath.Join(filepath.Dir(executable), "..", "..", "pithead")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(127)
	}
	env := append(os.Environ(), "PITHEAD_GO_REFERENCE="+reference, "PITHEAD_IMPL=bash", "PITHEAD_IMPL_LAUNCHED=1")
	argv := append([]string{bash, reference}, os.Args[1:]...)
	if err := syscall.Exec(bash, argv, env); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(1)
}
