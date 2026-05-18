// Package collect — режим сбора диагностической информации для разработчика.
// Создаёт единый Markdown-файл с raw-выводами команд, конфигами и хвостами
// логов. Используется в beta-фазе: пользователь присылает .md, мы по нему
// улучшаем парсеры и corner cases.
package collect

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Dump собирает Markdown-отчёт с диагностическими данными.
// Возвращает путь к созданному файлу.
func Dump(reportJSON []byte) (string, error) {
	ts := time.Now().Format("20060102-150405")
	path := filepath.Join(os.TempDir(), fmt.Sprintf("serverdoc-dump-%s.md", ts))

	f, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	w := &mdWriter{w: f}

	// Title block
	hostname, _ := os.Hostname()
	fmt.Fprintf(f, "# serverdoc dump — `%s`\n\n", hostname)
	fmt.Fprintf(f, "- generated: `%s`\n", time.Now().Format(time.RFC3339))
	fmt.Fprintf(f, "- file: `%s`\n\n", path)

	// 1) Собственный JSON отчёт.
	w.block("report.json", "json", string(reportJSON))

	// 2) Raw outputs CLI панелей.
	w.heading("Panel CLI outputs")
	for _, src := range panelOutputs() {
		w.block("panel/"+src.name, "", src.content)
	}

	// 3) Effective stack configs.
	w.heading("Stack configs")
	for _, src := range stackOutputs() {
		lang := langByExt(src.name)
		w.block("stack/"+src.name, lang, src.content)
	}

	// 4) Log tails.
	w.heading("Log tails (~256 KB)")
	for _, src := range logTails() {
		w.block("logs/"+src.name, "log", src.content)
	}

	// 5) /proc snapshots.
	w.heading("/proc snapshots")
	for _, src := range procSnapshots() {
		w.block("proc/"+src.name, "", src.content)
	}

	// 6) Системные команды.
	w.heading("System commands")
	for _, src := range systemOutputs() {
		w.block("system/"+src.name, "", src.content)
	}

	// 7) Docker.
	docker := dockerOutputs()
	if len(docker) > 0 {
		w.heading("Docker")
		for _, src := range docker {
			w.block("docker/"+src.name, "", src.content)
		}
	}

	return path, nil
}

// mdWriter — поток записи Markdown.
type mdWriter struct {
	w io.Writer
}

func (w *mdWriter) heading(title string) {
	fmt.Fprintf(w.w, "\n## %s\n\n", title)
}

// block выводит секцию с заголовком h3 и code-fenced содержимым.
// Если в content встречается тройной бэктик — fence удлиняется до 4-х.
func (w *mdWriter) block(name, lang, content string) {
	fmt.Fprintf(w.w, "\n### `%s`\n\n", name)
	content = strings.TrimRight(content, "\n")
	if content == "" {
		fmt.Fprintln(w.w, "_(пусто)_")
		return
	}
	fence := "```"
	if strings.Contains(content, "```") {
		fence = "````"
	}
	if lang != "" {
		fmt.Fprintf(w.w, "%s%s\n", fence, lang)
	} else {
		fmt.Fprintf(w.w, "%s\n", fence)
	}
	fmt.Fprintln(w.w, content)
	fmt.Fprintf(w.w, "%s\n", fence)
}

func langByExt(name string) string {
	switch {
	case strings.HasSuffix(name, ".json"):
		return "json"
	case strings.HasSuffix(name, ".conf"):
		return "ini"
	case strings.HasSuffix(name, ".tpl"):
		return "ini"
	case strings.HasSuffix(name, ".log"):
		return "log"
	}
	return ""
}

type entry struct {
	name    string
	content string
}

func runCmd(name string, args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err != nil && len(out) == 0 {
		return "error: " + err.Error()
	}
	return string(out)
}

func panelOutputs() []entry {
	var out []entry
	if fileExists("/usr/local/mgr5/sbin/mgrctl") {
		out = append(out, entry{"ispmgr_webdomain_text.txt",
			runCmd("/usr/local/mgr5/sbin/mgrctl", "-m", "ispmgr", "webdomain")})
		out = append(out, entry{"ispmgr_webdomain_json.txt",
			runCmd("/usr/local/mgr5/sbin/mgrctl", "-m", "ispmgr", "-o", "json", "webdomain")})
	}
	if which("mogwai") {
		out = append(out, entry{"mogwai_sites_list.txt",
			runCmd("mogwai", "sites", "list")})
		out = append(out, entry{"mogwai_sites_list_json.txt",
			runCmd("mogwai", "--json", "sites", "list")})
	}
	if fileExists("/usr/local/hestia/bin/v-list-users") {
		out = append(out, entry{"hestia_users.json",
			runCmd("/usr/local/hestia/bin/v-list-users", "json")})
		out = append(out, entry{"hestia_sys_php.json",
			runCmd("/usr/local/hestia/bin/v-list-sys-php", "json")})
		out = append(out, entry{"hestia_templates_backend.json",
			runCmd("/usr/local/hestia/bin/v-list-web-templates-backend", "json")})
	}
	return out
}

func stackOutputs() []entry {
	var out []entry
	for _, bin := range []string{"apache2ctl", "httpd"} {
		if which(bin) {
			out = append(out, entry{"apache_V.txt", runCmd(bin, "-V")})
			out = append(out, entry{"apache_M.txt", runCmd(bin, "-M")})
			break
		}
	}
	if which("nginx") {
		out = append(out, entry{"nginx_T.txt", runCmd("nginx", "-T")})
	}
	if which("mysql") {
		out = append(out, entry{"mysql_variables.txt",
			runCmd("mysql", "-BN", "-e", "SHOW GLOBAL VARIABLES")})
		out = append(out, entry{"mysql_status.txt",
			runCmd("mysql", "-BN", "-e", "SHOW GLOBAL STATUS")})
		out = append(out, entry{"mysql_processlist.txt",
			runCmd("mysql", "-BN", "-e", "SHOW FULL PROCESSLIST")})
	}
	for _, base := range []string{"/etc/php", "/opt"} {
		out = append(out, walkConfigs(base, "pool.d")...)
	}
	for _, root := range []string{"/etc/apache2", "/etc/httpd"} {
		if dirExists(root) {
			out = append(out, walkConfigs(root, "")...)
		}
	}
	return out
}

func walkConfigs(root, mustContainSubdir string) []entry {
	var out []entry
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(path, ".conf") && !strings.HasSuffix(path, ".tpl") {
			return nil
		}
		if mustContainSubdir != "" && !strings.Contains(path, "/"+mustContainSubdir+"/") &&
			!strings.HasSuffix(filepath.Dir(path), "/"+mustContainSubdir) {
			return nil
		}
		if info.Size() > 512*1024 {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		out = append(out, entry{strings.TrimPrefix(path, "/"), string(b)})
		return nil
	})
	return out
}

func logTails() []entry {
	var out []entry
	candidates := []string{
		"/var/log/messages",
		"/var/log/syslog",
		"/var/log/kern.log",
		"/var/log/apache2/error.log",
		"/var/log/httpd/error_log",
		"/var/log/nginx/error.log",
		"/var/log/mysql/error.log",
		"/var/log/mariadb/mariadb.log",
		"/var/log/mysqld.log",
	}
	for _, p := range candidates {
		if !fileExists(p) {
			continue
		}
		out = append(out, entry{filepath.Base(p), readTail(p, 256*1024)})
	}
	return out
}

func procSnapshots() []entry {
	files := []string{
		"/proc/meminfo", "/proc/cpuinfo", "/proc/loadavg",
		"/proc/vmstat", "/proc/diskstats", "/proc/version",
		"/proc/net/tcp", "/proc/net/tcp6", "/proc/net/unix",
	}
	var out []entry
	for _, f := range files {
		if b, err := os.ReadFile(f); err == nil {
			out = append(out, entry{strings.TrimPrefix(f, "/proc/"), string(b)})
		}
	}
	return out
}

func systemOutputs() []entry {
	out := []entry{
		{"ps_auxf.txt", runCmd("ps", "auxf")},
		{"free_m.txt", runCmd("free", "-m")},
		{"df_h.txt", runCmd("df", "-h")},
		{"df_i.txt", runCmd("df", "-i")},
		{"systemctl_failed.txt", runCmd("systemctl", "list-units", "--failed", "--no-legend")},
		{"systemctl_running.txt", runCmd("systemctl", "list-units", "--type=service", "--state=running", "--no-legend")},
		{"uptime.txt", runCmd("uptime")},
		{"uname_a.txt", runCmd("uname", "-a")},
		{"ip_a.txt", runCmd("ip", "-o", "addr")},
		{"ss_tan.txt", runCmd("ss", "-tan")},
	}
	if which("dmesg") {
		out = append(out, entry{"dmesg_tail.txt", runCmd("dmesg", "-T")})
	}
	return out
}

func dockerOutputs() []entry {
	if !fileExists("/var/run/docker.sock") && !fileExists("/run/docker.sock") {
		return nil
	}
	if !which("docker") {
		return nil
	}
	return []entry{
		{"docker_info.txt", runCmd("docker", "info")},
		{"docker_ps.txt", runCmd("docker", "ps", "-a")},
		{"docker_stats.txt", runCmd("docker", "stats", "--no-stream")},
	}
}

// ---------------------------------------------------------------------------

func readTail(path string, n int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return ""
	}
	if fi.Size() > n {
		if _, err := f.Seek(fi.Size()-n, io.SeekStart); err != nil {
			return ""
		}
	}
	b, _ := io.ReadAll(f)
	return string(b)
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func which(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
