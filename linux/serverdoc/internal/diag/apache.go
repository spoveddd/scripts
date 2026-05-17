package diag

import (
	"bufio"
	"bytes"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"serverdoc/internal/stack"
)

// ApacheState — живое состояние и эффективные настройки Apache.
type ApacheState struct {
	// Workers
	WorkersAlive       int  `json:"workers_alive"`
	MaxRequestWorkers  int  `json:"max_request_workers"`
	MaxIsDefault       bool `json:"max_is_default,omitempty"` // не нашли в конфигах — взяли compile-time default
	UtilizationPercent int  `json:"utilization_percent"`
	AvgWorkerRSSMB     int  `json:"avg_worker_rss_mb,omitempty"` // средний RSS воркера
	ProjectedRAMMB     int  `json:"projected_ram_mb,omitempty"`  // AvgWorker × MaxRequestWorkers

	// Effective config (последнее найденное значение по всем .conf)
	Config ApacheConfig `json:"config"`

	ErrorLogPath    string   `json:"error_log_path,omitempty"`
	RecentMPMErrors []string `json:"recent_mpm_errors,omitempty"` // последние MPM-сообщения за 24ч
	NeedsAttention  bool     `json:"needs_attention"`
}

// ApacheConfig — ключевые директивы MPM/таймаутов/keepalive.
type ApacheConfig struct {
	StartServers           int    `json:"start_servers,omitempty"`
	MinSpareServers        int    `json:"min_spare_servers,omitempty"`
	MaxSpareServers        int    `json:"max_spare_servers,omitempty"`
	ServerLimit            int    `json:"server_limit,omitempty"`
	MaxConnectionsPerChild int    `json:"max_connections_per_child,omitempty"`
	ThreadsPerChild        int    `json:"threads_per_child,omitempty"`
	ThreadLimit            int    `json:"thread_limit,omitempty"`
	Timeout                int    `json:"timeout,omitempty"`
	KeepAlive              string `json:"keepalive,omitempty"` // "On"/"Off"
	KeepAliveTimeout       int    `json:"keepalive_timeout,omitempty"`
	MaxKeepAliveRequests   int    `json:"max_keepalive_requests,omitempty"`
}

func analyzeApache(a *stack.Apache) *ApacheState {
	if a == nil || !a.Running {
		return nil
	}

	st := &ApacheState{
		WorkersAlive: countApacheWorkers(a.Binary),
		ErrorLogPath: findApacheErrorLog(a.Binary),
	}

	cfg, maxWorkers := scanApacheConfig()
	st.Config = cfg
	st.MaxRequestWorkers = maxWorkers
	if st.MaxRequestWorkers == 0 {
		st.MaxRequestWorkers = compileDefaultMaxWorkers(a.MPM)
		st.MaxIsDefault = true
	}
	if st.MaxRequestWorkers > 0 {
		st.UtilizationPercent = 100 * st.WorkersAlive / st.MaxRequestWorkers
	}
	st.AvgWorkerRSSMB = ApacheWorkerAvgRSS(a.Binary)
	if st.AvgWorkerRSSMB > 0 && st.MaxRequestWorkers > 0 {
		st.ProjectedRAMMB = st.AvgWorkerRSSMB * st.MaxRequestWorkers
	}
	if st.ErrorLogPath != "" {
		st.RecentMPMErrors = scanApacheErrorLog(st.ErrorLogPath, 24*time.Hour)
	}
	st.NeedsAttention = st.UtilizationPercent >= 85 || len(st.RecentMPMErrors) > 0
	return st
}

// compileDefaultMaxWorkers возвращает дефолт MaxRequestWorkers если не задан:
// prefork = 256, event/worker = 400 (ServerLimit 16 × ThreadsPerChild 25).
func compileDefaultMaxWorkers(mpm string) int {
	switch mpm {
	case "event", "worker":
		return 400
	default:
		return 256
	}
}

// countApacheWorkers — все процессы apache2/httpd минус мастер.
func countApacheWorkers(bin string) int {
	pids := pidsByCmdline(bin)
	masters := 0
	for _, pid := range pids {
		if procPPID(pid) == 1 {
			masters++
		}
	}
	if masters == 0 {
		if len(pids) > 0 {
			return len(pids) - 1
		}
		return 0
	}
	return len(pids) - masters
}

// scanApacheConfig сканирует все .conf файлы Apache и возвращает
// последнее найденное значение по каждой директиве + max(MaxRequestWorkers).
func scanApacheConfig() (ApacheConfig, int) {
	roots := []string{
		"/etc/apache2", // Debian/Ubuntu
		"/etc/httpd",   // RHEL/CentOS/Alma
	}

	var cfg ApacheConfig
	maxWorkers := 0

	for _, root := range roots {
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if !strings.HasSuffix(path, ".conf") {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			parseApacheDirectives(string(data), &cfg, &maxWorkers)
			return nil
		})
	}
	return cfg, maxWorkers
}

var apacheDirectiveRe = regexp.MustCompile(
	`(?im)^\s*(MaxRequestWorkers|MaxClients|StartServers|MinSpareServers|MaxSpareServers|ServerLimit|MaxConnectionsPerChild|MaxRequestsPerChild|ThreadsPerChild|ThreadLimit|Timeout|KeepAlive|KeepAliveTimeout|MaxKeepAliveRequests)\s+(\S+)`)

// parseApacheDirectives ищет директивы в одном файле. Несколько встретившихся
// значений одной директивы — берём последнее (как Apache на самом деле).
// Для MaxRequestWorkers возвращаем max — обычно так, но если в конфигах
// явно две секции под разные MPM, активный — один из них; брать max безопаснее.
func parseApacheDirectives(content string, cfg *ApacheConfig, maxWorkers *int) {
	for _, m := range apacheDirectiveRe.FindAllStringSubmatch(content, -1) {
		name, val := m[1], m[2]
		switch strings.ToLower(name) {
		case "maxrequestworkers", "maxclients":
			if v, err := strconv.Atoi(val); err == nil && v > *maxWorkers {
				*maxWorkers = v
			}
		case "startservers":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.StartServers = v
			}
		case "minspareservers":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.MinSpareServers = v
			}
		case "maxspareservers":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.MaxSpareServers = v
			}
		case "serverlimit":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.ServerLimit = v
			}
		case "maxconnectionsperchild", "maxrequestsperchild":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.MaxConnectionsPerChild = v
			}
		case "threadsperchild":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.ThreadsPerChild = v
			}
		case "threadlimit":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.ThreadLimit = v
			}
		case "timeout":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.Timeout = v
			}
		case "keepalive":
			// Принимаем On/Off/0/1 как строку с нормализацией.
			v := strings.Title(strings.ToLower(val))
			if v == "1" {
				v = "On"
			} else if v == "0" {
				v = "Off"
			}
			cfg.KeepAlive = v
		case "keepalivetimeout":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.KeepAliveTimeout = v
			}
		case "maxkeepaliverequests":
			if v, err := strconv.Atoi(val); err == nil {
				cfg.MaxKeepAliveRequests = v
			}
		}
	}
}

func findApacheErrorLog(bin string) string {
	candidates := []string{
		"/var/log/apache2/error.log",
		"/var/log/httpd/error_log",
	}
	if bin == "httpd" {
		candidates = []string{candidates[1], candidates[0]}
	}
	for _, p := range candidates {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}
	return ""
}

func scanApacheErrorLog(path string, maxAge time.Duration) []string {
	const tailBytes = 256 * 1024
	data, err := readTail(path, tailBytes)
	if err != nil {
		return nil
	}
	cutoff := time.Now().Add(-maxAge)
	var out []string
	seen := map[string]bool{}
	for _, ln := range strings.Split(string(data), "\n") {
		if !mpmErrRe.MatchString(ln) {
			continue
		}
		ts := parseApacheTimestamp(ln)
		if !ts.IsZero() && ts.Before(cutoff) {
			continue
		}
		key := mpmErrRe.FindString(ln)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, strings.TrimSpace(ln))
		if len(out) >= 10 {
			break
		}
	}
	return out
}

var (
	mpmErrRe     = regexp.MustCompile(`AH00(484|161|045|046)|MaxRequestWorkers|scoreboard is full`)
	apacheTimeRe = regexp.MustCompile(`\[([A-Z][a-z]{2} [A-Z][a-z]{2} \d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)? \d{4})\]`)
)

func parseApacheTimestamp(ln string) time.Time {
	m := apacheTimeRe.FindStringSubmatch(ln)
	if m == nil {
		return time.Time{}
	}
	for _, layout := range []string{
		"Mon Jan 02 15:04:05.000000 2006",
		"Mon Jan 02 15:04:05 2006",
	} {
		if t, err := time.Parse(layout, m[1]); err == nil {
			return t
		}
	}
	return time.Time{}
}

func readTail(path string, n int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if fi.Size() > n {
		if _, err := f.Seek(fi.Size()-n, io.SeekStart); err != nil {
			return nil, err
		}
	}
	buf := bytes.NewBuffer(nil)
	_, err = io.Copy(buf, f)
	return buf.Bytes(), err
}

func pidsByCmdline(needle string) []int {
	var pids []int
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/cmdline")
		if err != nil || len(b) == 0 {
			continue
		}
		cl := strings.ReplaceAll(string(b), "\x00", " ")
		if strings.Contains(cl, needle) {
			pids = append(pids, pid)
		}
	}
	sort.Ints(pids)
	return pids
}

func procPPID(pid int) int {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return 0
	}
	for _, ln := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(ln, "PPid:") {
			ppid, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(ln, "PPid:")))
			return ppid
		}
	}
	return 0
}

// procRSSMB читает VmRSS из /proc/<pid>/status, возвращает RSS в MB.
func procRSSMB(pid int) int {
	f, err := os.Open("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		ln := sc.Text()
		if strings.HasPrefix(ln, "VmRSS:") {
			fields := strings.Fields(strings.TrimPrefix(ln, "VmRSS:"))
			if len(fields) > 0 {
				kb, _ := strconv.Atoi(fields[0])
				return kb / 1024
			}
		}
	}
	return 0
}

// ApacheWorkerAvgRSS — средний RSS apache воркеров (без мастера) в MB.
// Полезно для прикидки потребления памяти при росте до MaxRequestWorkers.
func ApacheWorkerAvgRSS(bin string) int {
	pids := pidsByCmdline(bin)
	if len(pids) == 0 {
		return 0
	}
	totalMB, count := 0, 0
	for _, pid := range pids {
		if procPPID(pid) == 1 {
			continue // мастер
		}
		mb := procRSSMB(pid)
		if mb > 0 {
			totalMB += mb
			count++
		}
	}
	if count == 0 {
		return 0
	}
	return totalMB / count
}
