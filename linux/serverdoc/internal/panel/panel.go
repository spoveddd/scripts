// Package panel определяет установленную панель управления и получает
// список сайтов через её CLI (mogwai / mgrctl / v-list-*).
package panel

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"serverdoc/internal/sys"
)

// Kind — тип панели управления.
type Kind string

const (
	ISPmanager Kind = "ISPmanager"
	FastPanel  Kind = "FastPanel"
	Hestia     Kind = "HestiaCP"
	None       Kind = "none"
)

// Нормализованный словарь handlers — общий для всех панелей. Каждое
// значение задаёт механизм исполнения PHP, что определяет модель памяти
// и пулов воркеров (важно для Фазы 3).
const (
	HandlerPHPFPM       = "php_fpm"         // nginx + php-fpm (долгоживущий FPM master)
	HandlerApacheFCGID  = "apache_fcgid"    // Apache + mod_fcgid + php-cgi (форки под Apache)
	HandlerApacheModPHP = "apache_mod_php"  // Apache + mod_php
	HandlerApacheMPMITK = "apache_mpm_itk"  // Apache + mpm-itk
	HandlerCGI          = "cgi"             // generic CGI
	HandlerLSAPI        = "lsapi"           // Apache LSAPI
	HandlerStatic       = "static"          // нет PHP, только статика
	HandlerNodeJS       = "nodejs"          // Node.js (standalone/pm2)
	HandlerSystemd      = "systemd"         // systemd-unit handler (FastPanel)
	HandlerNone         = "none"            // PHP явно отключён
	HandlerUnknown      = "unknown"
)

// Detect определяет панель по характерным каталогам/бинарникам.
func Detect() Kind {
	switch {
	case dirExists("/usr/local/mgr5"):
		return ISPmanager
	case dirExists("/usr/local/fastpanel2") || dirExists("/opt/fastpanel2") || sys.Have("mogwai"):
		return FastPanel
	case dirExists("/usr/local/hestia"):
		return Hestia
	default:
		return None
	}
}

// Site — один сайт. Поля заполняются по мере возможности конкретной панели.
type Site struct {
	Name       string `json:"name"`
	Owner      string `json:"owner,omitempty"`
	Handler    string `json:"handler,omitempty"`     // см. константы Handler*
	PHPVersion string `json:"php_version,omitempty"` // 8.1, 7.4, ...
	DocRoot    string `json:"docroot,omitempty"`
	Enabled    bool   `json:"enabled"`
}

// ListSites возвращает сайты, человекочитаемое предупреждение (если разбор
// был неполным) и ошибку.
func ListSites(k Kind) ([]Site, string, error) {
	switch k {
	case FastPanel:
		return fastpanelSites()
	case ISPmanager:
		return ispSites()
	case Hestia:
		return hestiaSites()
	default:
		return nil, "", nil
	}
}

// ---------------------------------------------------------------------------
// FastPanel
// ---------------------------------------------------------------------------

// fpSite описывает один сайт в выводе `mogwai --json sites list`.
// Структура выверена по реальному выводу: поля верхнего уровня + main_backend.
type fpSite struct {
	Domain  string `json:"domain"`
	Enabled bool   `json:"enabled"`
	Owner   struct {
		Username string `json:"username"`
	} `json:"owner"`
	MainBackend struct {
		Handler        *string `json:"handler"`         // mpm_itk, php_fpm, fcgi, cgi, standalone, pm2, systemd
		HandlerVersion *string `json:"handler_version"` // "83" → 8.3 для PHP; для Node.js — полная "20.15.1"
		Type           string  `json:"type"`            // php, static, nodejs
	} `json:"main_backend"`
}

func fastpanelSites() ([]Site, string, error) {
	// Глобальный флаг --json идёт перед подкомандой.
	out, err := sys.Run(20*time.Second, "mogwai", "--json", "sites", "list")
	if err != nil {
		return nil, "", err
	}
	var arr []fpSite
	if err := json.Unmarshal([]byte(out), &arr); err != nil {
		return nil, "FastPanel: mogwai --json вернул неожиданный формат — " + err.Error(), nil
	}

	sites := make([]Site, 0, len(arr))
	for _, s := range arr {
		if s.Domain == "" {
			continue
		}
		sites = append(sites, Site{
			Name:       s.Domain,
			Owner:      s.Owner.Username,
			Handler:    normalizeFPHandler(deref(s.MainBackend.Handler), s.MainBackend.Type),
			PHPVersion: normalizeFPVersion(deref(s.MainBackend.HandlerVersion), s.MainBackend.Type),
			Enabled:    s.Enabled,
		})
	}
	return sites, "", nil
}

// normalizeFPHandler приводит handler FastPanel к общему словарю.
// type важен: для type=static handler null, для nodejs — standalone/pm2.
func normalizeFPHandler(h, t string) string {
	switch t {
	case "static":
		return HandlerStatic
	case "nodejs":
		return HandlerNodeJS
	}
	switch h {
	case "php_fpm":
		return HandlerPHPFPM
	case "fcgi":
		return HandlerApacheFCGID
	case "mpm_itk":
		return HandlerApacheMPMITK
	case "cgi":
		return HandlerCGI
	case "standalone", "pm2":
		return HandlerNodeJS
	case "systemd":
		return HandlerSystemd
	case "":
		return HandlerStatic
	default:
		return HandlerUnknown
	}
}

// normalizeFPVersion превращает "83" → "8.3". Для двузначных минорников
// (PHP 8.10+) формат сломается — оставляем как есть, об этом узнаем позже.
// Для Node.js (type=nodejs) версия приходит в полном виде "20.15.1" — не трогаем.
func normalizeFPVersion(v, t string) string {
	if v == "" || t != "php" {
		return v
	}
	if len(v) == 2 && !strings.Contains(v, ".") {
		return v[:1] + "." + v[1:]
	}
	return v
}

// ---------------------------------------------------------------------------
// ISPmanager
// ---------------------------------------------------------------------------

// ispJSON — корневая структура mgrctl -o json. Все значения завёрнуты как
// {"$": "value"} (XML-derived формат). Для развёртки используется hop.
type ispJSON struct {
	Doc struct {
		Elem []map[string]json.RawMessage `json:"elem"`
	} `json:"doc"`
}

func ispSites() ([]Site, string, error) {
	bin := "/usr/local/mgr5/sbin/mgrctl"
	if !fileExists(bin) {
		bin = "mgrctl"
	}
	out, err := sys.Run(30*time.Second, bin, "-m", "ispmgr", "-o", "json", "webdomain")
	if err != nil {
		return nil, "", err
	}

	var doc ispJSON
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		return nil, "ISPmanager: mgrctl -o json вернул неожиданный формат — " + err.Error(), nil
	}

	sites := make([]Site, 0, len(doc.Doc.Elem))
	for _, e := range doc.Doc.Elem {
		name := ispField(e, "name")
		if name == "" {
			continue
		}
		mode := ispField(e, "php_mode")
		sites = append(sites, Site{
			Name:       name,
			Owner:      ispField(e, "owner"),
			Handler:    normalizeISPMode(mode),
			PHPVersion: stripISPVersion(ispField(e, "php_version")),
			DocRoot:    ispField(e, "docroot"),
			Enabled:    ispField(e, "active") == "on",
		})
	}
	return sites, "", nil
}

// ispField разворачивает {"$": "value"}. Поле может также быть пустым
// объектом {} (для значений-флагов) — тогда возвращаем "".
func ispField(m map[string]json.RawMessage, key string) string {
	raw, ok := m[key]
	if !ok {
		return ""
	}
	var wrap struct {
		Value string `json:"$"`
	}
	if json.Unmarshal(raw, &wrap) != nil {
		return ""
	}
	return wrap.Value
}

// normalizeISPMode преобразует ISP `php_mode_*` в общий словарь.
// fcgi_apache — это Apache + mod_fcgid + php-cgi, не PHP-FPM (важно для памяти).
func normalizeISPMode(m string) string {
	switch m {
	case "php_mode_fcgi_nginxfpm":
		return HandlerPHPFPM
	case "php_mode_fcgi_apache":
		return HandlerApacheFCGID
	case "php_mode_mod":
		return HandlerApacheModPHP
	case "php_mode_cgi":
		return HandlerCGI
	case "php_mode_lsapi":
		return HandlerLSAPI
	case "php_mode_nophp":
		return HandlerNone
	case "":
		return HandlerUnknown
	default:
		return HandlerUnknown
	}
}

// stripISPVersion отсекает суффикс " (alt)" и патч-часть — у ISP формат
// "7.4.33 (alt)", приводим к общему "X.Y" как у FastPanel/Hestia.
func stripISPVersion(v string) string {
	if i := strings.Index(v, " "); i >= 0 {
		v = v[:i]
	}
	parts := strings.SplitN(v, ".", 3)
	if len(parts) >= 2 {
		return parts[0] + "." + parts[1]
	}
	return v
}

// ---------------------------------------------------------------------------
// HestiaCP
// ---------------------------------------------------------------------------

// hestiaUser — поля из v-list-users json которые нам нужны.
type hestiaUser struct {
	WebDomains string `json:"WEB_DOMAINS"` // "14" или "unlimited"
	Suspended  string `json:"SUSPENDED"`   // "yes" / "no"
}

// hestiaDomain — поля из v-list-web-domains <user> json.
// BACKEND — это ИМЯ шаблона (default, PHP-8_3, no-php, socket, ...),
// а не версия PHP. Версию ищем по карте из /etc/php/*/fpm/pool.d/.
type hestiaDomain struct {
	IP           string `json:"IP"`
	DocumentRoot string `json:"DOCUMENT_ROOT"`
	Backend      string `json:"BACKEND"`
	Suspended    string `json:"SUSPENDED"`
}

func hestiaSites() ([]Site, string, error) {
	binDir := "/usr/local/hestia/bin/"

	usersOut, err := sys.Run(15*time.Second, binDir+"v-list-users", "json")
	if err != nil {
		return nil, "", err
	}
	var users map[string]hestiaUser
	if err := json.Unmarshal([]byte(usersOut), &users); err != nil {
		return nil, "Hestia: v-list-users json вернул неожиданный формат — " + err.Error(), nil
	}

	domainVer := scanHestiaPHPVersions()

	var sites []Site
	for name, u := range users {
		if u.WebDomains == "0" {
			continue
		}
		domOut, err := sys.Run(15*time.Second, binDir+"v-list-web-domains", name, "json")
		if err != nil {
			continue
		}
		var doms map[string]hestiaDomain
		if json.Unmarshal([]byte(domOut), &doms) != nil {
			continue
		}
		for domain, d := range doms {
			handler, version := hestiaBackendToHandler(d.Backend, domain, domainVer)
			sites = append(sites, Site{
				Name:       domain,
				Owner:      name,
				Handler:    handler,
				PHPVersion: version,
				DocRoot:    d.DocumentRoot,
				Enabled:    d.Suspended != "yes",
			})
		}
	}
	return sites, "", nil
}

// hestiaBackendToHandler решает, какой PHP-механизм и какая версия у домена.
// Источники по убыванию надёжности:
//  1. Карта domainVer из реальных pool-файлов /etc/php/<X.Y>/fpm/pool.d/<domain>.conf.
//  2. Имя шаблона PHP-X_Y.
//  3. no-php → none/static.
func hestiaBackendToHandler(backend, domain string, domainVer map[string]string) (handler, version string) {
	if backend == "no-php" {
		return HandlerNone, ""
	}
	if v, ok := domainVer[domain]; ok {
		return HandlerPHPFPM, v
	}
	if m := hestiaTemplateVerRe.FindStringSubmatch(backend); m != nil {
		return HandlerPHPFPM, m[1] + "." + m[2]
	}
	// Шаблон есть, но pool под домен не найден — скорее всего PHP-FPM, но версия неизвестна.
	return HandlerPHPFPM, ""
}

var hestiaTemplateVerRe = regexp.MustCompile(`^PHP-(\d+)_(\d+)$`)

// scanHestiaPHPVersions строит карту domain→version по реальным pool-файлам.
// Имя файла = <domain>.conf, каталог = /etc/php/<X.Y>/fpm/pool.d/.
// Фильтрует служебные dummy.conf и www.conf.
func scanHestiaPHPVersions() map[string]string {
	res := map[string]string{}
	entries, err := os.ReadDir("/etc/php")
	if err != nil {
		return res
	}
	for _, ent := range entries {
		if !ent.IsDir() {
			continue
		}
		ver := ent.Name() // "8.3", "7.4", ...
		if !phpVerDirRe.MatchString(ver) {
			continue
		}
		poolDir := filepath.Join("/etc/php", ver, "fpm", "pool.d")
		pools, err := os.ReadDir(poolDir)
		if err != nil {
			continue
		}
		for _, p := range pools {
			name := p.Name()
			if !strings.HasSuffix(name, ".conf") {
				continue
			}
			if name == "www.conf" || name == "dummy.conf" {
				continue
			}
			domain := strings.TrimSuffix(name, ".conf")
			res[domain] = ver
		}
	}
	return res
}

var phpVerDirRe = regexp.MustCompile(`^\d+\.\d+$`)

// ---------------------------------------------------------------------------
// Хелперы
// ---------------------------------------------------------------------------

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
