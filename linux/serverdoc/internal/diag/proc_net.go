package diag

import (
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// netConn — одна запись из /proc/net/tcp{,6}.
type netConn struct {
	LocalIP   net.IP
	LocalPort int
	RemoteIP  net.IP
	RemotePort int
	State     uint8 // 0x01 ESTABLISHED, 0x0A LISTEN и т.д.
	Inode     uint64
}

// TCP states из include/net/tcp_states.h ядра.
const (
	tcpEstablished = 0x01
	tcpSynSent     = 0x02
	tcpTimeWait    = 0x06
	tcpCloseWait   = 0x08
	tcpListen      = 0x0A
)

// readProcNetTCP читает /proc/net/tcp и /proc/net/tcp6 и возвращает все коннекты.
func readProcNetTCP() []netConn {
	var all []netConn
	for _, path := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		v6 := strings.HasSuffix(path, "6")
		all = append(all, parseProcNetTCP(string(b), v6)...)
	}
	return all
}

// parseProcNetTCP формат:
//
//	sl  local_address rem_address   st  tx_queue rx_queue tr tm->when retrnsmt uid timeout inode ...
//
// local/rem_address: HEX_IP:HEX_PORT. IP в little-endian hex (для IPv4).
// Для IPv6 — 32 hex символа, тоже LE по 32-битным словам.
func parseProcNetTCP(content string, isV6 bool) []netConn {
	var out []netConn
	for i, ln := range strings.Split(content, "\n") {
		if i == 0 || ln == "" { // первая строка — заголовок
			continue
		}
		fields := strings.Fields(ln)
		if len(fields) < 10 {
			continue
		}
		local := parseHexAddr(fields[1], isV6)
		rem := parseHexAddr(fields[2], isV6)
		if local.Port < 0 || rem.Port < 0 {
			continue
		}
		state, err := strconv.ParseUint(fields[3], 16, 8)
		if err != nil {
			continue
		}
		inode, _ := strconv.ParseUint(fields[9], 10, 64)
		out = append(out, netConn{
			LocalIP:    local.IP,
			LocalPort:  local.Port,
			RemoteIP:   rem.IP,
			RemotePort: rem.Port,
			State:      uint8(state),
			Inode:      inode,
		})
	}
	return out
}

type hexAddr struct {
	IP   net.IP
	Port int
}

func parseHexAddr(s string, isV6 bool) hexAddr {
	parts := strings.Split(s, ":")
	if len(parts) != 2 {
		return hexAddr{Port: -1}
	}
	port, err := strconv.ParseInt(parts[1], 16, 32)
	if err != nil {
		return hexAddr{Port: -1}
	}
	ip := parseHexIP(parts[0], isV6)
	return hexAddr{IP: ip, Port: int(port)}
}

// parseHexIP разворачивает hex-форму из /proc/net/tcp в net.IP.
// IPv4: 4 байта в LE — "0100007F" → 127.0.0.1.
// IPv6: 16 байт в виде 4-х 32-битных слов LE.
func parseHexIP(s string, isV6 bool) net.IP {
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil
	}
	if !isV6 {
		if len(b) != 4 {
			return nil
		}
		return net.IPv4(b[3], b[2], b[1], b[0])
	}
	if len(b) != 16 {
		return nil
	}
	out := make([]byte, 16)
	// Каждое 4-байтное слово в /proc little-endian.
	for i := 0; i < 16; i += 4 {
		out[i+0], out[i+1], out[i+2], out[i+3] = b[i+3], b[i+2], b[i+1], b[i+0]
	}
	return net.IP(out)
}

// readProcNetUnix возвращает map inode → path для unix-сокетов.
// Формат:
//
//	Num       RefCount Protocol Flags    Type St Inode Path
//	0000000000000000: 00000002 00000000 00010000 0001 01 12345 /run/php/php8.3-fpm-site.ru.sock
func readProcNetUnix() map[uint64]string {
	res := map[uint64]string{}
	b, err := os.ReadFile("/proc/net/unix")
	if err != nil {
		return res
	}
	for i, ln := range strings.Split(string(b), "\n") {
		if i == 0 || ln == "" {
			continue
		}
		fields := strings.Fields(ln)
		if len(fields) < 7 {
			continue
		}
		inode, err := strconv.ParseUint(fields[6], 10, 64)
		if err != nil || inode == 0 {
			continue
		}
		path := ""
		if len(fields) >= 8 {
			path = fields[7]
		}
		if path != "" {
			res[inode] = path
		}
	}
	return res
}

// pidSocketInodes возвращает inode'ы всех сокетов которые открыты процессом.
// /proc/PID/fd/N — symlink в формате "socket:[12345]".
func pidSocketInodes(pid int) []uint64 {
	dir := "/proc/" + strconv.Itoa(pid) + "/fd"
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []uint64
	for _, e := range ents {
		target, err := os.Readlink(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		if !strings.HasPrefix(target, "socket:[") {
			continue
		}
		ins := strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]")
		inode, err := strconv.ParseUint(ins, 10, 64)
		if err != nil {
			continue
		}
		out = append(out, inode)
	}
	return out
}

// buildInodeToPID — обратный индекс: каждый socket inode → PID который его держит.
// Сразу же фильтрует только PIDs где cmdline соответствует predicate (например,
// только worker'ы apache/php-fpm/php-cgi).
func buildInodeToPID(predicate func(cmdline string) bool) map[uint64]int {
	res := map[uint64]int{}
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		if predicate != nil {
			b, err := os.ReadFile("/proc/" + e.Name() + "/cmdline")
			if err != nil {
				continue
			}
			if !predicate(strings.ReplaceAll(string(b), "\x00", " ")) {
				continue
			}
		}
		for _, inode := range pidSocketInodes(pid) {
			// Если несколько процессов держат один сокет (форк) — берём первого.
			if _, exists := res[inode]; !exists {
				res[inode] = pid
			}
		}
	}
	return res
}

// localIPs — все IP сервера + 127.0.0.0/8 + 0.0.0.0. Используется чтобы
// отделить исходящие коннекты от локальных (PHP-FPM unix socket уже отдельно,
// здесь только TCP).
func localIPs() map[string]bool {
	res := map[string]bool{"0.0.0.0": true, "::": true}
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if ipNet, ok := a.(*net.IPNet); ok {
			res[ipNet.IP.String()] = true
		}
	}
	return res
}

// isLoopback — 127.0.0.0/8 или ::1.
func isLoopback(ip net.IP) bool {
	return ip != nil && ip.IsLoopback()
}
