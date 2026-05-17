package diag

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"serverdoc/internal/stack"
)

// ApacheState — живое состояние Apache.
type ApacheState struct {
	WorkersAlive       int      `json:"workers_alive"`        // живые worker-процессы
	MaxRequestWorkers  int      `json:"max_request_workers"`  // из конфига MPM
	UtilizationPercent int      `json:"utilization_percent"`  // workers_alive / max * 100
	ErrorLogPath       string   `json:"error_log_path,omitempty"`
	RecentMPMErrors    []string `json:"recent_mpm_errors,omitempty"` // последние MPM-сообщения за 24ч
	NeedsAttention     bool     `json:"needs_attention"`             // >85% утилизация ИЛИ recent MPM errors
}

func analyzeApache(a *stack.Apache) *ApacheState {
	if a == nil || !a.Running {
		return nil
	}

	st := &ApacheState{
		WorkersAlive:      countApacheWorkers(a.Binary),
		MaxRequestWorkers: readApacheMaxWorkers(),
		ErrorLogPath:      findApacheErrorLog(a.Binary),
	}
	if st.MaxRequestWorkers > 0 {
		st.UtilizationPercent = 100 * st.WorkersAlive / st.MaxRequestWorkers
	}
	if st.ErrorLogPath != "" {
		st.RecentMPMErrors = scanApacheErrorLog(st.ErrorLogPath, 24*time.Hour)
	}
	st.NeedsAttention = st.UtilizationPercent >= 85 || len(st.RecentMPMErrors) > 0
	return st
}

// countApacheWorkers — все процессы apache2/httpd минус мастер.
// Мастер — тот, у кого PPID=1. Workers форкаются от него.
func countApacheWorkers(bin string) int {
	pids := pidsByCmdline(bin)
	masters := 0
	for _, pid := range pids {
		if procPPID(pid) == 1 {
			masters++
		}
	}
	if masters == 0 {
		// Если apache запущен из systemd — мастер может иметь PPID systemd, не 1.
		// В таком случае считаем что один из процессов — мастер.
		if len(pids) > 0 {
			return len(pids) - 1
		}
		return 0
	}
	return len(pids) - masters
}

// readApacheMaxWorkers ищет MaxRequestWorkers/MaxClients в конфигах MPM.
// Сканит стандартные пути Debian и RHEL; берёт максимальное значение,
// которое реально применяется (MPM может быть несколько в файлах, но активен
// один — выбираем последнее найденное, для prefork/event/worker отдельно
// не различаем, что нормально для большинства серверов).
func readApacheMaxWorkers() int {
	roots := []string{
		"/etc/apache2", // Debian/Ubuntu
		"/etc/httpd",   // RHEL/CentOS/Alma
	}
	max := 0
	for _, root := range roots {
		_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if !strings.HasSuffix(path, ".conf") {
				return nil
			}
			b, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			for _, m := range apacheMaxRe.FindAllStringSubmatch(string(b), -1) {
				v, _ := strconv.Atoi(m[2])
				if v > max {
					max = v
				}
			}
			return nil
		})
	}
	return max
}

// Учитываем что директива может быть закомментирована — поэтому требуем
// чтобы перед именем не было #. Имя нечувствительно к регистру.
var apacheMaxRe = regexp.MustCompile(`(?im)^\s*(MaxRequestWorkers|MaxClients)\s+(\d+)`)

func findApacheErrorLog(bin string) string {
	candidates := []string{
		"/var/log/apache2/error.log", // Debian
		"/var/log/httpd/error_log",   // RHEL
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

// scanApacheErrorLog читает последние ~256 KB error.log и возвращает строки
// с критичными MPM-сообщениями за последние maxAge.
// AH00484 — event MPM "server reached MaxRequestWorkers".
// AH00161 — prefork MPM "server reached MaxRequestWorkers".
// AH00045 — scoreboard full.
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
		// Сжимаем повторяющиеся строки до уникальных по тексту ошибки.
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

// parseApacheTimestamp — формат "[Sun May 17 12:34:56.123456 2026]".
func parseApacheTimestamp(ln string) time.Time {
	m := apacheTimeRe.FindStringSubmatch(ln)
	if m == nil {
		return time.Time{}
	}
	// Layout для базового формата без микросекунд.
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

// readTail читает последние n байт файла.
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
	offset := int64(0)
	if fi.Size() > n {
		offset = fi.Size() - n
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return nil, err
		}
	}
	buf := bytes.NewBuffer(nil)
	_, err = io.Copy(buf, f)
	return buf.Bytes(), err
}

// pidsByCmdline возвращает PID процессов, у которых cmdline содержит needle.
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

// procPPID читает PPid из /proc/<pid>/status.
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
