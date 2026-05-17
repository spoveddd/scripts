package diag

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"serverdoc/internal/stack"
)

// FPMState — живое состояние одной PHP-версии (FPM).
type FPMState struct {
	Version            string    `json:"version"`
	Pools              []FPMPool `json:"pools,omitempty"`
	WorkersTotal       int       `json:"workers_total"`
	MaxChildrenTotal   int       `json:"max_children_total"`
	UtilizationPercent int       `json:"utilization_percent"`
	AvgWorkerRSSMB     int       `json:"avg_worker_rss_mb,omitempty"`
	ProjectedRAMMB     int       `json:"projected_ram_mb,omitempty"` // Σ max_children × avgRSS
}

// FPMPool — один пул php-fpm со всем что важно для аудита.
type FPMPool struct {
	Name                    string `json:"name"`
	PM                      string `json:"pm,omitempty"` // dynamic/static/ondemand
	MaxChildren             int    `json:"max_children"`
	StartServers            int    `json:"start_servers,omitempty"`
	MinSpareServers         int    `json:"min_spare_servers,omitempty"`
	MaxSpareServers         int    `json:"max_spare_servers,omitempty"`
	MaxRequests             int    `json:"max_requests"` // 0 = нет ротации (memleak risk)
	RequestTerminateTimeout int    `json:"request_terminate_timeout_sec"`
	SlowlogPath             string `json:"slowlog_path,omitempty"`
	SlowlogTimeout          int    `json:"slowlog_timeout_sec,omitempty"`
	WorkersAlive            int    `json:"workers_alive"`
	UtilizationPercent      int    `json:"utilization_percent"`
}

func analyzeFPM(php []stack.PHPVersion) []FPMState {
	if len(php) == 0 {
		return nil
	}

	masters, workers := scanFPMProcesses()

	// PIDs всех воркеров с привязкой к (version, pool).
	type vp struct{ ver, pool string }
	workersByVP := map[vp][]int{}
	for _, w := range workers {
		master, ok := masters[w.ppid]
		if !ok {
			continue
		}
		k := vp{master, w.pool}
		workersByVP[k] = append(workersByVP[k], w.pid)
	}

	var out []FPMState
	for _, p := range php {
		if p.PoolDir == "" {
			continue
		}
		pools := parseFPMPools(p.PoolDir)
		if len(pools) == 0 {
			continue
		}
		st := FPMState{Version: p.Version}
		var rssSum, rssCount int
		for i := range pools {
			pids := workersByVP[vp{p.Version, pools[i].Name}]
			pools[i].WorkersAlive = len(pids)
			for _, pid := range pids {
				mb := procRSSMB(pid)
				if mb > 0 {
					rssSum += mb
					rssCount++
				}
			}
			if pools[i].MaxChildren > 0 {
				pools[i].UtilizationPercent = 100 * pools[i].WorkersAlive / pools[i].MaxChildren
			}
			st.MaxChildrenTotal += pools[i].MaxChildren
			st.WorkersTotal += pools[i].WorkersAlive
		}
		if rssCount > 0 {
			st.AvgWorkerRSSMB = rssSum / rssCount
		}
		if st.AvgWorkerRSSMB > 0 && st.MaxChildrenTotal > 0 {
			st.ProjectedRAMMB = st.AvgWorkerRSSMB * st.MaxChildrenTotal
		}
		if st.MaxChildrenTotal > 0 {
			st.UtilizationPercent = 100 * st.WorkersTotal / st.MaxChildrenTotal
		}
		sort.SliceStable(pools, func(i, j int) bool {
			return pools[i].UtilizationPercent > pools[j].UtilizationPercent
		})
		st.Pools = pools
		out = append(out, st)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	return out
}

type fpmWorker struct {
	pid  int
	ppid int
	pool string
}

var (
	fpmMasterCmdRe = regexp.MustCompile(`php-fpm:\s*master\s+process\s+\(([^)]+)\)`)
	fpmPoolCmdRe   = regexp.MustCompile(`php-fpm:\s*pool\s+(\S+)`)
	verEtcRe       = regexp.MustCompile(`/etc/php/(\d+\.\d+)/`)
	verOptRe       = regexp.MustCompile(`/(?:opt|etc/opt/remi)/php(\d)(\d+)/`)
)

func scanFPMProcesses() (map[int]string, []fpmWorker) {
	masters := map[int]string{}
	var workers []fpmWorker

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

		if m := fpmMasterCmdRe.FindStringSubmatch(cl); m != nil {
			if v := versionFromPath(m[1]); v != "" {
				masters[pid] = v
			}
			continue
		}
		if m := fpmPoolCmdRe.FindStringSubmatch(cl); m != nil {
			workers = append(workers, fpmWorker{
				pid:  pid,
				ppid: procPPID(pid),
				pool: m[1],
			})
		}
	}
	return masters, workers
}

func versionFromPath(p string) string {
	if m := verEtcRe.FindStringSubmatch(p); m != nil {
		return m[1]
	}
	if m := verOptRe.FindStringSubmatch(p); m != nil {
		return m[1] + "." + m[2]
	}
	return ""
}

func parseFPMPools(poolDir string) []FPMPool {
	ents, err := os.ReadDir(poolDir)
	if err != nil {
		return nil
	}
	var out []FPMPool
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".conf") {
			continue
		}
		if strings.HasSuffix(name, ".default") || name == "www.conf" || name == "dummy.conf" {
			continue
		}
		p := readPoolConf(filepath.Join(poolDir, name))
		if p.Name == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

var (
	poolSectionRe = regexp.MustCompile(`^\[([^\]]+)\]`)
	// Все интересные директивы. Значение — после = с возможными пробелами.
	poolDirectiveRe = regexp.MustCompile(`^\s*(pm|pm\.max_children|pm\.start_servers|pm\.min_spare_servers|pm\.max_spare_servers|pm\.max_requests|request_terminate_timeout|slowlog|request_slowlog_timeout)\s*=\s*(.+?)\s*$`)
)

func readPoolConf(path string) FPMPool {
	var p FPMPool
	f, err := os.Open(path)
	if err != nil {
		return p
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		ln := sc.Text()
		// Пропускаем комментарии.
		trim := strings.TrimSpace(ln)
		if strings.HasPrefix(trim, ";") || strings.HasPrefix(trim, "#") {
			continue
		}
		if m := poolSectionRe.FindStringSubmatch(ln); m != nil && p.Name == "" {
			p.Name = m[1]
			continue
		}
		m := poolDirectiveRe.FindStringSubmatch(ln)
		if m == nil {
			continue
		}
		val := m[2]
		switch m[1] {
		case "pm":
			p.PM = val
		case "pm.max_children":
			p.MaxChildren = atoiOr(val, 0)
		case "pm.start_servers":
			p.StartServers = atoiOr(val, 0)
		case "pm.min_spare_servers":
			p.MinSpareServers = atoiOr(val, 0)
		case "pm.max_spare_servers":
			p.MaxSpareServers = atoiOr(val, 0)
		case "pm.max_requests":
			p.MaxRequests = atoiOr(val, 0)
		case "request_terminate_timeout":
			p.RequestTerminateTimeout = parseDurationSec(val)
		case "slowlog":
			p.SlowlogPath = val
		case "request_slowlog_timeout":
			p.SlowlogTimeout = parseDurationSec(val)
		}
	}
	return p
}

// atoiOr — int с дефолтом при ошибке.
func atoiOr(s string, def int) int {
	v, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return def
	}
	return v
}

// parseDurationSec — поддерживает "30s", "5m", "1h" и просто число (секунды).
// PHP-FPM формат коротких единиц.
func parseDurationSec(s string) int {
	s = strings.TrimSpace(s)
	if s == "" || s == "0" {
		return 0
	}
	suf := s[len(s)-1]
	num := s
	mult := 1
	switch suf {
	case 's':
		num = s[:len(s)-1]
	case 'm':
		num, mult = s[:len(s)-1], 60
	case 'h':
		num, mult = s[:len(s)-1], 3600
	case 'd':
		num, mult = s[:len(s)-1], 86400
	}
	v, err := strconv.Atoi(strings.TrimSpace(num))
	if err != nil {
		return 0
	}
	return v * mult
}
