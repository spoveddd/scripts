// Package notes — фактологические наблюдения по снапшоту состояния.
// Не даёт советов — только корреляции, которые инженер интерпретирует сам.
// База для будущих рекомендаций (Фаза 4).
package notes

import (
	"fmt"
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

// Note — одно наблюдение.
type Note struct {
	Severity Severity `json:"severity"`
	Code     string   `json:"code"` // машинный ID для будущих YAML-правил
	Text     string   `json:"text"`
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
		switch {
		case a.UtilizationPercent >= 95:
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "apache_workers_saturated",
				Text: fmt.Sprintf(
					"Apache: %d/%d воркеров занято (%d%%) — на грани MaxRequestWorkers, новые запросы будут вставать в очередь",
					a.WorkersAlive, a.MaxRequestWorkers, a.UtilizationPercent),
			})
		case a.UtilizationPercent >= 80:
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "apache_workers_high",
				Text: fmt.Sprintf(
					"Apache: %d/%d воркеров занято (%d%%) — приближается к лимиту MaxRequestWorkers",
					a.WorkersAlive, a.MaxRequestWorkers, a.UtilizationPercent),
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

	// Максимум — реальная "стоимость" одного зависшего запроса.
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

	return &Note{
		Severity: SevWarn,
		Code:     "apache_timeouts_high",
		Text: fmt.Sprintf(
			"Таймауты Apache/fcgid завышены (%s) — зависший backend держит воркер до %dс.%s Типично 30-60с",
			strings.Join(parts, ", "), worst, mpmContext),
	}
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
		// Утилизация по пулам.
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

			// pm.max_requests=0 — нет ротации воркеров, утечки накапливаются.
			if p.MaxRequests == 0 && p.MaxChildren > 0 {
				out = append(out, Note{
					Severity: SevWarn,
					Code:     "fpm_no_max_requests",
					Text: fmt.Sprintf(
						"PHP %s пул %s: pm.max_requests=0 — воркеры не перезапускаются, утечки памяти накапливаются. Стандартное значение 500-1000",
						st.Version, p.Name),
				})
			}

			// request_terminate_timeout=0 — зависший запрос съест воркера навсегда.
			if p.RequestTerminateTimeout == 0 && p.MaxChildren > 0 {
				out = append(out, Note{
					Severity: SevWarn,
					Code:     "fpm_no_terminate_timeout",
					Text: fmt.Sprintf(
						"PHP %s пул %s: request_terminate_timeout не задан — зависший запрос займёт воркера до перезапуска fpm",
						st.Version, p.Name),
				})
			}

			// pm=static с большим числом воркеров — всегда жрёт память по верхнему лимиту.
			if p.PM == "static" && p.MaxChildren >= 50 {
				out = append(out, Note{
					Severity: SevInfo,
					Code:     "fpm_pm_static_high",
					Text: fmt.Sprintf(
						"PHP %s пул %s: pm=static с %d воркеров — память выделяется по верхнему лимиту независимо от нагрузки",
						st.Version, p.Name, p.MaxChildren),
				})
			}

			// Slowlog не настроен — нет видимости что замедляет сайты.
			if p.SlowlogPath == "" || p.SlowlogTimeout == 0 {
				// Не критично, поэтому одна общая info-нота на пул не нужна — пропускаем чтобы не шуметь.
			}
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
	// Сводим: какие процессы убивались чаще всего.
	byProc := map[string]int{}
	for _, e := range o.RecentEvents {
		byProc[e.Process]++
	}
	var procList []string
	for p, n := range byProc {
		if n > 1 {
			procList = append(procList, fmt.Sprintf("%s×%d", p, n))
		} else {
			procList = append(procList, p)
		}
	}
	procs := strings.Join(procList, ", ")
	return []Note{{
		Severity: SevCrit,
		Code:     "oom_recent",
		Text: fmt.Sprintf(
			"OOM-killer убил %d процессов за 7 дней (%s) — сервер периодически уходит в дефицит RAM",
			o.EventCount, procs),
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
		switch {
		case pct >= 70:
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "mysql_buffer_pool_oversize",
				Text: fmt.Sprintf(
					"MySQL: innodb_buffer_pool_size=%d MB — %d%% всей RAM (%d MB). MySQL зарезервирует это под себя — на Apache/PHP останется мало",
					cfg.InnodbBufferPoolMB, pct, s.MemTotalMB),
			})
		case pct >= 50:
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "mysql_buffer_pool_large",
				Text: fmt.Sprintf(
					"MySQL: innodb_buffer_pool_size=%d MB — %d%% всей RAM. Проверьте что хватает остального под Apache+PHP",
					cfg.InnodbBufferPoolMB, pct),
			})
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
			Text:     "MySQL: slow_query_log=OFF — нет видимости что замедляет БД. Включить и поставить long_query_time=1-3",
		})
	}

	return out
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

func memoryBudgetNotes(b *diag.MemoryBudget) []Note {
	if b == nil || b.CommitMB == 0 {
		return nil
	}
	switch {
	case b.UtilizationPercent >= 100:
		return []Note{{
			Severity: SevCrit,
			Code:     "memory_budget_overflow",
			Text: fmt.Sprintf(
				"Бюджет памяти при max нагрузке: %d MB при RAM %d MB (%d%%) — RAM не хватит на пике",
				b.CommitMB, b.TotalMB, b.UtilizationPercent),
		}}
	case b.UtilizationPercent >= 70:
		return []Note{{
			Severity: SevWarn,
			Code:     "memory_budget_tight",
			Text: fmt.Sprintf(
				"Бюджет памяти при max нагрузке: %d MB при RAM %d MB (%d%%) — запас по памяти невелик",
				b.CommitMB, b.TotalMB, b.UtilizationPercent),
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
