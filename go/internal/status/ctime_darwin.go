//go:build darwin

package status

import "syscall"

func ctimeNS(stat *syscall.Stat_t) int64 {
	return stat.Ctimespec.Sec*1_000_000_000 + stat.Ctimespec.Nsec
}
