// Package sys собирает базовую информацию о сервере и предоставляет
// безопасный хелпер для запуска внешних команд с таймаутом.
package sys

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Run выполняет команду с таймаутом и возвращает объединённый вывод
// (stdout+stderr). Многие утилиты пишут версию в stderr — поэтому combined.
func Run(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return string(out), err
}

// Have сообщает, есть ли бинарник в PATH.
func Have(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// Info — снимок состояния железа и ОС.
type Info struct {
	Hostname    string `json:"hostname"`
	OSName      string `json:"os_name"`
	OSVersion   string `json:"os_version"`
	Kernel      string `json:"kernel"`
	CPUCount    int    `json:"cpu_count"`
	MemTotalMB  int    `json:"mem_total_mb"`
	MemAvailMB  int    `json:"mem_avail_mb"`
	SwapTotalMB int    `json:"swap_total_mb"`
	SwapFreeMB  int    `json:"swap_free_mb"`
	Load1       string `json:"load1"`
}

// Collect собирает Info из /proc и /etc/os-release.
func Collect() Info {
	var i Info
	i.Hostname, _ = os.Hostname()
	i.OSName, i.OSVersion = osRelease()
	i.Kernel = strings.TrimSpace(readFile("/proc/sys/kernel/osrelease"))
	i.CPUCount = runtime.NumCPU()
	i.MemTotalMB, i.MemAvailMB, i.SwapTotalMB, i.SwapFreeMB = meminfo()
	i.Load1 = load1()
	return i
}

func readFile(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}

func osRelease() (string, string) {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return "Unknown", ""
	}
	defer f.Close()

	var name, ver string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "NAME="):
			name = unquote(line[5:])
		case strings.HasPrefix(line, "VERSION_ID="):
			ver = unquote(line[11:])
		}
	}
	if name == "" {
		name = "Unknown"
	}
	name = strings.NewReplacer(" GNU/Linux", "", " Linux", "").Replace(name)
	return name, ver
}

func unquote(s string) string {
	return strings.Trim(strings.TrimSpace(s), `"'`)
}

// meminfo читает /proc/meminfo, отдаёт значения в мегабайтах.
func meminfo() (total, avail, swapTotal, swapFree int) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return
	}
	defer f.Close()

	var memFree int
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 {
			continue
		}
		kb, _ := strconv.Atoi(fields[1])
		mb := kb / 1024
		switch fields[0] {
		case "MemTotal:":
			total = mb
		case "MemAvailable:":
			avail = mb
		case "MemFree:":
			memFree = mb
		case "SwapTotal:":
			swapTotal = mb
		case "SwapFree:":
			swapFree = mb
		}
	}
	// На старых ядрах нет MemAvailable — откатываемся к MemFree.
	if avail == 0 {
		avail = memFree
	}
	return
}

func load1() string {
	fields := strings.Fields(readFile("/proc/loadavg"))
	if len(fields) > 0 {
		return fields[0]
	}
	return "-"
}
