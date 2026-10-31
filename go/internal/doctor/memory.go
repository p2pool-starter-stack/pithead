package doctor

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

var ErrUnsupportedProbeInput = errors.New("unsupported doctor probe input")

const (
	defaultMeminfo = "/proc/meminfo"
	defaultMarker  = "/run/pithead-hugepages-degraded"
	hugePages      = 3072
	randomXDataset = 1040
	randomXPages   = 1296
)

type Finding struct {
	ID      string
	Status  string
	Message string
}

type Memory struct {
	Meminfo   string
	Marker    string
	Appliance bool
}

func (memory Memory) Reserved() (Finding, error) {
	meminfo := memory.meminfo()
	total, totalSupported := meminfoValue(meminfo, "HugePages_Total")
	free, freeSupported := meminfoValue(meminfo, "HugePages_Free")
	if !totalSupported || !freeSupported {
		return Finding{}, ErrUnsupportedProbeInput
	}
	needText, supported := decisionPages(memory.marker())
	if !supported {
		return Finding{}, ErrUnsupportedProbeInput
	}
	need, _ := strconv.ParseInt(needText, 10, 64)
	who := "this machine needs for RandomX"
	if need < randomXPages {
		need = randomXPages
		needText = strconv.Itoa(randomXPages)
		who = "P2Pool's RandomX dataset and its two caches need"
	}

	totalNumber, valid := decimal(total)
	if !valid {
		if digits(total) {
			return Finding{}, ErrUnsupportedProbeInput
		}
		return Finding{"hugepages", "warn", fmt.Sprintf("Could not read HugePages from %s.", meminfo)}, nil
	}
	if totalNumber >= need {
		if free == "" {
			free = "?"
		}
		return Finding{"hugepages", "ok", fmt.Sprintf("HugePages reserved: %s total, %s free (RandomX uses these).", total, free)}, nil
	}

	fallback := "P2Pool puts its RandomX dataset (1040 pages) and caches in ordinary RAM instead: up to 2592 MiB, which its 4 GiB memory limit holds but the rest of the machine loses."
	short := "HugePages_Total is 0: " + fallback
	if totalNumber != 0 {
		arithmeticNeed, needValid := bashArithmetic(needText)
		arithmeticTotal, totalValid := bashArithmetic(total)
		if !needValid || !totalValid {
			return Finding{}, ErrUnsupportedProbeInput
		}
		shortage := arithmeticNeed - arithmeticTotal
		short = fmt.Sprintf("HugePages reserved: only %s of the %s pages %s (%d MiB short).", total, needText, who, shortage*2)
		if totalNumber < randomXDataset {
			short += " That is too few for P2Pool's RandomX dataset: " + fallback
		} else {
			short += " If monerod's own RandomX pages leave fewer than 1040 free when P2Pool starts, " + fallback
		}
	}
	if memory.Appliance {
		short += " There is no dashboard control that reserves them."
	} else {
		short += " Run './pithead setup' (kernel optimization) to grow the pool. For persistence, accept setup's GRUB drop-in and reboot after it verifies the generated kernel entries; a reboot also fills a pool that fragmented memory cannot."
	}
	return Finding{"hugepages", "warn", short}, nil
}

func (memory Memory) Degraded() ([]Finding, error) {
	marker := memory.marker()
	info, err := os.Stat(marker)
	if err != nil || !info.Mode().IsRegular() {
		return nil, nil
	}
	file, err := os.Open(marker)
	if err != nil {
		return nil, ErrUnsupportedProbeInput
	}
	defer file.Close()
	message, readErr := bufio.NewReader(file).ReadString('\n')
	if readErr != nil && !errors.Is(readErr, io.EOF) {
		return nil, ErrUnsupportedProbeInput
	}
	message = strings.TrimSuffix(message, "\n")
	if strings.ContainsRune(message, 0) {
		return nil, ErrUnsupportedProbeInput
	}
	message = strings.ReplaceAll(message, "\t", " ")
	return []Finding{{"hugepages-degraded", "warn", message}}, nil
}

func (memory Memory) Available() (Finding, error) {
	available, supported := meminfoValue(memory.meminfo(), "MemAvailable")
	if !supported {
		return Finding{}, ErrUnsupportedProbeInput
	}
	if available == "" {
		return Finding{"free-ram", "warn", "Could not read MemAvailable from /proc/meminfo."}, nil
	}
	kib, valid := bashArithmetic(available)
	if !valid {
		return Finding{}, ErrUnsupportedProbeInput
	}
	mib := kib / 1024
	if mib >= 2048 {
		return Finding{"free-ram", "ok", fmt.Sprintf("Free RAM: %d MiB available.", mib)}, nil
	}
	return Finding{"free-ram", "warn", fmt.Sprintf("Free RAM low: %d MiB available — the stack (Tari especially) may be memory-starved.", mib)}, nil
}

func DecisionPages(marker string) string {
	pages, _ := decisionPages(marker)
	return pages
}

func decisionPages(marker string) (string, bool) {
	if marker == "" {
		marker = defaultMarker
	}
	file, err := os.Open(marker)
	if err != nil {
		return strconv.Itoa(hugePages), true
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	for {
		line, readErr := reader.ReadString('\n')
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return strconv.Itoa(hugePages), false
		}
		if strings.ContainsRune(line, 0) {
			return strconv.Itoa(hugePages), false
		}
		line = strings.TrimSuffix(line, "\n")
		if !strings.HasPrefix(line, "pages=") {
			if readErr != nil {
				break
			}
			continue
		}
		pages := strings.TrimPrefix(line, "pages=")
		if digits(pages) {
			value, parseErr := strconv.ParseInt(pages, 10, 64)
			if parseErr != nil {
				return strconv.Itoa(hugePages), false
			}
			if value < hugePages {
				return pages, true
			}
			return strconv.Itoa(hugePages), true
		}
		if readErr != nil {
			break
		}
	}
	return strconv.Itoa(hugePages), true
}

func (memory Memory) meminfo() string {
	if memory.Meminfo != "" {
		return memory.Meminfo
	}
	return defaultMeminfo
}

func (memory Memory) marker() string {
	if memory.Marker != "" {
		return memory.Marker
	}
	return defaultMarker
}

func meminfoValue(path, name string) (string, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", true
	}
	defer file.Close()
	values := make([]string, 0, 1)
	reader := bufio.NewReader(file)
	for {
		line, readErr := reader.ReadString('\n')
		line = strings.TrimSuffix(line, "\n")
		if strings.HasPrefix(line, name) {
			fields := strings.FieldsFunc(line, func(character rune) bool {
				return character == ' ' || character == '\t'
			})
			if len(fields) > 1 {
				if strings.ContainsRune(fields[1], 0) {
					return "", false
				}
				values = append(values, fields[1])
			} else {
				values = append(values, "")
			}
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) {
				return "", false
			}
			break
		}
	}
	return strings.TrimRight(strings.Join(values, "\n"), "\n"), true
}

func decimal(value string) (int64, bool) {
	if !digits(value) {
		return 0, false
	}
	number, err := strconv.ParseInt(value, 10, 64)
	return number, err == nil
}

func digits(value string) bool {
	if value == "" {
		return false
	}
	for _, digit := range value {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
}

func bashArithmetic(value string) (int64, bool) {
	base := 10
	digitsAt := 0
	if len(value) > 0 && (value[0] == '+' || value[0] == '-') {
		digitsAt = 1
	}
	if len(value)-digitsAt > 1 && value[digitsAt] == '0' {
		base = 8
	}
	number, err := strconv.ParseInt(value, base, 64)
	return number, err == nil
}
