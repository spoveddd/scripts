// Package notes — фактологические наблюдения по снапшоту состояния.
// Не даёт советов — только корреляции, которые инженер интерпретирует сам.
// База для будущих рекомендаций (Фаза 4).
package notes

import (
	"fmt"
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
	out = append(out, mysqlNotes(d.MySQL)...)
	out = append(out, procsNotes(d.Procs)...)
	out = append(out, serviceLogNotes("nginx", d.NginxLog)...)
	out = append(out, serviceLogNotes("MySQL", d.MySQLLog)...)
	out = append(out, oomNotes(d.OOM)...)

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

	for _, p := range php {
		if p.MasterRunning || p.Pools == 0 {
			continue
		}
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "php_fpm_pools_orphan",
			Text: fmt.Sprintf(
				"PHP %s: %d пулов в %s, master не запущен — конфиги без процесса",
				p.Version, p.Pools, p.PoolDir),
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
	for _, s := range sites {
		if !s.Enabled {
			disabled++
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
				"Apache prefork + KeepAlive On + KeepAliveTimeout %d — каждый idle-клиент держит воркер. Снизить до 2-5 или выключить KeepAlive",
				a.Config.KeepAliveTimeout),
		})
	}

	// Большой Timeout при php_fpm/proxy — воркеры лежат пока бэкенд не ответит.
	if a.Config.Timeout >= 120 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "apache_timeout_high",
			Text: fmt.Sprintf(
				"Apache Timeout = %d сек — при зависании бэкенда воркеры будут висеть всё это время. Типичное значение 30-60",
				a.Config.Timeout),
		})
	}

	// MPM event/worker без ThreadsPerChild — берётся compile default (25), но
	// инженеру стоит увидеть это явно.
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

func mysqlNotes(m *diag.MySQLState) []Note {
	if m == nil {
		return nil
	}
	var out []Note

	if !m.AccessOK {
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "mysql_no_access",
			Text: "MySQL: serverdoc не смог подключиться (нет socket-auth для root или .my.cnf) — диагностика БД пропущена",
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

	// Подозрительные state'ы: "Locked" / "Waiting for table metadata lock" / "Sending data" > 5.
	if n := m.QueriesByState["Locked"] + m.QueriesByState["Waiting for table metadata lock"]; n > 0 {
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "mysql_lock_contention",
			Text: fmt.Sprintf(
				"MySQL: %d запросов в состоянии блокировки — возможна lock contention",
				n),
		})
	}

	return out
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
