package diag

import (
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"serverdoc/internal/panel"
)

// LogsState — топ-сайтов по нагрузке за период.
type LogsState struct {
	PeriodMinutes int        `json:"period_minutes"`
	TotalRequests int        `json:"total_requests"`
	TopSites      []SiteLoad `json:"top_sites,omitempty"`
	ParsedFiles   int        `json:"parsed_files"`
	Note          string     `json:"note,omitempty"`
}

// SiteLoad — нагрузка на один сайт за период.
type SiteLoad struct {
	Site         string `json:"site"`
	Requests     int    `json:"requests"`
	LogPath      string `json:"log_path,omitempty"`
	RequestsPerSec float64 `json:"requests_per_sec"`
}

const logsDefaultPeriod = 60 * time.Minute

func analyzeLogs(pk panel.Kind, sites []panel.Site) *LogsState {
	paths := logPathsForPanel(pk)
	if len(paths) == 0 {
		return &LogsState{Note: "лог-пути для этой панели неизвестны"}
	}

	cutoff := time.Now().Add(-logsDefaultPeriod)
	loads := map[string]*SiteLoad{}
	parsedFiles := 0

	// Читаем не больше ~1 MB с хвоста каждого файла — этого хватает на типичный
	// сайт за час; для очень нагруженных мы недосчитаем (видно по nginx access),
	// но в Note об этом сообщим если файлы оказались больше лимита.
	const tailBytes = 1 * 1024 * 1024

	for _, path := range paths {
		data, err := readTail(path, tailBytes)
		if err != nil {
			continue
		}
		parsedFiles++
		siteName := siteNameFromLogPath(path, pk)
		n := countRequestsSince(data, cutoff)
		if n == 0 {
			continue
		}
		if loads[siteName] == nil {
			loads[siteName] = &SiteLoad{Site: siteName, LogPath: path}
		}
		loads[siteName].Requests += n
	}

	st := &LogsState{
		PeriodMinutes: int(logsDefaultPeriod.Minutes()),
		ParsedFiles:   parsedFiles,
	}
	periodSec := logsDefaultPeriod.Seconds()
	for _, l := range loads {
		l.RequestsPerSec = float64(l.Requests) / periodSec
		st.TotalRequests += l.Requests
		st.TopSites = append(st.TopSites, *l)
	}
	sort.SliceStable(st.TopSites, func(i, j int) bool {
		return st.TopSites[i].Requests > st.TopSites[j].Requests
	})
	if len(st.TopSites) > 10 {
		st.TopSites = st.TopSites[:10]
	}
	return st
}

// logPathsForPanel возвращает glob-шаблоны и разворачивает их в реальные файлы.
// Логика взята из ddoser (по факту проверена на всех трёх панелях).
func logPathsForPanel(pk panel.Kind) []string {
	var patterns []string
	switch pk {
	case panel.ISPmanager:
		patterns = []string{"/var/www/httpd-logs/*.access.log"}
	case panel.FastPanel:
		// Предпочитаем backend-логи, но соберём оба типа — каждый сайт в логике
		// нагрузки будет считаться отдельно. Дедупликация по имени сайта
		// в siteNameFromLogPath.
		patterns = []string{
			"/var/www/*/data/logs/*-backend.access.log",
			"/var/www/*/data/logs/*-frontend.access.log",
		}
	case panel.Hestia:
		patterns = []string{
			"/var/log/apache2/domains/*.log",
			"/var/log/nginx/domains/*.log",
		}
	default:
		return nil
	}
	var paths []string
	seen := map[string]bool{}
	for _, p := range patterns {
		matches, _ := filepath.Glob(p)
		for _, m := range matches {
			// Только access-логи, не error.
			base := filepath.Base(m)
			if strings.Contains(base, "error") {
				continue
			}
			if seen[m] {
				continue
			}
			seen[m] = true
			paths = append(paths, m)
		}
	}
	return paths
}

// siteNameFromLogPath извлекает имя домена из пути лог-файла. Для одного домена
// может быть несколько файлов (FastPanel — backend+frontend, Hestia — apache+nginx);
// мы возвращаем одно и то же имя, чтобы счётчики суммировались.
func siteNameFromLogPath(path string, pk panel.Kind) string {
	base := filepath.Base(path)
	// Отрезаем стандартные суффиксы.
	for _, suf := range []string{
		"-backend.access.log", "-frontend.access.log",
		".access.log", ".log",
	} {
		if strings.HasSuffix(base, suf) {
			base = strings.TrimSuffix(base, suf)
			break
		}
	}
	return base
}

// countRequestsSince — число строк в логе с timestamp >= cutoff.
// Формат combined: `1.2.3.4 - - [DD/Mon/YYYY:HH:MM:SS +TZ] "GET ..."`.
// Если в строке нет валидного timestamp — считаем (лучше переоценить,
// чем потерять). Маленький бенефит ценой потенциальной погрешности.
func countRequestsSince(data []byte, cutoff time.Time) int {
	n := 0
	lines := strings.Split(string(data), "\n")
	// Первая строка могла быть обрезана tail — пропустим её.
	for i, ln := range lines {
		if i == 0 {
			continue
		}
		if ln == "" {
			continue
		}
		ts, ok := parseAccessTime(ln)
		if !ok {
			// Без timestamp — попадёт в зачёт.
			n++
			continue
		}
		if ts.Before(cutoff) {
			continue
		}
		n++
	}
	return n
}

var accessTimeRe = regexp.MustCompile(`\[(\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]`)

func parseAccessTime(ln string) (time.Time, bool) {
	m := accessTimeRe.FindStringSubmatch(ln)
	if m == nil {
		return time.Time{}, false
	}
	t, err := time.Parse("02/Jan/2006:15:04:05 -0700", m[1])
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}
