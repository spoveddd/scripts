package diag

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// StuckWorkersState — результат поиска зависших воркеров через сэмплинг.
type StuckWorkersState struct {
	Skipped       bool          `json:"skipped,omitempty"`        // если sampling выключен флагом
	Samples       int           `json:"samples"`                  // обычно 3
	SampleSpanMs  int           `json:"sample_span_ms"`           // полная длительность сэмпла
	WorkersTotal  int           `json:"workers_total"`            // сколько worker-процессов в момент сэмпла
	StuckCount    int           `json:"stuck_count"`              // сколько обнаружено зависших
	Workers       []StuckWorker `json:"workers,omitempty"`        // top-N по приоритету
}

// StuckWorker — один зависший воркер с привязкой.
type StuckWorker struct {
	PID         int      `json:"pid"`
	Process     string   `json:"process"`           // "apache2"/"php-fpm"/"php-cgi"
	State       string   `json:"state"`             // "D"/"S"
	Site        string   `json:"site,omitempty"`    // привязанный сайт если найден
	Pool        string   `json:"pool,omitempty"`    // имя пула php-fpm
	Wchan       string   `json:"wchan,omitempty"`   // имя функции ядра где висит
	RSSMB       int      `json:"rss_mb,omitempty"`
	CPUTickInc  int      `json:"cpu_tick_inc"`      // прирост utime+stime между snapshot 1 и 3
	CmdHead     string   `json:"cmd_head,omitempty"`
	Outbound    []string `json:"outbound,omitempty"` // активные remote endpoints
}

const (
	stuckSamples     = 3
	stuckIntervalMs  = 1500
)

// analyzeStuck делает 3 снапшота состояния процессов и находит worker'ы,
// у которых между снэпшотами state не менялся и CPU не использовался.
func analyzeStuck() *StuckWorkersState {
	st := &StuckWorkersState{Samples: stuckSamples, SampleSpanMs: stuckIntervalMs * (stuckSamples - 1)}
	snapshots := make([]map[int]procSnap, 0, stuckSamples)

	for i := 0; i < stuckSamples; i++ {
		snapshots = append(snapshots, takeProcSnapshot())
		if i < stuckSamples-1 {
			time.Sleep(time.Duration(stuckIntervalMs) * time.Millisecond)
		}
	}

	// Кандидаты: есть во всех 3 снэпшотах, state не менялся, CPU не вырос.
	type cand struct {
		pid        int
		first      procSnap
		last       procSnap
		cpuTickInc int
	}
	var candidates []cand
	for pid, sFirst := range snapshots[0] {
		// Только worker-процессы. Хотим: apache, php-fpm worker, php-cgi.
		if !isStuckCandidate(sFirst.Cmdline) {
			continue
		}
		st.WorkersTotal++
		sMid, okMid := snapshots[1][pid]
		sLast, okLast := snapshots[stuckSamples-1][pid]
		if !okMid || !okLast {
			continue
		}
		if sFirst.State != sMid.State || sFirst.State != sLast.State {
			continue
		}
		// State "R" (running) пропускаем — он легитимно работает.
		if sFirst.State == "R" {
			continue
		}
		// D-state почти всегда зависание. S-state — спим, но если CPU не растёт
		// и есть outbound connection — тоже завис (PHP ждёт ответа).
		cpuInc := sLast.CPUTicks - sFirst.CPUTicks
		if cpuInc > 0 {
			continue
		}
		candidates = append(candidates, cand{pid: pid, first: sFirst, last: sLast, cpuTickInc: cpuInc})
	}

	// Привязка: получим карту PID → исходящие endpoints (через те же helpers).
	outbound := outboundByPID()

	// Карты для маппинга PHP-FPM unix socket → имя сайта.
	unixByInode := readProcNetUnix()

	for _, ca := range candidates {
		w := StuckWorker{
			PID:        ca.pid,
			Process:    ca.first.Comm,
			State:      ca.first.State,
			Wchan:      readWchan(ca.pid),
			RSSMB:      procRSSMB(ca.pid),
			CPUTickInc: ca.cpuTickInc,
			CmdHead:    truncStr(ca.first.Cmdline, 100),
		}

		// Привязка к сайту:
		// 1) php-fpm worker — cmdline даёт "pool X" напрямую.
		if m := fpmPoolCmdRe.FindStringSubmatch(ca.first.Cmdline); m != nil {
			w.Pool = m[1]
			w.Site = w.Pool // часто pool == domain (Hestia)
		}
		// 2) apache/php-cgi — ищем unix-сокет на php-fpm в /proc/PID/fd.
		if w.Site == "" {
			w.Site = siteFromPHPSocket(ca.pid, unixByInode)
		}

		// Исходящие endpoints. Только ESTABLISHED + SYN_SENT — то что зависает.
		if eps, ok := outbound[ca.pid]; ok {
			w.Outbound = eps
		}

		st.Workers = append(st.Workers, w)
	}
	st.StuckCount = len(st.Workers)

	// Сортируем: сначала D-state, потом с outbound (точно ждут внешний ответ),
	// потом с привязкой к сайту — самые полезные сверху.
	sort.SliceStable(st.Workers, func(i, j int) bool {
		score := func(w StuckWorker) int {
			s := 0
			if w.State == "D" {
				s += 100
			}
			if len(w.Outbound) > 0 {
				s += 50
			}
			if w.Site != "" {
				s += 10
			}
			return s
		}
		return score(st.Workers[i]) > score(st.Workers[j])
	})
	if len(st.Workers) > 15 {
		st.Workers = st.Workers[:15]
	}
	return st
}

// procSnap — снэпшот одного PID.
type procSnap struct {
	State    string // R, S, D, Z
	Comm     string
	Cmdline  string
	CPUTicks int // utime+stime из /proc/PID/stat
}

func takeProcSnapshot() map[int]procSnap {
	res := map[int]procSnap{}
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		stat, ok := readStat(pid)
		if !ok {
			continue
		}
		cmdline, _ := os.ReadFile("/proc/" + e.Name() + "/cmdline")
		res[pid] = procSnap{
			State:    stat.State,
			Comm:     stat.Comm,
			Cmdline:  strings.ReplaceAll(string(cmdline), "\x00", " "),
			CPUTicks: stat.UTime + stat.STime,
		}
	}
	return res
}

// statFields — релевантные поля из /proc/PID/stat.
type statFields struct {
	State string
	Comm  string
	UTime int
	STime int
}

// readStat парсит /proc/PID/stat. Формат:
//
//	pid (comm) state ppid ... utime stime ...
//
// Тут (comm) может содержать пробелы и скобки — берём содержимое между
// первой "(" и последней ")".
func readStat(pid int) (statFields, bool) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return statFields{}, false
	}
	s := string(b)
	l := strings.Index(s, "(")
	r := strings.LastIndex(s, ")")
	if l < 0 || r < 0 || r < l {
		return statFields{}, false
	}
	comm := s[l+1 : r]
	after := strings.Fields(s[r+1:])
	if len(after) < 13 {
		return statFields{}, false
	}
	state := after[0]
	utime, _ := strconv.Atoi(after[11])
	stime, _ := strconv.Atoi(after[12])
	return statFields{State: state, Comm: comm, UTime: utime, STime: stime}, true
}

// isStuckCandidate — только web/script worker'ы.
// Master-процессы не нужны (они тоже могут спать).
var fpmWorkerStuckRe = regexp.MustCompile(`php-fpm:\s*pool\s+`)

func isStuckCandidate(cmdline string) bool {
	if strings.Contains(cmdline, "php-fpm: master") {
		return false
	}
	if fpmWorkerStuckRe.MatchString(cmdline) {
		return true
	}
	for _, k := range []string{"apache2", "httpd", "php-cgi"} {
		if strings.Contains(cmdline, k) {
			return true
		}
	}
	return false
}

func readWchan(pid int) string {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/wchan")
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(b))
	if s == "0" {
		return ""
	}
	return s
}

// siteFromPHPSocket — для apache/php-cgi воркера ищем подключение к
// php-fpm unix-сокету и достаём из имени сокета домен.
// Имя у Hestia: /run/php/php8.3-fpm-<domain>.sock.
// У ISP/FastPanel может быть другое, но мы достаём базу имени без расширения.
var fpmSockRe = regexp.MustCompile(`php\d+\.\d+-fpm-(.+?)\.sock`)

func siteFromPHPSocket(pid int, unixByInode map[uint64]string) string {
	for _, inode := range pidSocketInodes(pid) {
		path, ok := unixByInode[inode]
		if !ok {
			continue
		}
		if !strings.Contains(path, "fpm") || !strings.HasSuffix(path, ".sock") {
			continue
		}
		if m := fpmSockRe.FindStringSubmatch(filepath.Base(path)); m != nil {
			return m[1]
		}
		// Если формат другой — вернём имя файла как fallback.
		return strings.TrimSuffix(filepath.Base(path), ".sock")
	}
	return ""
}

// outboundByPID возвращает карту PID → формализованный список endpoint'ов
// (для интеграции в зависшие воркеры). Тут не нужны топы — просто per-PID.
func outboundByPID() map[int][]string {
	conns := readProcNetTCP()
	if len(conns) == 0 {
		return nil
	}
	locals := localIPs()
	pidByInode := buildInodeToPID(isStuckCandidate)

	res := map[int][]string{}
	for _, c := range conns {
		if c.State != tcpEstablished && c.State != tcpSynSent {
			continue
		}
		if isLoopback(c.RemoteIP) || locals[c.RemoteIP.String()] {
			continue
		}
		pid, ok := pidByInode[c.Inode]
		if !ok {
			continue
		}
		ep := c.RemoteIP.String() + ":" + strconv.Itoa(c.RemotePort)
		if c.State == tcpSynSent {
			ep += " (SYN_SENT)"
		}
		if !contains(res[pid], ep) {
			res[pid] = append(res[pid], ep)
		}
	}
	return res
}

func truncStr(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}
