package firewall

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const (
	LANTag    = "pithead-lan-guard"
	LANChain  = "PITHEAD-LAN"
	LANTable  = "pithead_lan"
	EgressTag = "pithead-tor-egress"
)

var ErrUnsupportedInput = errors.New("unsupported firewall input")

var portPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

func Engine() (string, error) {
	if engine := os.Getenv("PITHEAD_ENGINE"); engine == "docker" || engine == "podman" {
		return engine, nil
	}
	docker, err := tool("docker")
	if err != nil {
		return "", err
	}
	if docker != "" {
		return "docker", nil
	}
	podman, err := tool("podman")
	if err != nil {
		return "", err
	}
	if podman != "" {
		return "podman", nil
	}
	return "docker", nil
}

func LANEnforced(ports []string) (int, error) {
	for _, port := range ports {
		if !portPattern.MatchString(port) {
			return 0, ErrUnsupportedInput
		}
		if _, err := strconv.ParseUint(port, 10, 16); err != nil {
			return 0, ErrUnsupportedInput
		}
	}
	engine, err := Engine()
	if err != nil {
		return 0, err
	}
	if engine == "podman" {
		return nftEnforced(ports)
	}
	return iptablesEnforced(ports)
}

func iptablesEnforced(ports []string) (int, error) {
	iptables, err := tool("iptables")
	if err != nil {
		return 0, err
	}
	if iptables == "" {
		return 2, nil
	}
	if err := executable(iptables); err != nil {
		return 0, err
	}
	sudo, err := tool("sudo")
	if err != nil {
		return 0, err
	}
	if sudo == "" {
		return 3, nil
	}
	if _, ok, err := command(sudo, "-n", "iptables", "-S"); err != nil {
		return 0, err
	} else if !ok {
		return 3, nil
	}
	chain, ok, err := command(sudo, "-n", "iptables", "-S", LANChain)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 1, nil
	}
	if err := requireTool("tail"); err != nil {
		return 0, err
	}
	if lastLine(chain) != "-A "+LANChain+" -j DROP" {
		return 1, nil
	}
	dockerUser, ok, err := command(sudo, "-n", "iptables", "-S", "DOCKER-USER")
	if err != nil {
		return 0, err
	}
	if !ok {
		return 1, nil
	}
	if len(ports) > 0 {
		if err := requireTool("grep"); err != nil {
			return 0, err
		}
	}
	for _, port := range ports {
		pattern := regexp.MustCompile(`--dport ` + port + ` .*` + regexp.QuoteMeta(LANTag) + `.* -j ` + regexp.QuoteMeta(LANChain) + `$`)
		if !lineMatch(dockerUser, pattern) {
			return 1, nil
		}
	}
	seen := make(map[string]bool)
	dport := regexp.MustCompile(`--dport[[:space:]]+([0-9]+)`)
	for _, line := range lines(dockerUser) {
		switch {
		case strings.Contains(line, LANTag):
			match := dport.FindStringSubmatch(line)
			if match != nil {
				seen[match[1]] = true
			}
		case strings.HasPrefix(line, "-N"), strings.HasPrefix(line, "-P"), strings.Contains(line, EgressTag):
		case strings.Contains(line, " -j ACCEPT"), strings.Contains(line, " -j RETURN"):
			for _, port := range ports {
				if !seen[port] {
					return 5, nil
				}
			}
		}
	}
	forward, ok, err := command(sudo, "-n", "iptables", "-S", "FORWARD")
	if err != nil {
		return 0, err
	}
	if !ok || !strings.Contains(forward, "-j DOCKER-USER") {
		if ok && len(ports) == 0 {
			if err := requireTool("grep"); err != nil {
				return 0, err
			}
		}
		return 4, nil
	}
	if len(ports) == 0 {
		if err := requireTool("grep"); err != nil {
			return 0, err
		}
	}
	return 0, nil
}

func nftEnforced(ports []string) (int, error) {
	nft, err := tool("nft")
	if err != nil {
		return 0, err
	}
	if nft == "" {
		return 2, nil
	}
	if err := executable(nft); err != nil {
		return 0, err
	}
	jq, err := tool("jq")
	if err != nil {
		return 0, err
	}
	if jq == "" {
		return 3, nil
	}
	if err := executable(jq); err != nil {
		return 0, err
	}
	sudo, err := tool("sudo")
	if err != nil {
		return 0, err
	}
	if sudo == "" {
		return 3, nil
	}
	if _, ok, err := command(sudo, "-n", "nft", "list", "tables"); err != nil {
		return 0, err
	} else if !ok {
		return 3, nil
	}
	out, ok, err := command(sudo, "-n", "nft", "-j", "list", "table", "inet", LANTable)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 1, nil
	}
	enforced, err := validateNFT(out, ports)
	if err != nil {
		return 0, err
	}
	if !enforced {
		return 1, nil
	}
	return 0, nil
}

func tool(name string) (string, error) {
	for _, part := range filepath.SplitList(os.Getenv("PATH")) {
		if part == "" || !filepath.IsAbs(part) {
			return "", ErrUnsupportedInput
		}
	}
	path, err := exec.LookPath(name)
	if errors.Is(err, exec.ErrDot) {
		return "", ErrUnsupportedInput
	}
	if err != nil {
		return "", nil
	}
	return path, nil
}

func command(path string, args ...string) (string, bool, error) {
	cmd := exec.Command(path, args...)
	cmd.Stderr = io.Discard
	out, err := cmd.Output()
	if bytes.IndexByte(out, 0) >= 0 {
		return "", false, ErrUnsupportedInput
	}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return "", false, nil
		}
		return "", false, ErrUnsupportedInput
	}
	return strings.TrimRight(string(out), "\n"), true, nil
}

func requireTool(name string) error {
	path, err := tool(name)
	if err != nil {
		return err
	}
	if path == "" {
		return ErrUnsupportedInput
	}
	return executable(path)
}

func executable(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return ErrUnsupportedInput
	}
	defer file.Close()
	header := make([]byte, 4)
	n, err := file.Read(header)
	if err != nil && !errors.Is(err, io.EOF) {
		return ErrUnsupportedInput
	}
	header = header[:n]
	if bytes.HasPrefix(header, []byte("#!")) || bytes.HasPrefix(header, []byte("\x7fELF")) || bytes.HasPrefix(header, []byte("MZ")) {
		return nil
	}
	if n == 4 {
		magic := string(header)
		for _, supported := range []string{"\xfe\xed\xfa\xce", "\xfe\xed\xfa\xcf", "\xce\xfa\xed\xfe", "\xcf\xfa\xed\xfe", "\xca\xfe\xba\xbe", "\xca\xfe\xba\xbf"} {
			if magic == supported {
				return nil
			}
		}
	}
	return ErrUnsupportedInput
}

func lastLine(value string) string {
	values := lines(value)
	return values[len(values)-1]
}

func lines(value string) []string {
	return strings.Split(value, "\n")
}

func lineMatch(value string, pattern *regexp.Regexp) bool {
	for _, line := range lines(value) {
		if pattern.MatchString(line) {
			return true
		}
	}
	return false
}
