// Package stack определяет состав веб-стека: Apache (включая MPM),
// nginx, MySQL/MariaDB и версии PHP-FPM.
package stack

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"serverdoc/internal/sys"
)

// Stack — снимок веб-стека сервера.
type Stack struct {
	Apache *Apache      `json:"apache,omitempty"`
	Nginx  *Service     `json:"nginx,omitempty"`
	MySQL  *Service     `json:"mysql,omitempty"`
	PHP    []PHPVersion `json:"php,omitempty"`
}

// Apache — детали Apache. MPM критичен: от него зависит расчёт памяти.
type Apache struct {
	Binary  string `json:"binary"`  // apache2 | httpd
	Version string `json:"version"` // Apache/2.4.x
	MPM     string `json:"mpm"`     // prefork | event | worker
	Running bool   `json:"running"`
}

// Service — обобщённый сервис (nginx, mysql).
type Service struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Running bool   `json:"running"`
}

// PHPVersion — одна установленная версия PHP.
// Если master запущен, ConfigPath указывает на главный php-fpm.conf;
// поля Pools и PoolDir заполняются всегда, когда найден каталог пулов.
type PHPVersion struct {
	Version       string `json:"version"`               // 8.1
	Pools         int    `json:"pools"`                 // число реальных пул-конфигов (без *.default/www/dummy)
	PoolDir       string `json:"pool_dir,omitempty"`    // каталог пулов
	ConfigPath    string `json:"config_path,omitempty"` // главный php-fpm.conf (если найден)
	MasterRunning bool   `json:"master_running"`
	Service       string `json:"service,omitempty"` // ярлык: "alt-php /opt/phpXY" / "system" / "fastpanel /opt/fphp"
}

// Collect собирает полный снимок стека.
func Collect() Stack {
	return Stack{
		Apache: detectApache(),
		Nginx:  detectNginx(),
		MySQL:  detectMySQL(),
		PHP:    detectPHP(),
	}
}

func detectApache() *Apache {
	var bin string
	for _, c := range []string{"apache2", "httpd"} {
		if sys.Have(c) {
			bin = c
			break
		}
	}
	if bin == "" {
		return nil
	}

	a := &Apache{Binary: bin}

	// apache2ctl -V / httpd -V печатает версию и MPM.
	out, _ := sys.Run(5*time.Second, bin+"ctl", "-V")
	if strings.TrimSpace(out) == "" {
		out, _ = sys.Run(5*time.Second, bin, "-V")
	}
	for _, ln := range strings.Split(out, "\n") {
		ln = strings.TrimSpace(ln)
		switch {
		case strings.HasPrefix(ln, "Server version:"):
			a.Version = strings.TrimSpace(strings.TrimPrefix(ln, "Server version:"))
		case strings.HasPrefix(ln, "Server MPM:"):
			a.MPM = strings.ToLower(strings.TrimSpace(strings.TrimPrefix(ln, "Server MPM:")))
		}
	}
	a.Running = procMatch(bin)
	return a
}

func detectNginx() *Service {
	if !sys.Have("nginx") && !procMatch("nginx") {
		return nil
	}
	s := &Service{Name: "nginx", Running: procMatch("nginx")}
	out, _ := sys.Run(5*time.Second, "nginx", "-v") // версия уходит в stderr
	s.Version = extractVersion(out)
	return s
}

func detectMySQL() *Service {
	running := procMatch("mysqld") || procMatch("mariadbd")
	hasBin := sys.Have("mysqld") || sys.Have("mariadbd") || sys.Have("mysql")
	if !running && !hasBin {
		return nil
	}
	s := &Service{Name: "mysql/mariadb", Running: running}
	if sys.Have("mysql") {
		out, _ := sys.Run(5*time.Second, "mysql", "--version")
		s.Version = extractVersion(out)
	}
	return s
}

// detectPHP идёт по двум источникам: живые php-fpm master процессы и
// сканирование известных каталогов пулов. Сначала процессы — они дают
// точную привязку версии к конфигу. Затем директорный скан — чтобы
// учесть случаи "конфиг есть, master не запущен".
//
// Служебные инсталляции PHP игнорируются: /opt/fphp (FastPanel) и
// /usr/local/hestia/php (Hestia) — они не обслуживают клиентские сайты.
func detectPHP() []PHPVersion {
	found := map[string]*PHPVersion{}
	get := func(v, src string) *PHPVersion {
		if found[v] == nil {
			found[v] = &PHPVersion{Version: v, Service: src}
		} else if found[v].Service == "" {
			found[v].Service = src
		}
		return found[v]
	}

	// 1) От процессов: cmdline вида
	//    "php-fpm: master process (/opt/php74/etc/php-fpm.conf)"
	// Версию вытаскиваем из пути конфига; пулы — из соседнего каталога.
	for _, cl := range procCmdlines() {
		m := fpmMasterRe.FindStringSubmatch(cl)
		if m == nil {
			continue
		}
		conf := m[1]
		if shouldIgnorePHPPath(conf) {
			continue
		}
		ver, label := versionFromConfigPath(conf)
		if ver == "" {
			continue
		}
		pv := get(ver, label)
		pv.MasterRunning = true
		pv.ConfigPath = conf
		if pd, n := poolDirAndCount(conf); pd != "" {
			pv.PoolDir = pd
			if n > pv.Pools {
				pv.Pools = n
			}
		}
	}

	// 2) Директорный скан — для версий с выключенным master и для подсчёта пулов.
	for _, dir := range phpPoolDirs() {
		ver, label := versionFromPoolDir(dir)
		if ver == "" {
			continue
		}
		n := countPoolConfs(dir)
		pv := get(ver, label)
		if pv.PoolDir == "" {
			pv.PoolDir = dir
		}
		if n > pv.Pools {
			pv.Pools = n
		}
	}

	out := make([]PHPVersion, 0, len(found))
	for _, v := range found {
		out = append(out, *v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	return out
}

var (
	fpmMasterRe = regexp.MustCompile(`php-fpm:\s*master\s+process\s+\(([^)]+)\)`)

	// Версия из пути:
	//   /etc/php/8.3/fpm/...        → 8.3 (Debian native)
	//   /opt/php83/etc/php-fpm.conf → 8.3 (alt-php ISP/FastPanel)
	//   /etc/opt/remi/php83/...     → 8.3 (RHEL remi)
	verEtcPhpRe = regexp.MustCompile(`/etc/php/(\d+\.\d+)/`)
	verOptPhpRe = regexp.MustCompile(`/(?:opt|etc/opt/remi)/php(\d)(\d+)/`)
)

// shouldIgnorePHPPath — служебные PHP, не обслуживающие клиентские сайты.
func shouldIgnorePHPPath(p string) bool {
	return strings.HasPrefix(p, "/opt/fphp/") ||
		strings.HasPrefix(p, "/usr/local/hestia/php/")
}

// versionFromConfigPath возвращает версию ("8.3") и ярлык источника.
// Для /etc/php/8.3/... ярлык "system", для /opt/phpXY/ — "alt-php /opt/phpXY".
func versionFromConfigPath(p string) (version, label string) {
	if m := verEtcPhpRe.FindStringSubmatch(p); m != nil {
		return m[1], "system"
	}
	if m := verOptPhpRe.FindStringSubmatch(p); m != nil {
		v := m[1] + "." + m[2]
		// Восстановим каталог /opt/phpXY/ для ярлыка.
		if idx := strings.Index(p, "/php"+m[1]+m[2]+"/"); idx >= 0 {
			root := p[:idx+len("/php"+m[1]+m[2])]
			return v, "alt-php " + root
		}
		return v, "alt-php"
	}
	return "", ""
}

// versionFromPoolDir выводит версию из каталога пулов:
//
//	/etc/php/8.3/fpm/pool.d         → 8.3
//	/opt/php83/etc/php-fpm.d/pool.d → 8.3
//	/opt/php83/etc/php-fpm.d        → 8.3
func versionFromPoolDir(dir string) (version, label string) {
	return versionFromConfigPath(dir)
}

// poolDirAndCount берёт путь к php-fpm.conf, ищет рядом каталог
// пулов (php-fpm.d или pool.d) и считает реальные пул-конфиги.
func poolDirAndCount(conf string) (string, int) {
	base := filepath.Dir(conf)
	for _, sub := range []string{"php-fpm.d/pool.d", "php-fpm.d", "pool.d"} {
		d := filepath.Join(base, sub)
		if dirExists(d) {
			return d, countPoolConfs(d)
		}
	}
	return "", 0
}

// phpPoolDirs возвращает все каталоги пулов, которые могут существовать
// на типичных установках (без учёта запущенных мастеров).
func phpPoolDirs() []string {
	var dirs []string

	// Debian-style: /etc/php/<ver>/fpm/pool.d/
	if ents, err := os.ReadDir("/etc/php"); err == nil {
		for _, e := range ents {
			if !e.IsDir() {
				continue
			}
			d := filepath.Join("/etc/php", e.Name(), "fpm", "pool.d")
			if dirExists(d) {
				dirs = append(dirs, d)
			}
		}
	}

	// Alt-php (ISP, FastPanel): /opt/php*/etc/php-fpm.d/ (рекурсивно — структура
	// между мажорами разная: у php83 есть подкаталог pool.d, у php74 плоско).
	if ents, err := os.ReadDir("/opt"); err == nil {
		for _, e := range ents {
			if !e.IsDir() || !strings.HasPrefix(e.Name(), "php") {
				continue
			}
			if shouldIgnorePHPPath("/opt/" + e.Name() + "/") {
				continue
			}
			root := filepath.Join("/opt", e.Name(), "etc", "php-fpm.d")
			if !dirExists(root) {
				continue
			}
			dirs = append(dirs, root)
			// Подкаталоги верхнего уровня — обычно pool.d/site.d/user.d.
			if subs, err := os.ReadDir(root); err == nil {
				for _, s := range subs {
					if s.IsDir() {
						dirs = append(dirs, filepath.Join(root, s.Name()))
					}
				}
			}
		}
	}

	// RHEL remi: /etc/opt/remi/php*/php-fpm.d/
	if ents, err := os.ReadDir("/etc/opt/remi"); err == nil {
		for _, e := range ents {
			if !e.IsDir() || !strings.HasPrefix(e.Name(), "php") {
				continue
			}
			d := filepath.Join("/etc/opt/remi", e.Name(), "php-fpm.d")
			if dirExists(d) {
				dirs = append(dirs, d)
			}
		}
	}

	return dirs
}

// countPoolConfs считает реальные пул-конфиги в каталоге (нерекурсивно),
// исключая образцы и служебные имена.
func countPoolConfs(dir string) int {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	n := 0
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
		n++
	}
	return n
}

// ---------------------------------------------------------------------------
// Хелперы /proc
// ---------------------------------------------------------------------------

var (
	cmdlineOnce  sync.Once
	cmdlineCache []string
)

// procCmdlines читает командные строки всех процессов (кэшируется на запуск).
func procCmdlines() []string {
	cmdlineOnce.Do(func() {
		ents, _ := os.ReadDir("/proc")
		for _, e := range ents {
			if !e.IsDir() {
				continue
			}
			if _, err := strconv.Atoi(e.Name()); err != nil {
				continue
			}
			b, err := os.ReadFile("/proc/" + e.Name() + "/cmdline")
			if err != nil {
				continue
			}
			cmdlineCache = append(cmdlineCache, strings.ReplaceAll(string(b), "\x00", " "))
		}
	})
	return cmdlineCache
}

func procMatch(needle string) bool {
	for _, cl := range procCmdlines() {
		if strings.Contains(cl, needle) {
			return true
		}
	}
	return false
}

var verRe = regexp.MustCompile(`\d+\.\d+\.\d+`)

func extractVersion(s string) string {
	return verRe.FindString(s)
}

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
