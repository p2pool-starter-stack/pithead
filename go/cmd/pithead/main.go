package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/p2pool-starter-stack/pithead/go/internal/cli"
)

func main() {
	internal, reference, args, err := invocation(os.Args)
	if err != nil {
		if internal {
			os.Exit(125)
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if internal && os.Getenv("_PITHEAD_GO_RECEIPT") == "1" {
		stderr := os.NewFile(5, "native stderr")
		if _, err := stderr.Stat(); err != nil {
			os.Exit(125)
		}
		os.Stderr = stderr
	}
	err = cli.Run(reference, args, os.Stdout)
	if internal {
		var receipt io.Writer = io.Discard
		if os.Getenv("_PITHEAD_GO_RECEIPT") == "1" {
			receipt = os.NewFile(3, "native completion")
		}
		os.Exit(internalResult(err, os.Stderr, receipt))
	}
	if errors.Is(err, cli.ErrFallback) {
		err = cli.Fallback(reference, args)
	}
	exit(err)
}

func invocation(argv []string) (bool, string, []string, error) {
	if os.Getenv("_PITHEAD_GO_NATIVE") == "1" {
		reference := os.Getenv("_PITHEAD_GO_SCRIPT")
		if reference == "" {
			return true, "", nil, errors.New("missing Bash reference")
		}
		return true, reference, argv[1:], nil
	}
	reference := os.Getenv("PITHEAD_GO_REFERENCE")
	if reference == "" {
		executable, err := os.Executable()
		if err != nil {
			return false, "", nil, err
		}
		reference = filepath.Join(filepath.Dir(executable), "..", "..", "pithead")
	}
	return false, reference, argv[1:], nil
}

func internalResult(err error, stderr, receipt io.Writer) int {
	var exitError *cli.ExitError
	if errors.As(err, &exitError) && exitError.Message != "" {
		fmt.Fprintln(stderr, exitError.Message)
	}
	code := internalExitCode(err)
	if code != 125 {
		if _, err := fmt.Fprintln(receipt, "pithead-native-v1"); err != nil {
			return 125
		}
	}
	return code
}

func internalExitCode(err error) int {
	if err == nil {
		return 200
	}
	var exitError *cli.ExitError
	if errors.As(err, &exitError) {
		switch exitError.Code {
		case 0:
			return 200
		case 1:
			return 201
		case 141:
			return 241
		}
	}
	return 125
}

func exit(err error) {
	if err == nil {
		return
	}
	var exitError *cli.ExitError
	if errors.As(err, &exitError) {
		if exitError.Message != "" {
			fmt.Fprintln(os.Stderr, exitError.Message)
		}
		os.Exit(exitError.Code)
	}
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
