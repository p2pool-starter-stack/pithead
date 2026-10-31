package status

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

type Runner struct {
	Dir, Program, EnvFile     string
	Out, Err                  io.Writer
	red, green, yellow, reset string
}

func (r *Runner) Run() int {
	if file, ok := r.Out.(*os.File); ok && os.Getenv("NO_COLOR") == "" {
		var size [4]uint16
		_, _, err := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&size)))
		if err == 0 {
			r.red, r.green, r.yellow, r.reset = "\033[1;31m", "\033[1;32m", "\033[1;33m", "\033[0m"
		}
	}
	if info, err := os.Stat(r.path(r.EnvFile)); err != nil || !info.Mode().IsRegular() {
		fmt.Fprint(r.Err, echoEscapes(fmt.Sprintf("%s[ERROR]%s No %s found. Run '%s setup' first.\n", r.red, r.reset, r.EnvFile, r.Program)))
		return 1
	}
	return r.services()
}

func (r *Runner) path(value string) string {
	if filepath.IsAbs(value) {
		return value
	}
	return filepath.Join(r.Dir, value)
}

func shellValue(value string) string {
	return strings.TrimRight(strings.ReplaceAll(value, "\x00", ""), "\n")
}

func (r *Runner) output(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = r.Dir
	output, err := cmd.Output()
	return shellValue(string(output)), err
}

func (r *Runner) filter(input string, args ...string) (string, error) {
	cmd := exec.Command("jq", args...)
	cmd.Dir = r.Dir
	cmd.Stdin = strings.NewReader(input)
	output, err := cmd.Output()
	return shellValue(string(output)), err
}

func (r *Runner) row(color, glyph, name, detail string) {
	fmt.Fprintf(r.Out, "  %s%s%s %-13s %s\n", color, glyph, r.reset, name, detail)
}

func (r *Runner) log(message string) {
	fmt.Fprint(r.Out, echoEscapes(r.green+"[pithead]"+r.reset+" "+message+"\n"))
}

func (r *Runner) warn(message string) {
	fmt.Fprint(r.Err, echoEscapes(r.yellow+"[WARNING]"+r.reset+" "+message+"\n"))
}
