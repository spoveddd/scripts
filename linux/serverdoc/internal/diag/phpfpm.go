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
}

// FPMPool — один пул php-fpm.
type FPMPool struct {
	Name               string `json:"name"`
	MaxChildren        int    `json:"max_children"`
	WorkersAlive       int    `json:"workers_alive"`
	UtilizationPercent int    `json:"utilization_percent"`
}

func analyzeFPM(php []stack.PHPVersion) []FPMState {
	if len(php) == 0 {
		return nil
	}

	// Один раз пробегаем /proc: собираем мастера (cmdline → версия) и
	// воркеры (cmdline → имя пула, PPID → master PID → версия).
	masters, workers := scanFPMProcesses()

	// Сгруппируем воркеры по (version, pool_name).
	type vp struct{ ver, pool string }
	workersByVP := map[vp]int{}
	for _, w := range workers {
		master, ok := masters[w.ppid]
		if !ok {
			continue
		}
		workersByVP[vp{master, w.pool}]++
	}

	var out []FPMState
	for _, p := range php {
		if p.PoolDir == "" {
			// Без каталога пулов мы не знаем pm.max_children — пропускаем
			// (мастер мог быть запущен, но конфиги в нестандартном месте).
			continue
		}
		pools := parseFPMPools(p.PoolDir)
		if len(pools) == 0 {
			continue
		}
		st := FPMState{Version: p.Version}
		for i := range pools {
			pools[i].WorkersAlive = workersByVP[vp{p.Version, pools[i].Name}]
			if pools[i].MaxChildren > 0 {
				pools[i].UtilizationPercent = 100 * pools[i].WorkersAlive / pools[i].MaxChildren
			}
			st.MaxChildrenTotal += pools[i].MaxChildren
			st.WorkersTotal += pools[i].WorkersAlive
		}
		if st.MaxChildrenTotal > 0 {
			st.UtilizationPercent = 100 * st.WorkersTotal / st.MaxChildrenTotal
		}
		// Сортируем пулы по убыванию утилизации — самые горячие наверху.
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
	// Версия из пути конфига мастера: см. stack.versionFromConfigPath.
	verEtcRe = regexp.MustCompile(`/etc/php/(\d+\.\d+)/`)
	verOptRe = regexp.MustCompile(`/(?:opt|etc/opt/remi)/php(\d)(\d+)/`)
)

// scanFPMProcesses возвращает карту PID мастера → версия PHP, и список воркеров.
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

// parseFPMPools читает все *.conf в poolDir (нерекурсивно) и возвращает
// список пулов с pm.max_children. Фильтрует служебные имена.
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
	poolMaxChRe   = regexp.MustCompile(`^\s*pm\.max_children\s*=\s*(\d+)`)
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
		if m := poolSectionRe.FindStringSubmatch(ln); m != nil && p.Name == "" {
			p.Name = m[1]
		}
		if m := poolMaxChRe.FindStringSubmatch(ln); m != nil {
			v, _ := strconv.Atoi(m[1])
			p.MaxChildren = v
		}
	}
	return p
}
