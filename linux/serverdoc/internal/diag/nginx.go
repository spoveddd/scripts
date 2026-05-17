package diag

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

// ServiceLogState — общая структура для error-логов бэкенд-сервисов
// (nginx, mysql и т.п.). Категории отсортированы по убыванию count.
type ServiceLogState struct {
	LogPath       string        `json:"log_path,omitempty"`
	PeriodHours   int           `json:"period_hours"`
	TotalMatched  int           `json:"total_matched"`
	Categories    []LogCategory `json:"categories,omitempty"`
	Note          string        `json:"note,omitempty"` // если лог недоступен
}

// LogCategory — одна категория сгруппированных сообщений.
type LogCategory struct {
	Code        string   `json:"code"`
	Severity    string   `json:"severity"` // "crit"/"warn"/"info"
	Description string   `json:"description"`
	Count       int      `json:"count"`
	Examples    []string `json:"examples,omitempty"`
}

func analyzeNginxLog() *ServiceLogState {
	candidates := []string{
		"/var/log/nginx/error.log",
		"/var/log/nginx/error_log",
	}
	var path string
	for _, p := range candidates {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			path = p
			break
		}
	}
	if path == "" {
		return &ServiceLogState{Note: "nginx error.log не найден"}
	}
	return scanServiceLog(path, 24*time.Hour, nginxPatterns, parseNginxTimestamp)
}

// nginxPatterns — категории сообщений nginx, упорядочены от наиболее
// критичных к менее. Первое совпадение определяет категорию.
var nginxPatterns = []logPattern{
	{
		code: "nginx_worker_connections_full", severity: "crit",
		description: "Воркеры nginx упёрлись в worker_connections — новые соединения отклоняются",
		re:          regexp.MustCompile(`worker_connections are not enough|worker_connections .* exceeded`),
	},
	{
		code: "nginx_too_many_open_files", severity: "crit",
		description: "Too many open files — упор в ulimit nofile или worker_rlimit_nofile",
		re:          regexp.MustCompile(`Too many open files|EMFILE`),
	},
	{
		code: "nginx_no_live_upstreams", severity: "crit",
		description: "Все upstream-сервера недоступны (PHP-FPM/Apache не отвечает)",
		re:          regexp.MustCompile(`no live upstreams`),
	},
	{
		code: "nginx_upstream_refused", severity: "crit",
		description: "Connection refused от upstream — бэкенд не слушает (PHP-FPM/Apache down)",
		re:          regexp.MustCompile(`connect\(\) failed.*Connection refused|connect\(\) to .* failed.*111`),
	},
	{
		code: "nginx_upstream_timeout", severity: "warn",
		description: "upstream timed out — PHP-FPM/Apache не успевает ответить",
		re:          regexp.MustCompile(`upstream timed out|upstream prematurely closed`),
	},
	{
		code: "nginx_open_sockets_limit", severity: "warn",
		description: "open sockets exceeded — лимит ядра на сокеты",
		re:          regexp.MustCompile(`open sockets exceeded`),
	},
	{
		code: "nginx_client_body_large", severity: "info",
		description: "client intended to send too large body — упирается в client_max_body_size",
		re:          regexp.MustCompile(`client intended to send too large body`),
	},
	{
		code: "nginx_ssl_handshake", severity: "info",
		description: "Проблемы SSL-handshake",
		re:          regexp.MustCompile(`SSL_do_handshake\(\) failed`),
	},
}

// nginxTimeRe — формат "2026/05/17 12:34:56".
var nginxTimeRe = regexp.MustCompile(`^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})`)

func parseNginxTimestamp(ln string) time.Time {
	m := nginxTimeRe.FindStringSubmatch(ln)
	if m == nil {
		return time.Time{}
	}
	t, err := time.ParseInLocation("2006/01/02 15:04:05", m[1], time.Local)
	if err != nil {
		return time.Time{}
	}
	return t
}

// ---------------------------------------------------------------------------
// Общий хелпер для сканирования error-лога: tail → фильтр по времени →
// группировка по паттернам.
// ---------------------------------------------------------------------------

type logPattern struct {
	code        string
	severity    string
	description string
	re          *regexp.Regexp
}

func scanServiceLog(
	path string,
	maxAge time.Duration,
	patterns []logPattern,
	tsParser func(string) time.Time,
) *ServiceLogState {
	const tailBytes = 512 * 1024
	data, err := readTail(path, tailBytes)
	if err != nil {
		return &ServiceLogState{Note: "не удалось прочитать " + path + ": " + err.Error()}
	}

	st := &ServiceLogState{
		LogPath:     path,
		PeriodHours: int(maxAge.Hours()),
	}
	cutoff := time.Now().Add(-maxAge)
	cats := map[string]*LogCategory{}

	for _, ln := range strings.Split(string(data), "\n") {
		if ln == "" {
			continue
		}
		if tsParser != nil {
			if ts := tsParser(ln); !ts.IsZero() && ts.Before(cutoff) {
				continue
			}
		}
		for _, pat := range patterns {
			if !pat.re.MatchString(ln) {
				continue
			}
			c, ok := cats[pat.code]
			if !ok {
				c = &LogCategory{
					Code:        pat.code,
					Severity:    pat.severity,
					Description: pat.description,
				}
				cats[pat.code] = c
			}
			c.Count++
			st.TotalMatched++
			if len(c.Examples) < 2 {
				// Сокращаем длинные строки.
				ex := strings.TrimSpace(ln)
				if len(ex) > 180 {
					ex = ex[:177] + "..."
				}
				c.Examples = append(c.Examples, ex)
			}
			break
		}
	}

	for _, c := range cats {
		st.Categories = append(st.Categories, *c)
	}
	sort.SliceStable(st.Categories, func(i, j int) bool {
		// Сначала по severity (crit > warn > info), потом по count.
		sevRank := func(s string) int {
			switch s {
			case "crit":
				return 0
			case "warn":
				return 1
			}
			return 2
		}
		if a, b := sevRank(st.Categories[i].Severity), sevRank(st.Categories[j].Severity); a != b {
			return a < b
		}
		return st.Categories[i].Count > st.Categories[j].Count
	})
	return st
}
