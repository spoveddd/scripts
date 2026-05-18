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
// realPools — карта version → set реальных pool names (фильтр служебных).
// siteNames — множество доменов с панели для дополнительной проверки pool.
func analyzeStuck(realPools map[string]map[string]bool, siteNames map[string]bool) *StuckWorkersState {
	st := &StuckWorkersState{Samples: stuckSamples, SampleSpanMs: stuckIntervalMs * (stuckSamples - 1)}
	snapshots := make([]map[int]procSnap, 0, stuckSamples)

	for i := 0; i < stuckSamples; i++ {
		snapshots = append(snapshots, takeProcSnapshot())
		if i < stuckSamples-1 {
			time.Sleep(time.Duration(stuckIntervalMs) * time.Millisecond)
		}
	}

	// Кандидаты: есть во всех 3 снэпшотах, state не менялся, CPU не вырос.
	// Для S-state дополнительно требуется наличие активного клиентского
	// соединения — иначе worker просто idle и ждёт нового запроса от epoll,
	// что нормально и не является зависанием.
	type cand struct {
		pid        int
		first      procSnap
		last       procSnap
		cpuTickInc int
	}
	var candidates []cand

	// Карта master PID → версия PHP. Нужна чтобы привязать worker'а к
	// конкретной версии и проверить что его pool реально обслуживает сайты.
	fpmMasters, _ := scanFPMProcesses()

	// Активные TCP соединения worker'ов: socket inode → есть ESTABLISHED.
	activeTCP := buildActiveTCPInodes()
	// Все ESTABLISHED endpoints по inode (включая loopback) для показа "ждёт ответа".
	allEndpoints := buildEndpointsByInode()
	// Активные unix-сокеты: socket inode → path сокета.
	unixByInode := readProcNetUnix()

	for pid, sFirst := range snapshots[0] {
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
		if sFirst.State == "R" {
			continue
		}
		cpuInc := sLast.CPUTicks - sFirst.CPUTicks
		if cpuInc > 0 {
			continue
		}
		// D-state: всегда подозрительно (uninterruptible I/O в ядре).
		// S-state: только если воркер реально обслуживает запрос
		// (есть активный сокет к клиенту или к upstream).
		if sFirst.State != "D" && !hasActiveConnection(pid, activeTCP, unixByInode) {
			continue
		}
		// Фильтр: php-fpm worker из служебного пула.
		// 1) Pool не входит в parseFPMPools этой версии (www.conf-эквивалент).
		// 2) Pool совпадает с известным системным именем (www-data, www, apps,
		//    apache) И не совпадает ни с одним именем сайта с панели.
		if m := fpmPoolCmdRe.FindStringSubmatch(sFirst.Cmdline); m != nil {
			pool := m[1]
			ver := fpmMasters[procPPID(pid)]
			if !isRealPool(realPools, ver, pool) {
				continue
			}
			if isSystemPoolName(pool) && !siteNames[pool] {
				continue
			}
		}
		candidates = append(candidates, cand{pid: pid, first: sFirst, last: sLast, cpuTickInc: cpuInc})
	}

	// unixByInode уже построен выше; используем для маппинга PHP-FPM сокет → сайт.

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

		// Все активные TCP-эндпоинты (включая loopback к MySQL/Redis и т.п.) —
		// это то, ОТ ЧЕГО воркер сейчас ждёт ответа.
		w.Outbound = endpointsForPID(ca.pid, allEndpoints)
		// Если PHP-FPM worker и pool name всё ещё не совпадает с сайтом —
		// пометим его явно "пул=X" чтобы инженер понял что pool это служебное имя.
		if w.Site == "" && w.Pool != "" {
			w.Site = "(пул " + w.Pool + ")"
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
// Проверяем по basename исполняемого файла (первое слово cmdline), а не
// подстрокой — иначе "ihttpd" (от ISPmanager) ловится как "httpd".
var fpmWorkerStuckRe = regexp.MustCompile(`php-fpm:\s*pool\s+`)

func isStuckCandidate(cmdline string) bool {
	if strings.Contains(cmdline, "php-fpm: master") {
		return false
	}
	if fpmWorkerStuckRe.MatchString(cmdline) {
		return true
	}
	// Берём первое слово cmdline — это путь к бинарю.
	fields := strings.Fields(cmdline)
	if len(fields) == 0 {
		return false
	}
	bin := fields[0]
	// Отрезаем путь, оставляем basename.
	if idx := strings.LastIndex(bin, "/"); idx >= 0 {
		bin = bin[idx+1:]
	}
	switch bin {
	case "apache2", "httpd", "php-cgi":
		return true
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

// buildEndpointsByInode возвращает карту socket inode → описание remote endpoint
// для ESTABLISHED/SYN_SENT соединений. Включает loopback (это важно — MySQL/
// Redis обычно слушают 127.0.0.1, и если PHP завис на ответе от БД, нам надо
// это увидеть). Известные порты подписываются (3306=MySQL и т.д.).
func buildEndpointsByInode() map[uint64]string {
	res := map[uint64]string{}
	for _, c := range readProcNetTCP() {
		if c.State != tcpEstablished && c.State != tcpSynSent {
			continue
		}
		label := wellKnownPortLabel(c.RemotePort)
		ep := c.RemoteIP.String() + ":" + strconv.Itoa(c.RemotePort)
		if label != "" {
			ep += " " + label
		}
		if c.State == tcpSynSent {
			ep += " [SYN_SENT]"
		}
		res[c.Inode] = ep
	}
	return res
}

// endpointsForPID возвращает remote endpoints всех ESTABLISHED/SYN_SENT
// сокетов открытых процессом. Дедуплицируется по endpoint-строке.
func endpointsForPID(pid int, endpoints map[uint64]string) []string {
	seen := map[string]bool{}
	var out []string
	for _, inode := range pidSocketInodes(pid) {
		if ep, ok := endpoints[inode]; ok && !seen[ep] {
			seen[ep] = true
			out = append(out, ep)
		}
	}
	return out
}

// wellKnownPortLabel — лейбл для распространённых хостинговых backend-портов.
func wellKnownPortLabel(port int) string {
	switch port {
	case 3306:
		return "(MySQL)"
	case 5432:
		return "(PostgreSQL)"
	case 6379:
		return "(Redis)"
	case 11211:
		return "(memcached)"
	case 9000:
		return "(PHP-FPM TCP)"
	case 25, 465, 587:
		return "(SMTP)"
	case 110, 995:
		return "(POP3)"
	case 143, 993:
		return "(IMAP)"
	case 80:
		return "(HTTP)"
	case 443:
		return "(HTTPS)"
	}
	return ""
}

// isSystemPoolName — имена пулов php-fpm которые обычно служебные.
// На ISP это пул панели (www-data), на Debian/Ubuntu — дефолтный (www).
func isSystemPoolName(pool string) bool {
	switch pool {
	case "www", "www-data", "apache", "apps", "default":
		return true
	}
	return false
}

// isRealPool проверяет что worker'ский pool name относится к реальному сайту,
// а не к служебному пулу (типа www.conf у Debian-PHP который мы исключаем
// из реальных пулов).
func isRealPool(realPools map[string]map[string]bool, version, pool string) bool {
	if realPools == nil {
		return true // без контекста — не фильтруем
	}
	set, ok := realPools[version]
	if !ok {
		return true
	}
	return set[pool]
}

// buildActiveTCPInodes возвращает множество socket-inode где есть ESTABLISHED
// соединение. SYN_SENT тоже включаем — это "висит на коннекте к upstream/api".
// LISTEN и TIME_WAIT/CLOSE_WAIT исключаем — это не активная нагрузка.
func buildActiveTCPInodes() map[uint64]bool {
	res := map[uint64]bool{}
	for _, c := range readProcNetTCP() {
		if c.State != tcpEstablished && c.State != tcpSynSent {
			continue
		}
		res[c.Inode] = true
	}
	return res
}

// hasActiveConnection — есть ли у процесса активное клиентское/upstream соединение.
// Учитывает TCP ESTABLISHED/SYN_SENT и unix-сокеты к php-fpm.
// Loopback TCP игнорируем кроме php-fpm (apache→fpm идёт через 127.0.0.1).
func hasActiveConnection(pid int, activeTCP map[uint64]bool, unixByInode map[uint64]string) bool {
	for _, inode := range pidSocketInodes(pid) {
		if activeTCP[inode] {
			return true
		}
		// Unix-сокет к php-fpm.
		if path, ok := unixByInode[inode]; ok {
			if strings.Contains(path, "fpm") || strings.Contains(path, "php") {
				return true
			}
		}
	}
	return false
}

func truncStr(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}
