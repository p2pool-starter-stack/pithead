//go:build linux

package status

import "syscall"

func ctimeNS(stat *syscall.Stat_t) int64 {
	return stat.Ctim.Sec*1_000_000_000 + stat.Ctim.Nsec
}
