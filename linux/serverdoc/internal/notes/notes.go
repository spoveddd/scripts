// Package notes — фактологические наблюдения по снапшоту состояния.
// Не даёт советов — только корреляции, которые инженер интерпретирует сам.
// База для будущих рекомендаций (Фаза 4).
package notes

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"serverdoc/internal/diag"
	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

// Severity — уровень замечания. crit — сайты сломаны или сервер на грани.
type Severity string

const (
	SevCrit Severity = "crit"
	SevWarn Severity = "warn"
	SevInfo Severity = "info"
)

// Note — одно наблюдение + рекомендуемое действие.
type Note struct {
	Severity Severity `json:"severity"`
	Code     string   `json:"code"`             // машинный ID
	Text     string   `json:"text"`             // что увидели
	Action   []string `json:"action,omitempty"` // что сделать (multiline)
}

// Collect строит список замечаний по снапшоту.
func Collect(s sys.Info, sites []panel.Site, st stack.Stack, d diag.Report) []Note {
	var out []Note

	out = append(out, phpFPMNotes(sites, st.PHP)...)
	out = append(out, resourceNotes(s)...)
	out = append(out, siteNotes(sites)...)
	out = append(out, apacheNotes(d.Apache, st.Apache, s)...)
	out = append(out, fpmDiagNotes(d.FPM, s)...)
	out = append(out, mysqlNotes(d.MySQL, st.MySQL, s)...)
	out = append(out, mysqlInstancesNotes(d.MySQLInstances)...)
	out = append(out, nginxConfigNotes(d.Nginx, d.Apache)...)
	out = append(out, procsNotes(d.Procs)...)
	out = append(out, serviceLogNotes("nginx", d.NginxLog)...)
	out = append(out, serviceLogNotes("MySQL", d.MySQLLog)...)
	out = append(out, oomNotes(d.OOM)...)
	out = append(out, memoryBudgetNotes(d.Memory)...)
	out = append(out, stuckNotes(d.Stuck)...)
	out = append(out, outboundNotes(d.Outbound)...)

	return out
}

// phpFPMNotes — корреляция между сайтами на php_fpm и состоянием masters.
func phpFPMNotes(sites []panel.Site, php []stack.PHPVersion) []Note {
	var out []Note

	fpmSitesByVer := map[string]int{}
	for _, s := range sites {
		if !s.Enabled || s.Handler != panel.HandlerPHPFPM || s.PHPVersion == "" {
			continue
		}
		fpmSitesByVer[s.PHPVersion]++
	}

	stackByVer := map[string]stack.PHPVersion{}
	for _, p := range php {
		stackByVer[p.Version] = p
	}

	for ver, n := range fpmSitesByVer {
		p, ok := stackByVer[ver]
		if !ok {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "php_version_missing",
				Text: fmt.Sprintf(
					"PHP %s используется %d сайтами через php-fpm, но не установлен на сервере",
					ver, n),
			})
			continue
		}
		if !p.MasterRunning {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "php_fpm_master_down",
				Text: fmt.Sprintf(
					"PHP %s: %d активных сайтов через php-fpm, но master не запущен — обращения вернут 502",
					ver, n),
			})
		}
	}

	var idle []string
	for _, p := range php {
		if !p.MasterRunning {
			continue
		}
		if p.Pools > 0 || fpmSitesByVer[p.Version] > 0 {
			continue
		}
		idle = append(idle, p.Version)
	}
	if len(idle) > 0 {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "php_fpm_masters_idle",
			Text: fmt.Sprintf(
				"PHP %s: masters запущены, но не обслуживают сайты — можно остановить и освободить RAM",
				strings.Join(idle, ", ")),
		})
	}

	// Сворачиваем "pool есть, master не запущен" во одну сводную ноту —
	// иначе на alt-php серверах (с 10+ предустановленными версиями) генерируется
	// длинный шум, который заслоняет важное.
	var orphan []string
	for _, p := range php {
		if p.MasterRunning || p.Pools == 0 {
			continue
		}
		orphan = append(orphan, p.Version)
	}
	if len(orphan) > 0 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "php_fpm_pools_orphan",
			Text: fmt.Sprintf(
				"PHP %s: пулы есть, master не запущен — конфиги без процесса (alt-php установлен, fpm выключен)",
				strings.Join(orphan, ", ")),
		})
	}

	return out
}

func resourceNotes(s sys.Info) []Note {
	var out []Note

	if s.MemTotalMB > 0 {
		availPct := 100 * s.MemAvailMB / s.MemTotalMB
		if availPct < 10 {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "ram_starved",
				Text: fmt.Sprintf(
					"Свободной RAM меньше 10%% (%d из %d MB) — риск OOM-килла процессов",
					s.MemAvailMB, s.MemTotalMB),
			})
		} else if availPct < 20 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "ram_tight",
				Text: fmt.Sprintf(
					"Свободной RAM около %d%% (%d из %d MB) — узкое место при пике",
					availPct, s.MemAvailMB, s.MemTotalMB),
			})
		}
	}

	if s.SwapTotalMB > 0 {
		swapUsedPct := 100 * (s.SwapTotalMB - s.SwapFreeMB) / s.SwapTotalMB
		if swapUsedPct >= 50 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "swap_heavy",
				Text: fmt.Sprintf(
					"Swap занят на %d%% (%d из %d MB) — система давно живёт в дефиците RAM",
					swapUsedPct, s.SwapTotalMB-s.SwapFreeMB, s.SwapTotalMB),
			})
		} else if swapUsedPct >= 20 {
			out = append(out, Note{
				Severity: SevInfo,
				Code:     "swap_active",
				Text: fmt.Sprintf(
					"Swap используется на %d%% (%d из %d MB)",
					swapUsedPct, s.SwapTotalMB-s.SwapFreeMB, s.SwapTotalMB),
			})
		}
	}

	if la := parseLoad(s.Load1); la > 0 && s.CPUCount > 0 {
		ratio := la / float64(s.CPUCount)
		if ratio >= 2.0 {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "la_overload",
				Text: fmt.Sprintf(
					"LA %s при %d ядрах (отношение %.1f×CPU) — сервер перегружен",
					s.Load1, s.CPUCount, ratio),
			})
		} else if ratio >= 1.0 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "la_high",
				Text: fmt.Sprintf(
					"LA %s при %d ядрах (отношение %.1f×CPU) — все ядра под нагрузкой",
					s.Load1, s.CPUCount, ratio),
			})
		}
	}

	return out
}

func siteNotes(sites []panel.Site) []Note {
	var out []Note

	disabled := 0
	var unknown []string
	for _, s := range sites {
		if !s.Enabled {
			disabled++
		}
		if s.Handler == panel.HandlerUnknown {
			unknown = append(unknown, s.Name)
		}
	}
	if disabled > 0 && len(sites) > 0 {
		pct := 100 * disabled / len(sites)
		if pct >= 30 {
			out = append(out, Note{
				Severity: SevInfo,
				Code:     "many_disabled_sites",
				Text: fmt.Sprintf(
					"%d из %d сайтов (%d%%) выключены — можно проверить, не остались ли от ушедших клиентов",
					disabled, len(sites), pct),
			})
		}
	}
	if len(unknown) > 0 {
		list := strings.Join(unknown, ", ")
		if len(list) > 160 {
			list = list[:157] + "..."
		}
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "sites_unknown_handler",
			Text: fmt.Sprintf(
				"%d сайт(ов) с непознанным handler (%s) — serverdoc не понял что это; пришлите вывод mogwai/mgrctl для этих доменов",
				len(unknown), list),
		})
	}

	return out
}

func apacheNotes(a *diag.ApacheState, stk *stack.Apache, s sys.Info) []Note {
	if a == nil {
		return nil
	}
	var out []Note

	if a.MaxRequestWorkers > 0 {
		// Считаем безопасную рекомендуемую границу с учётом памяти:
		// сколько вмещается в 70% RAM при текущем avg RSS воркера.
		var recommendedMax int
		if a.AvgWorkerRSSMB > 0 && s.MemTotalMB > 0 {
			recommendedMax = (s.MemTotalMB * 70 / 100) / a.AvgWorkerRSSMB
		}
		switch {
		case a.UtilizationPercent >= 95:
			act := apacheMaxWorkersAction(a, recommendedMax, true)
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "apache_workers_saturated",
				Text: fmt.Sprintf(
					"Apache: %d/%d воркеров занято (%d%%) — упирается в MaxRequestWorkers, новые запросы встают в очередь",
					a.WorkersAlive, a.MaxRequestWorkers, a.UtilizationPercent),
				Action: act,
			})
		case a.UtilizationPercent >= 80:
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "apache_workers_high",
				Text: fmt.Sprintf(
					"Apache: %d/%d воркеров занято (%d%%) — приближается к лимиту MaxRequestWorkers",
					a.WorkersAlive, a.MaxRequestWorkers, a.UtilizationPercent),
				Action: apacheMaxWorkersAction(a, recommendedMax, false),
			})
		}
	}

	if len(a.RecentMPMErrors) > 0 {
		out = append(out, Note{
			Severity: SevCrit,
			Code:     "apache_mpm_errors",
			Text: fmt.Sprintf(
				"Apache: в error.log за последние 24ч %d критических MPM-сообщений (сервер упирался в лимит воркеров)",
				len(a.RecentMPMErrors)),
		})
	}

	if a.MaxIsDefault {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "apache_workers_default",
			Text: fmt.Sprintf(
				"Apache: MaxRequestWorkers не задан в конфигах — используется compile-time default (%d). Стоит зафиксировать явно",
				a.MaxRequestWorkers),
			Action: maxWorkersConfigHint(),
		})
	}

	// Память: если все воркеры зайдут, влезут ли они в RAM.
	if a.ProjectedRAMMB > 0 && s.MemTotalMB > 0 {
		pct := 100 * a.ProjectedRAMMB / s.MemTotalMB
		switch {
		case pct >= 100:
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "apache_memory_oom_risk",
				Text: fmt.Sprintf(
					"Apache: при упоре в MaxRequestWorkers (%d × %d MB) понадобится %d MB — больше всей RAM (%d MB). OOM-killer гарантирован",
					a.MaxRequestWorkers, a.AvgWorkerRSSMB, a.ProjectedRAMMB, s.MemTotalMB),
			})
		case pct >= 70:
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "apache_memory_risk",
				Text: fmt.Sprintf(
					"Apache: при упоре в MaxRequestWorkers займёт ~%d MB (%d%% RAM, ~%d MB на воркер × %d) — не хватит места для остальных сервисов",
					a.ProjectedRAMMB, pct, a.AvgWorkerRSSMB, a.MaxRequestWorkers),
			})
		}
	}

	// KeepAlive on + prefork с долгим таймаутом = воркеры висят на idle-keepalive.
	if stk != nil && stk.MPM == "prefork" && a.Config.KeepAlive == "On" && a.Config.KeepAliveTimeout > 5 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "apache_keepalive_prefork",
			Text: fmt.Sprintf(
				"Apache prefork + KeepAlive On + KeepAliveTimeout=%dс — каждый idle-клиент держит занятым целый воркер пока не разорвёт соединение. Для prefork типично 2-5с или KeepAlive Off",
				a.Config.KeepAliveTimeout),
			Action: []string{
				"снизить keepalive в конфиге httpd:",
				"    KeepAliveTimeout 3",
				"  ИЛИ выключить полностью (nginx впереди обычно сам делает keepalive):",
				"    KeepAlive Off",
				"  затем: systemctl reload apache2 (или httpd)",
			},
		})
	}

	// Объединённая нота про таймауты Apache+fcgid: вместо 3 отдельных
	// (Timeout, FcgidIOTimeout, FcgidBusyTimeout) — одна сводная,
	// потому что инженер всё равно меняет их вместе.
	if n := apacheTimeoutNote(a.Config, stk); n != nil {
		out = append(out, *n)
	}

	// Дополнительные fcgid-ноты (не про таймауты).
	out = append(out, fcgidExtraNotes(a.Config)...)

	// MPM event/worker без ThreadsPerChild — берётся compile default (25).
	if stk != nil && (stk.MPM == "event" || stk.MPM == "worker") && a.Config.ThreadsPerChild == 0 {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "apache_mpm_event_no_threads",
			Text: fmt.Sprintf(
				"Apache MPM %s: ThreadsPerChild не задан — используется default. Эффективная пропускная способность зависит от ServerLimit × ThreadsPerChild",
				stk.MPM),
		})
	}

	return out
}

// apacheTimeoutNote собирает все таймаутные параметры Apache+fcgid в одну
// сводную ноту. Вместо 3 отдельных предупреждений (которые читаются как "три
// разные проблемы") даёт цельную картину "сколько секунд PHP может тупить".
func apacheTimeoutNote(cfg diag.ApacheConfig, stk *stack.Apache) *Note {
	timeout := cfg.Timeout
	var ioTimeout, busyTimeout int
	if cfg.Fcgid != nil {
		ioTimeout = cfg.Fcgid.IOTimeout
		busyTimeout = cfg.Fcgid.BusyTimeout
	}
	if timeout < 120 && ioTimeout < 120 && busyTimeout < 300 {
		return nil
	}

	worst := timeout
	if ioTimeout > worst {
		worst = ioTimeout
	}
	if busyTimeout > worst {
		worst = busyTimeout
	}

	parts := []string{}
	if timeout > 0 {
		parts = append(parts, fmt.Sprintf("Apache Timeout=%dс", timeout))
	}
	if ioTimeout > 0 {
		parts = append(parts, fmt.Sprintf("FcgidIOTimeout=%dс", ioTimeout))
	}
	if busyTimeout > 0 {
		parts = append(parts, fmt.Sprintf("FcgidBusyTimeout=%dс", busyTimeout))
	}

	mpmContext := ""
	if stk != nil && stk.MPM == "prefork" {
		mpmContext = fmt.Sprintf(" При prefork один зависший запрос занимает воркер до %d мин",
			worst/60)
	}

	// Конкретные команды в зависимости от ОС семейства.
	action := []string{"снизить до 60с (Apache+fcgid) в конфиге httpd:"}
	if dirExists("/etc/apache2") {
		action = append(action, "  /etc/apache2/conf.d/*.conf или /etc/apache2/conf-enabled/*.conf")
	} else if dirExists("/etc/httpd") {
		action = append(action, "  /etc/httpd/conf.d/*.conf")
	}
	action = append(action,
		"    Timeout 60",
		"    FcgidIOTimeout 60",
		"    FcgidBusyTimeout 90",
		"  затем: systemctl reload apache2 (или httpd)")

	return &Note{
		Severity: SevWarn,
		Code:     "apache_timeouts_high",
		Text: fmt.Sprintf(
			"Таймауты Apache/fcgid завышены (%s) — зависший backend держит воркер до %dс.%s Типично 30-60с",
			strings.Join(parts, ", "), worst, mpmContext),
		Action: action,
	}
}

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// maxWorkersConfigHint — путь файла где задавать MaxRequestWorkers
// (зависит от ОС: Debian vs RHEL и активный MPM).
func maxWorkersConfigHint() []string {
	var lines []string
	switch {
	case dirExists("/etc/apache2/mods-enabled"):
		lines = []string{
			"задать явно в /etc/apache2/mods-enabled/mpm_prefork.conf",
			"(или mpm_event.conf — смотрите какой MPM активен: apache2ctl -V):",
			"    <IfModule mpm_prefork_module>",
			"        ServerLimit          400",
			"        MaxRequestWorkers    400",
			"    </IfModule>",
			"  затем: systemctl reload apache2",
		}
	case dirExists("/etc/httpd/conf.modules.d"):
		lines = []string{
			"задать явно в /etc/httpd/conf.modules.d/00-mpm.conf",
			"(внутри секции <IfModule mpm_prefork_module> или _event_):",
			"    ServerLimit          400",
			"    MaxRequestWorkers    400",
			"  затем: systemctl reload httpd",
		}
	default:
		lines = []string{
			"задать явно в основном конфиге Apache (httpd.conf или conf.d/*.conf):",
			"    <IfModule mpm_prefork_module>",
			"        ServerLimit          400",
			"        MaxRequestWorkers    400",
			"    </IfModule>",
		}
	}
	return lines
}

// apacheMaxWorkersAction — конкретный совет по подъёму лимита воркеров.
// Учитывает recommendedMax (исходя из доступной RAM) — чтобы не предложить
// поднять до значения которое сразу даст OOM.
func apacheMaxWorkersAction(a *diag.ApacheState, recommendedMax int, urgent bool) []string {
	var out []string
	if urgent {
		out = append(out, "срочно одно из:")
		out = append(out, "  1) уменьшить таймауты (FcgidIOTimeout/Timeout/BusyTimeout до 60с) — освободит зависшие")
		out = append(out, "  2) поднять MaxRequestWorkers (если есть запас по RAM)")
	} else {
		out = append(out, "поднять MaxRequestWorkers с учётом памяти:")
	}
	target := a.MaxRequestWorkers * 2
	if recommendedMax > 0 && recommendedMax < target {
		target = recommendedMax
	}
	if a.AvgWorkerRSSMB > 0 {
		out = append(out, fmt.Sprintf("  безопасный максимум по RAM: %d воркеров (avg RSS %d MB × max = 70%% RAM)",
			recommendedMax, a.AvgWorkerRSSMB))
	}
	out = append(out, fmt.Sprintf("  рекомендуемое значение: %d", target))
	out = append(out, maxWorkersConfigHint()...)
	return out
}

// fcgidExtraNotes — fcgid параметры не связанные с таймаутами
// (MaxProcesses, MaxRequestsPerProcess).
func fcgidExtraNotes(cfg diag.ApacheConfig) []Note {
	if cfg.Fcgid == nil {
		return nil
	}
	f := cfg.Fcgid
	var out []Note

	if f.MaxProcesses > 0 && f.MaxProcesses < 50 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "fcgid_max_processes_low",
			Text: fmt.Sprintf(
				"mod_fcgid: FcgidMaxProcesses=%d — общий лимит php-cgi на весь Apache. При множестве сайтов мал — кто-то будет ждать. Дефолт 1000",
				f.MaxProcesses),
			Action: []string{
				"увеличить в /etc/httpd/conf.d/fcgid.conf (или /etc/apache2/mods-enabled/fcgid.conf):",
				"    FcgidMaxProcesses 200",
				"    FcgidMaxProcessesPerClass 20",
				"  затем: systemctl reload apache2 (или httpd)",
			},
		})
	}

	if f.MaxRequestsPerProcess == 0 {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "fcgid_no_max_requests",
			Text:     "mod_fcgid: FcgidMaxRequestsPerProcess не задан — php-cgi процессы не перезапускаются, утечки памяти могут накапливаться. Типично 500-10000",
		})
	}

	return out
}

func fpmDiagNotes(states []diag.FPMState, s sys.Info) []Note {
	var out []Note

	totalProjectedMB := 0
	for _, st := range states {
		// Сводные счётчики по версии — чтобы не плодить десятки одинаковых нот.
		var noTermPools, noMaxReqPools, staticHighPools []string

		for _, p := range st.Pools {
			if p.MaxChildren > 0 {
				switch {
				case p.UtilizationPercent >= 95:
					out = append(out, Note{
						Severity: SevCrit,
						Code:     "fpm_pool_saturated",
						Text: fmt.Sprintf(
							"PHP %s пул %s: %d/%d воркеров (%d%%) — упёрся в pm.max_children, новые запросы ждут",
							st.Version, p.Name, p.WorkersAlive, p.MaxChildren, p.UtilizationPercent),
					})
				case p.UtilizationPercent >= 80:
					out = append(out, Note{
						Severity: SevWarn,
						Code:     "fpm_pool_high",
						Text: fmt.Sprintf(
							"PHP %s пул %s: %d/%d воркеров (%d%%) — высокая утилизация",
							st.Version, p.Name, p.WorkersAlive, p.MaxChildren, p.UtilizationPercent),
					})
				}
			}
			if p.MaxRequests == 0 && p.MaxChildren > 0 {
				noMaxReqPools = append(noMaxReqPools, p.Name)
			}
			if p.RequestTerminateTimeout == 0 && p.MaxChildren > 0 {
				noTermPools = append(noTermPools, p.Name)
			}
			if p.PM == "static" && p.MaxChildren >= 50 {
				staticHighPools = append(staticHighPools, p.Name)
			}
		}

		// Сводные ноты на версию.
		if len(noTermPools) > 0 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "fpm_no_terminate_timeout",
				Text: fmt.Sprintf(
					"PHP %s: %d пулов без request_terminate_timeout (%s) — зависший PHP-запрос занимает воркера до перезапуска fpm",
					st.Version, len(noTermPools), summarizeList(noTermPools, 5)),
				Action: []string{
					"добавить в каждый pool.conf затронутых пулов:",
					"    request_terminate_timeout = 60s",
					"  типичные пути:",
					"    /etc/php/X.Y/fpm/pool.d/<domain>.conf  (Debian)",
					"    /opt/phpXY/etc/php-fpm.d/<domain>.conf (alt-php ISP/FastPanel)",
					fmt.Sprintf("  затем: systemctl reload php%s-fpm", st.Version),
				},
			})
		}
		if len(noMaxReqPools) > 0 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "fpm_no_max_requests",
				Text: fmt.Sprintf(
					"PHP %s: %d пулов с pm.max_requests=0 (%s) — воркеры не перезапускаются, утечки накапливаются",
					st.Version, len(noMaxReqPools), summarizeList(noMaxReqPools, 5)),
				Action: []string{
					"добавить в каждый pool.conf:",
					"    pm.max_requests = 500",
					fmt.Sprintf("  затем: systemctl reload php%s-fpm", st.Version),
				},
			})
		}
		if len(staticHighPools) > 0 {
			out = append(out, Note{
				Severity: SevInfo,
				Code:     "fpm_pm_static_high",
				Text: fmt.Sprintf(
					"PHP %s: пулы pm=static с большим max_children (%s) — память выделяется по верхнему лимиту",
					st.Version, summarizeList(staticHighPools, 5)),
				Action: []string{
					"если нагрузка переменная — заменить на pm=dynamic или ondemand:",
					"    pm = dynamic",
					"    pm.start_servers = 4",
					"    pm.min_spare_servers = 2",
					"    pm.max_spare_servers = 8",
				},
			})
		}

		totalProjectedMB += st.ProjectedRAMMB
	}

	// Совокупный memory risk: PHP-FPM при упоре в max_children.
	if totalProjectedMB > 0 && s.MemTotalMB > 0 {
		pct := 100 * totalProjectedMB / s.MemTotalMB
		switch {
		case pct >= 100:
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "fpm_memory_oom_risk",
				Text: fmt.Sprintf(
					"PHP-FPM: при упоре всех пулов в pm.max_children понадобится ~%d MB — больше всей RAM (%d MB). OOM-killer гарантирован",
					totalProjectedMB, s.MemTotalMB),
			})
		case pct >= 70:
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "fpm_memory_risk",
				Text: fmt.Sprintf(
					"PHP-FPM: при упоре всех пулов займёт ~%d MB (%d%% RAM) — не хватит места для остальных сервисов",
					totalProjectedMB, pct),
			})
		}
	}

	return out
}

func serviceLogNotes(name string, l *diag.ServiceLogState) []Note {
	if l == nil || len(l.Categories) == 0 {
		return nil
	}
	var out []Note
	for _, cat := range l.Categories {
		sev := SevInfo
		switch cat.Severity {
		case "crit":
			sev = SevCrit
		case "warn":
			sev = SevWarn
		}
		out = append(out, Note{
			Severity: sev,
			Code:     cat.Code,
			Text: fmt.Sprintf(
				"%s error.log за %dч: %s (×%d)",
				name, l.PeriodHours, cat.Description, cat.Count),
		})
	}
	return out
}

func oomNotes(o *diag.OOMState) []Note {
	if o == nil || o.EventCount == 0 {
		return nil
	}
	// ByProcess содержит счёт по ВСЕМ событиям (не только показанным 10).
	var procList []string
	mostlyMySQL := false
	for p, n := range o.ByProcess {
		if n > 1 {
			procList = append(procList, fmt.Sprintf("%s×%d", p, n))
		} else {
			procList = append(procList, p)
		}
		if p == "mysqld" || p == "mariadbd" {
			mostlyMySQL = true
		}
	}
	// Сортируем чтобы вывод был стабильным.
	sort.Strings(procList)
	procs := strings.Join(procList, ", ")

	action := []string{
		"посмотреть жертв подробнее:",
		"    grep -i 'killed process' /var/log/messages /var/log/kern.log 2>/dev/null | tail -20",
	}
	if mostlyMySQL {
		action = append(action,
			"OOM убивает MySQL/MariaDB → почти всегда innodb_buffer_pool_size слишком велик.",
			"  проверить: mysql -e \"SELECT @@innodb_buffer_pool_size/1024/1024 AS MB;\"",
			"  снизить до 35-50% RAM в [mysqld] раздел my.cnf и рестарт mysql",
			"  при Docker — проверить --memory лимит контейнера: docker stats")
	}
	action = append(action,
		"включить vm.overcommit логи для будущих инцидентов:",
		"    sysctl vm.panic_on_oom=0 (по умолчанию 0)",
		"    journalctl -k --grep='oom' --since '7 days ago'")

	return []Note{{
		Severity: SevCrit,
		Code:     "oom_recent",
		Text: fmt.Sprintf(
			"OOM-killer убил %d процессов за 7 дней (%s) — сервер периодически уходит в дефицит RAM",
			o.EventCount, procs),
		Action: action,
	}}
}

func mysqlNotes(m *diag.MySQLState, srv *stack.Service, s sys.Info) []Note {
	if m == nil {
		return nil
	}
	var out []Note

	if !m.AccessOK {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "mysql_no_access",
			Text:     "MySQL: serverdoc не смог подключиться (нет socket-auth для root или .my.cnf) — диагностика БД пропущена",
		})
		return out
	}

	if m.MaxConnections > 0 {
		switch {
		case m.UtilizationPercent >= 90:
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "mysql_connections_saturated",
				Text: fmt.Sprintf(
					"MySQL: %d/%d соединений (%d%%) — близко к max_connections, новые сайты будут ловить 'Too many connections'",
					m.ThreadsConnected, m.MaxConnections, m.UtilizationPercent),
			})
		case m.UtilizationPercent >= 70:
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "mysql_connections_high",
				Text: fmt.Sprintf(
					"MySQL: %d/%d соединений (%d%%) — приближается к max_connections",
					m.ThreadsConnected, m.MaxConnections, m.UtilizationPercent),
			})
		}
	}

	if m.LongRunningCount > 0 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "mysql_long_queries",
			Text: fmt.Sprintf(
				"MySQL: %d запросов выполняются дольше 30 секунд — возможный runaway или блокировка",
				m.LongRunningCount),
		})
	}

	if n := m.QueriesByState["Locked"] + m.QueriesByState["Waiting for table metadata lock"]; n > 0 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "mysql_lock_contention",
			Text: fmt.Sprintf(
				"MySQL: %d запросов в состоянии блокировки — возможна lock contention",
				n),
		})
	}

	cfg := m.Config

	// innodb_buffer_pool_size vs RAM.
	if cfg.InnodbBufferPoolMB > 0 && s.MemTotalMB > 0 {
		pct := 100 * cfg.InnodbBufferPoolMB / s.MemTotalMB
		// Рекомендованный размер: 40-50% RAM для dedicated DB, 25-35% для shared.
		recommendedMB := s.MemTotalMB * 35 / 100
		if pct >= 50 {
			act := []string{
				fmt.Sprintf("снизить до ~%d MB (35%% RAM):", recommendedMB),
				"  в /etc/mysql/my.cnf или /etc/my.cnf раздел [mysqld]:",
				fmt.Sprintf("    innodb_buffer_pool_size = %dM", recommendedMB),
				"  затем: systemctl restart mysql (или mysqld/mariadb)",
				"  ВНИМАНИЕ: restart MySQL — короткий downtime, делать в окно",
			}
			if pct >= 70 {
				out = append(out, Note{
					Severity: SevCrit,
					Code:     "mysql_buffer_pool_oversize",
					Text: fmt.Sprintf(
						"MySQL: innodb_buffer_pool_size=%d MB — %d%% всей RAM (%d MB). MySQL зарезервирует это под себя, на Apache/PHP останется мало → риск OOM",
						cfg.InnodbBufferPoolMB, pct, s.MemTotalMB),
					Action: act,
				})
			} else {
				out = append(out, Note{
					Severity: SevWarn,
					Code:     "mysql_buffer_pool_large",
					Text: fmt.Sprintf(
						"MySQL: innodb_buffer_pool_size=%d MB — %d%% всей RAM",
						cfg.InnodbBufferPoolMB, pct),
					Action: act,
				})
			}
		}
	}

	// query_cache_size > 0: интерпретация зависит от движка/версии:
	//  - MySQL 8.0+: query cache физически удалён, переменная фантомная — не шумим
	//  - MySQL 5.x: deprecated, всё ещё работает — warn если включён
	//  - MariaDB: работает, но deprecated с 10.10 — info
	if cfg.QueryCacheMB > 0 {
		if note := mysqlQueryCacheNote(cfg.QueryCacheMB, srv); note != nil {
			out = append(out, *note)
		}
	}

	// wait_timeout слишком большой — idle-соединения держат ресурсы.
	if cfg.WaitTimeout >= 28800 {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "mysql_wait_timeout_high",
			Text: fmt.Sprintf(
				"MySQL: wait_timeout=%dс (%.1fч) — idle-соединения держатся очень долго. Типично 600-1800",
				cfg.WaitTimeout, float64(cfg.WaitTimeout)/3600),
		})
	}

	// slow_query_log выключен — нет видимости медленных запросов.
	if cfg.SlowQueryLog == "OFF" {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "mysql_slow_query_disabled",
			Text:     "MySQL: slow_query_log=OFF — нет видимости что замедляет БД",
			Action: []string{
				"включить runtime (без рестарта):",
				"  mysql -e \"SET GLOBAL slow_query_log=ON; SET GLOBAL long_query_time=2;\"",
				"для постоянной фиксации добавьте в [mysqld] my.cnf:",
				"    slow_query_log = 1",
				"    slow_query_log_file = /var/log/mysql/slow.log",
				"    long_query_time = 2",
			},
		})
	}

	return out
}

// mysqlInstancesNotes — ноты про множественные MySQL инстансы.
// Часто корень "не понимаю откуда столько RAM" — два mysqld из разных
// источников (системный + Docker).
func mysqlInstancesNotes(instances []diag.MySQLInstance) []Note {
	if len(instances) <= 1 {
		return nil
	}
	containerized, native := 0, 0
	totalMB := 0
	for _, inst := range instances {
		if inst.Containerized {
			containerized++
		} else {
			native++
		}
		totalMB += inst.RSSMB
	}
	desc := fmt.Sprintf("найдено %d инстансов MySQL/MariaDB (нативных %d, в контейнерах %d) суммарно ~%d MB RSS",
		len(instances), native, containerized, totalMB)

	action := []string{
		"проверить какие инстансы реально нужны:",
		"    ps auxf | grep -E 'mysqld|mariadbd'",
		"    docker ps --filter ancestor=mysql --filter ancestor=mariadb",
	}
	if containerized > 0 {
		action = append(action,
			"для Docker-инстансов проверить лимиты памяти:",
			"    docker inspect <container> | grep -i memory")
	}
	if native > 0 && containerized > 0 {
		action = append(action,
			"если один из них — артефакт (старая инсталляция или забытый контейнер):",
			"    остановить ненужный — освободится RAM")
	}
	return []Note{{
		Severity: SevWarn,
		Code:     "mysql_multiple_instances",
		Text:     desc,
		Action:   action,
	}}
}

// mysqlQueryCacheNote возвращает ноту про query_cache_size с учётом движка
// и версии. Для MySQL 8.0+ — ничего (поле фантомное, советы бессмысленны).
func mysqlQueryCacheNote(mb int, srv *stack.Service) *Note {
	if srv == nil {
		return nil
	}
	ver := srv.Version // "8.0.44" / "11.4.5" / "10.6.25" / "5.7.42"
	major, minor := parseVerMajMin(ver)

	// MariaDB можно отличить по major >= 10 (у MySQL major 5/8).
	isMariaDB := major >= 10

	if !isMariaDB && major >= 8 {
		// MySQL 8.0+ — переменная фантомная, не предупреждаем.
		return nil
	}

	if isMariaDB {
		// MariaDB 10.10+ объявил deprecated. Раньше — нормально.
		if major > 10 || (major == 10 && minor >= 10) {
			return &Note{
				Severity: SevInfo,
				Code:     "mysql_query_cache_deprecated",
				Text: fmt.Sprintf(
					"MariaDB %s: query_cache_size=%d MB — deprecated с 10.10. Под нагрузкой обычно медленнее (mutex contention). Рассмотрите 0",
					ver, mb),
			}
		}
		// MariaDB 10.0-10.9 — это норма, ничего не сообщаем.
		return nil
	}

	// MySQL 5.x: deprecated, но рабочий.
	return &Note{
		Severity: SevWarn,
		Code:     "mysql_query_cache_legacy",
		Text: fmt.Sprintf(
			"MySQL %s: query_cache_size=%d MB — deprecated в 5.7, удалён в 8.0. Под нагрузкой mutex contention; типично выставить 0",
			ver, mb),
	}
}

// parseVerMajMin вытаскивает major.minor из "8.0.44" / "11.4.5" / "10.6.25-MariaDB".
func parseVerMajMin(ver string) (int, int) {
	v := strings.SplitN(ver, "-", 2)[0]
	parts := strings.SplitN(v, ".", 3)
	if len(parts) < 2 {
		return 0, 0
	}
	major, _ := strconv.Atoi(parts[0])
	minor, _ := strconv.Atoi(parts[1])
	return major, minor
}

func nginxConfigNotes(n *diag.NginxState, a *diag.ApacheState) []Note {
	if n == nil {
		return nil
	}
	cfg := n.Config
	var out []Note

	// Слишком мало capacity — узкое место при пике.
	if cfg.EffectiveCapacity > 0 && cfg.EffectiveCapacity < 2048 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "nginx_capacity_low",
			Text: fmt.Sprintf(
				"nginx: worker_processes×worker_connections = %d одновременных соединений. При пике может стать узким местом",
				cfg.EffectiveCapacity),
		})
	}

	// fastcgi_read_timeout vs Apache+fcgid IOTimeout — должны быть согласованы.
	// Если nginx закрывает раньше Apache — пользователь получает 504 пока
	// Apache+fcgid продолжает молотить запрос.
	if a != nil && a.Config.Fcgid != nil && cfg.FastcgiReadTimeout > 0 {
		if a.Config.Fcgid.IOTimeout > 0 && cfg.FastcgiReadTimeout != a.Config.Fcgid.IOTimeout {
			out = append(out, Note{
				Severity: SevInfo,
				Code:     "nginx_fastcgi_timeout_mismatch",
				Text: fmt.Sprintf(
					"nginx fastcgi_read_timeout=%dс не совпадает с Apache FcgidIOTimeout=%dс — какой-то закроет первым. Согласуйте значения",
					cfg.FastcgiReadTimeout, a.Config.Fcgid.IOTimeout),
			})
		}
	}

	// worker_rlimit_nofile vs capacity.
	if cfg.WorkerRlimitNofile > 0 && cfg.EffectiveCapacity > 0 &&
		cfg.WorkerRlimitNofile < 2*cfg.EffectiveCapacity {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "nginx_rlimit_low",
			Text: fmt.Sprintf(
				"nginx: worker_rlimit_nofile=%d при capacity %d — мало. Каждое соединение = 2+ fd (клиент+upstream). Поднять до %d+",
				cfg.WorkerRlimitNofile, cfg.EffectiveCapacity, cfg.EffectiveCapacity*2),
		})
	}

	return out
}

func stuckNotes(s *diag.StuckWorkersState) []Note {
	if s == nil || s.Skipped || s.StuckCount == 0 {
		return nil
	}
	// Сводим: сколько с привязкой к сайту, сколько с outbound.
	withSite, withOutbound, dState := 0, 0, 0
	var firstWithSite, firstWithOutbound *diag.StuckWorker
	for i := range s.Workers {
		w := &s.Workers[i]
		if w.Site != "" {
			withSite++
			if firstWithSite == nil {
				firstWithSite = w
			}
		}
		if len(w.Outbound) > 0 {
			withOutbound++
			if firstWithOutbound == nil {
				firstWithOutbound = w
			}
		}
		if w.State == "D" {
			dState++
		}
	}
	out := []Note{{
		Severity: SevWarn,
		Code:     "stuck_workers",
		Text: fmt.Sprintf(
			"Зависших воркеров: %d (из %d). С привязкой к сайту: %d, с открытыми исходящими: %d, в D-state: %d",
			s.StuckCount, s.WorkersTotal, withSite, withOutbound, dState),
	}}
	if firstWithOutbound != nil {
		out = append(out, Note{
			Severity: SevCrit,
			Code:     "stuck_with_outbound",
			Text: fmt.Sprintf(
				"PID %d (%s, сайт %s) висит и держит исходящий коннект на %s — почти наверняка PHP ждёт ответа внешнего сервиса",
				firstWithOutbound.PID, firstWithOutbound.Process,
				dash(firstWithOutbound.Site), strings.Join(firstWithOutbound.Outbound, ", ")),
		})
	}
	if dState >= 3 {
		out = append(out, Note{
			Severity: SevCrit,
			Code:     "stuck_dstate",
			Text: fmt.Sprintf(
				"%d воркеров в D-state (ждут I/O ядра) — обычно диск или сетевая ФС перегружены",
				dState),
		})
	}
	return out
}

func outboundNotes(o *diag.OutboundState) []Note {
	if o == nil {
		return nil
	}
	var out []Note

	if o.TotalSynSent >= 3 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "outbound_syn_sent",
			Text: fmt.Sprintf(
				"%d исходящих TCP в состоянии SYN_SENT — соединения не устанавливаются (фаервол назначения / упавший remote / таймаут)",
				o.TotalSynSent),
		})
	}

	// Один remote endpoint собирает много коннектов — концентрированная точка отказа.
	if len(o.TopRemotes) > 0 && o.TopRemotes[0].Count >= 5 {
		t := o.TopRemotes[0]
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "outbound_concentrated",
			Text: fmt.Sprintf(
				"К %s держится %d исходящих коннектов от %d процессов — если этот сервис тормозит, %d воркеров висят с ним",
				t.Endpoint, t.Count, len(t.PIDs), t.Count),
		})
	}

	return out
}

// dash возвращает "—" если строка пустая, иначе саму строку (для notes).
func dash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

// summarizeList возвращает строку "a, b, c +N ещё" если список длиннее limit,
// иначе просто "a, b, c". Чтобы длинные ноты с десятками pool name не раздували
// отчёт.
func summarizeList(items []string, limit int) string {
	if len(items) <= limit {
		return strings.Join(items, ", ")
	}
	return strings.Join(items[:limit], ", ") + fmt.Sprintf(", +%d ещё", len(items)-limit)
}

func memoryBudgetNotes(b *diag.MemoryBudget) []Note {
	if b == nil || b.CommitMB == 0 {
		return nil
	}
	// Action общая для обоих severity — но в crit сильнее.
	mkAction := func() []string {
		return []string{
			"возможные шаги (по убыванию обычной эффективности):",
			fmt.Sprintf("  1) MySQL buffer_pool ~ %d MB → уменьшить если >35%% RAM (см. ноту mysql_buffer_pool)", b.MySQLBufferMB),
			fmt.Sprintf("  2) Apache MaxRequestWorkers (сейчас даёт ~%d MB) → снизить лимит", b.ApacheMaxMB),
			"  3) PHP-FPM pm.max_children на тяжёлых пулах → снизить",
			"  4) docker stats — проверить лимиты памяти контейнеров",
		}
	}
	switch {
	case b.UtilizationPercent >= 100:
		return []Note{{
			Severity: SevCrit,
			Code:     "memory_budget_overflow",
			Text: fmt.Sprintf(
				"Бюджет памяти при max нагрузке: %d MB при RAM %d MB (%d%%) — RAM не хватит на пике, риск OOM",
				b.CommitMB, b.TotalMB, b.UtilizationPercent),
			Action: mkAction(),
		}}
	case b.UtilizationPercent >= 70:
		return []Note{{
			Severity: SevWarn,
			Code:     "memory_budget_tight",
			Text: fmt.Sprintf(
				"Бюджет памяти при max нагрузке: %d MB при RAM %d MB (%d%%) — запас по памяти невелик",
				b.CommitMB, b.TotalMB, b.UtilizationPercent),
			Action: mkAction(),
		}}
	}
	return nil
}

func procsNotes(p *diag.ProcsState) []Note {
	if p == nil {
		return nil
	}
	var out []Note

	if p.DState >= 5 {
		out = append(out, Note{
			Severity: SevCrit,
			Code:     "dstate_storm",
			Text: fmt.Sprintf(
				"%d процессов в состоянии D (ждут I/O) — почти всегда дисковая подсистема в перегрузке",
				p.DState),
		})
	} else if p.DState >= 2 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "dstate_some",
			Text: fmt.Sprintf(
				"%d процессов в состоянии D — стоит проверить дисковую активность (iostat/iotop)",
				p.DState),
		})
	}

	if p.Zombie >= 10 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "zombies_many",
			Text: fmt.Sprintf(
				"%d zombie-процессов — родитель не вызывает wait(), возможна утечка PID",
				p.Zombie),
		})
	}

	return out
}

func parseLoad(s string) float64 {
	var f float64
	_, err := fmt.Sscanf(s, "%f", &f)
	if err != nil {
		return 0
	}
	return f
}
