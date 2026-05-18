package diag

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// NginxConfig — критичные директивы nginx.
type NginxConfig struct {
	WorkerProcesses     string `json:"worker_processes,omitempty"` // "auto" или число
	WorkerProcessesNum  int    `json:"worker_processes_num,omitempty"`
	WorkerConnections   int    `json:"worker_connections,omitempty"`
	WorkerRlimitNofile  int    `json:"worker_rlimit_nofile,omitempty"`
	ClientMaxBodySize   string `json:"client_max_body_size,omitempty"`
	FastcgiReadTimeout  int    `json:"fastcgi_read_timeout,omitempty"`
	ProxyReadTimeout    int    `json:"proxy_read_timeout,omitempty"`
	KeepaliveTimeout    int    `json:"keepalive_timeout,omitempty"`
	EffectiveCapacity   int    `json:"effective_capacity,omitempty"` // worker_processes × worker_connections
}

// scanNginxConfig читает все *.conf под /etc/nginx и достаёт ключевые директивы.
// Не парсит контекст блока (http{}/server{}/location{}) — берёт последнее
// найденное значение. Для глобальных директив этого достаточно; для
// fastcgi_read_timeout/proxy_read_timeout может быть погрешность если в
// конфиге явно разные значения per-site, но для общей картины — норм.
func scanNginxConfig() NginxConfig {
	var cfg NginxConfig

	roots := []string{"/etc/nginx"}
	for _, root := range roots {
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			// nginx подключает множество файлов через include — берём всё.
			name := filepath.Base(path)
			if !strings.HasSuffix(name, ".conf") && name != "nginx.conf" {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			parseNginxDirectives(string(data), &cfg)
			return nil
		})
	}

	// Эффективная capacity.
	wp := cfg.WorkerProcessesNum
	if wp == 0 && strings.ToLower(cfg.WorkerProcesses) == "auto" {
		// auto = по числу CPU; используем 0 чтобы не врать (значение можно
		// показать как "auto × workers_conn" в отчёте).
	}
	if wp > 0 && cfg.WorkerConnections > 0 {
		cfg.EffectiveCapacity = wp * cfg.WorkerConnections
	}
	return cfg
}

var nginxDirectiveRe = regexp.MustCompile(
	`(?im)^\s*(worker_processes|worker_connections|worker_rlimit_nofile|client_max_body_size|fastcgi_read_timeout|proxy_read_timeout|keepalive_timeout)\s+([^;]+);`)

func parseNginxDirectives(content string, cfg *NginxConfig) {
	for _, m := range nginxDirectiveRe.FindAllStringSubmatch(content, -1) {
		name, val := strings.ToLower(m[1]), strings.TrimSpace(m[2])
		switch name {
		case "worker_processes":
			cfg.WorkerProcesses = val
			if v, err := strconv.Atoi(val); err == nil {
				cfg.WorkerProcessesNum = v
			}
		case "worker_connections":
			cfg.WorkerConnections = atoiOr(val, 0)
		case "worker_rlimit_nofile":
			cfg.WorkerRlimitNofile = atoiOr(val, 0)
		case "client_max_body_size":
			cfg.ClientMaxBodySize = val
		case "fastcgi_read_timeout":
			cfg.FastcgiReadTimeout = parseNginxDurationSec(val)
		case "proxy_read_timeout":
			cfg.ProxyReadTimeout = parseNginxDurationSec(val)
		case "keepalive_timeout":
			// Может быть "65" или "65 60" (timeout header). Берём первое.
			fields := strings.Fields(val)
			if len(fields) > 0 {
				cfg.KeepaliveTimeout = parseNginxDurationSec(fields[0])
			}
		}
	}
}

// parseNginxDurationSec — "60s" / "5m" / "1h" / "60". В секундах.
func parseNginxDurationSec(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
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
