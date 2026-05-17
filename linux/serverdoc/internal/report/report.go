// Package report формирует отчёт — человекочитаемый текст или JSON.
package report

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"serverdoc/internal/diag"
	"serverdoc/internal/notes"
	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

// Version устанавливается из main через ldflags.
var Version = "dev"

// Report — полный снимок состояния сервера.
type Report struct {
	Sys      sys.Info     `json:"system"`
	Panel    string       `json:"panel"`
	Sites    []panel.Site `json:"sites"`
	SiteWarn string       `json:"sites_warning,omitempty"`
	Stack    stack.Stack  `json:"stack"`
	Diag     diag.Report  `json:"diag"`
	Notes    []notes.Note `json:"notes,omitempty"`
}

// JSON выводит отчёт машинным форматом.
func (r Report) JSON(w io.Writer) {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(r)
}

// Text выводит человекочитаемый отчёт.
func (r Report) Text(w io.Writer, color bool) {
	c := palette(color)
	p := func(format string, a ...interface{}) { fmt.Fprintf(w, format+"\n", a...) }

	renderHeader(p, r, c)

	// --- Система ---
	p("")
	p("%sСИСТЕМА%s", c.head, c.reset)
	s := r.Sys
	p("  Хост:    %s", s.Hostname)
	p("  ОС:      %s %s · ядро %s", s.OSName, s.OSVersion, s.Kernel)
	p("  CPU:     %d ядер · LA %s", s.CPUCount, s.Load1)
	p("  RAM:     %d MB всего · %d MB доступно", s.MemTotalMB, s.MemAvailMB)
	if s.SwapTotalMB > 0 {
		p("  Swap:    %d MB всего · %d MB свободно", s.SwapTotalMB, s.SwapFreeMB)
	} else {
		p("  Swap:    отсутствует")
	}

	// --- Панель и сайты ---
	p("")
	p("%sПАНЕЛЬ И САЙТЫ%s", c.head, c.reset)
	p("  Панель:  %s", r.Panel)

	active, disabled := 0, 0
	byHandler := map[string]int{}
	byPHP := map[string]int{}
	for _, st := range r.Sites {
		if st.Enabled {
			active++
		} else {
			disabled++
		}
		if st.Handler != "" {
			byHandler[handlerLabel(st.Handler)]++
		}
		if st.PHPVersion != "" {
			byPHP[st.PHPVersion]++
		}
	}
	if disabled > 0 {
		p("  Сайтов:  %d (активных %d, выключенных %d)", len(r.Sites), active, disabled)
	} else {
		p("  Сайтов:  %d", len(r.Sites))
	}
	if r.SiteWarn != "" {
		p("  %s! %s%s", c.warn, r.SiteWarn, c.reset)
	}
	if len(byHandler) > 0 {
		p("  Хендлеры:      %s", joinCounts(byHandler))
	}
	if len(byPHP) > 0 {
		p("  PHP по сайтам: %s", joinCounts(byPHP))
	}

	// --- Стек ---
	p("")
	p("%sСТЕК%s", c.head, c.reset)
	if a := r.Stack.Apache; a != nil {
		p("  Apache:  %s · MPM %s · %s", dash(a.Version), dash(a.MPM), runState(a.Running, c))
	} else {
		p("  Apache:  не обнаружен")
	}
	if n := r.Stack.Nginx; n != nil {
		p("  nginx:   %s · %s", dash(n.Version), runState(n.Running, c))
	} else {
		p("  nginx:   не обнаружен")
	}
	if m := r.Stack.MySQL; m != nil {
		p("  MySQL:   %s · %s", dash(m.Version), runState(m.Running, c))
	} else {
		p("  MySQL:   не обнаружен")
	}
	renderPHP(p, r.Stack.PHP, byPHP, c)

	// --- Динамика ---
	if hasDiag(r.Diag) {
		p("")
		p("%sДИНАМИКА%s", c.head, c.reset)
		renderApacheDiag(p, r.Diag.Apache, c)
		renderFPMDiag(p, r.Diag.FPM, c)
		renderMySQLDiag(p, r.Diag.MySQL, c)
		renderProcsDiag(p, r.Diag.Procs, c)
		renderLogsDiag(p, r.Diag.Logs, c)
	}

	// --- Логи сервисов ---
	if hasServiceLogs(r.Diag) {
		p("")
		p("%sЛОГИ СЕРВИСОВ (за 24ч)%s", c.head, c.reset)
		renderServiceLog(p, "nginx", r.Diag.NginxLog, c)
		renderServiceLog(p, "MySQL", r.Diag.MySQLLog, c)
	}

	// --- OOM ---
	if r.Diag.OOM != nil && (r.Diag.OOM.EventCount > 0 || r.Diag.OOM.Note != "") {
		p("")
		p("%sOOM-KILLER (7 дней)%s", c.head, c.reset)
		renderOOM(p, r.Diag.OOM, c)
	}

	// --- Замечания ---
	if len(r.Notes) > 0 {
		p("")
		p("%sЗАМЕЧАНИЯ%s", c.head, c.reset)
		for _, n := range orderNotes(r.Notes) {
			marker, col := severityMarker(n.Severity, c)
			p("  %s %s%s%s", marker, col, n.Text, c.reset)
		}
	}

	p("")
}

// renderHeader — баннер с версией, хостом, временем и счётчиком замечаний по severity.
func renderHeader(p func(string, ...interface{}), r Report, c colors) {
	crit, warn := 0, 0
	for _, n := range r.Notes {
		switch n.Severity {
		case notes.SevCrit:
			crit++
		case notes.SevWarn:
			warn++
		}
	}

	const width = 76
	line := strings.Repeat("═", width)

	title := fmt.Sprintf("serverdoc %s · диагностика Вашего сервера", Version)
	subtitle := fmt.Sprintf("%s · %s · %s", r.Sys.Hostname, r.Panel,
		time.Now().Format("2006-01-02 15:04:05 MST"))

	status := c.ok + "проблем не найдено" + c.reset
	switch {
	case crit > 0 && warn > 0:
		status = fmt.Sprintf("%s%d критичных%s · %s%d предупреждений%s",
			c.bad, crit, c.reset, c.warn, warn, c.reset)
	case crit > 0:
		status = fmt.Sprintf("%s%d критичных проблем%s", c.bad, crit, c.reset)
	case warn > 0:
		status = fmt.Sprintf("%s%d предупреждений%s", c.warn, warn, c.reset)
	}

	p("")
	p("%s╔%s╗%s", c.bold, line, c.reset)
	p("%s║%s %s%-*s%s%s║%s", c.bold, c.reset, c.bold, width-2, title, c.reset, c.bold, c.reset)
	p("%s║%s %-*s%s║%s", c.bold, c.reset, width-2, subtitle, c.bold, c.reset)
	p("%s╚%s╝%s", c.bold, line, c.reset)
	p("  Статус:  %s", status)
}

func hasDiag(d diag.Report) bool {
	return d.Apache != nil || len(d.FPM) > 0 || d.MySQL != nil || d.Procs != nil || d.Logs != nil
}

func hasServiceLogs(d diag.Report) bool {
	has := func(l *diag.ServiceLogState) bool {
		return l != nil && (len(l.Categories) > 0 || l.Note != "")
	}
	return has(d.NginxLog) || has(d.MySQLLog)
}

func renderServiceLog(p func(string, ...interface{}), name string, l *diag.ServiceLogState, c colors) {
	if l == nil {
		return
	}
	if l.Note != "" {
		p("  %-7s %s%s%s", name+":", c.warn, l.Note, c.reset)
		return
	}
	if len(l.Categories) == 0 {
		p("  %-7s чисто (%d сообщений за период)", name+":", l.TotalMatched)
		return
	}
	p("  %-7s %d сообщений (%s):", name+":", l.TotalMatched, l.LogPath)
	for _, cat := range l.Categories {
		col := c.head
		switch cat.Severity {
		case "crit":
			col = c.bad
		case "warn":
			col = c.warn
		}
		p("           %s×%d%s %s", col, cat.Count, c.reset, cat.Description)
		for _, ex := range cat.Examples {
			p("             %s", ex)
		}
	}
}

func renderOOM(p func(string, ...interface{}), o *diag.OOMState, c colors) {
	if o.Note != "" {
		p("  %s%s%s", c.warn, o.Note, c.reset)
		return
	}
	p("  Источник: %s · событий: %s%d%s", o.Source, c.bad, o.EventCount, c.reset)
	for _, e := range o.RecentEvents {
		rss := ""
		if e.AnonRSSKB > 0 {
			rss = fmt.Sprintf(" · %d MB RSS", e.AnonRSSKB/1024)
		}
		when := e.Time
		if when == "" {
			when = "?"
		}
		p("    %s · %s%s (pid %d)%s%s", when, c.bad, e.Process, e.PID, c.reset, rss)
	}
}

func renderApacheDiag(p func(string, ...interface{}), a *diag.ApacheState, c colors) {
	if a == nil {
		return
	}
	col := c.ok
	if a.UtilizationPercent >= 95 {
		col = c.bad
	} else if a.UtilizationPercent >= 80 {
		col = c.warn
	}
	maxStr := "?"
	if a.MaxRequestWorkers > 0 {
		maxStr = fmt.Sprintf("%d", a.MaxRequestWorkers)
		if a.MaxIsDefault {
			maxStr += " (default)"
		}
		maxStr = fmt.Sprintf("%s · %s%d%%%s", maxStr, col, a.UtilizationPercent, c.reset)
	}
	p("  Apache:  воркеров живо %d из %s", a.WorkersAlive, maxStr)

	// Estimated memory at full load.
	if a.ProjectedRAMMB > 0 {
		p("           средний RSS воркера %d MB · при полной загрузке ~%d MB",
			a.AvgWorkerRSSMB, a.ProjectedRAMMB)
	}

	// Конфиг — компактной строкой.
	cfg := a.Config
	parts := []string{}
	if cfg.Timeout > 0 {
		parts = append(parts, fmt.Sprintf("Timeout=%d", cfg.Timeout))
	}
	if cfg.KeepAlive != "" {
		ka := fmt.Sprintf("KeepAlive=%s", cfg.KeepAlive)
		if cfg.KeepAliveTimeout > 0 {
			ka += fmt.Sprintf("/%ds", cfg.KeepAliveTimeout)
		}
		parts = append(parts, ka)
	}
	if cfg.MaxConnectionsPerChild > 0 {
		parts = append(parts, fmt.Sprintf("MaxConnPerChild=%d", cfg.MaxConnectionsPerChild))
	}
	if cfg.ThreadsPerChild > 0 {
		parts = append(parts, fmt.Sprintf("ThreadsPerChild=%d", cfg.ThreadsPerChild))
	}
	if len(parts) > 0 {
		p("           конфиг: %s", strings.Join(parts, " · "))
	}

	if len(a.RecentMPMErrors) > 0 {
		p("           %sв error.log за 24ч %d MPM-ошибок (упор в MaxRequestWorkers)%s",
			c.bad, len(a.RecentMPMErrors), c.reset)
	}
}

func renderFPMDiag(p func(string, ...interface{}), states []diag.FPMState, c colors) {
	if len(states) == 0 {
		return
	}
	for _, s := range states {
		col := c.ok
		if s.UtilizationPercent >= 95 {
			col = c.bad
		} else if s.UtilizationPercent >= 80 {
			col = c.warn
		}
		ramExtra := ""
		if s.AvgWorkerRSSMB > 0 {
			ramExtra = fmt.Sprintf(", avg worker %d MB → ~%d MB при упоре",
				s.AvgWorkerRSSMB, s.ProjectedRAMMB)
		}
		p("  PHP %s: воркеров %d из %d (%s%d%%%s), пулов %d%s",
			s.Version, s.WorkersTotal, s.MaxChildrenTotal, col, s.UtilizationPercent, c.reset, len(s.Pools), ramExtra)
		// Топ-3 пулов с наибольшей утилизацией ИЛИ с критичными настройками.
		shown := 0
		for _, p2 := range s.Pools {
			interesting := p2.UtilizationPercent >= 50 ||
				p2.MaxRequests == 0 ||
				p2.RequestTerminateTimeout == 0
			if !interesting || shown >= 5 {
				continue
			}
			poolCol := ""
			if p2.UtilizationPercent >= 80 {
				poolCol = c.warn
			}
			if p2.UtilizationPercent >= 95 {
				poolCol = c.bad
			}
			extras := []string{}
			if p2.PM != "" {
				extras = append(extras, "pm="+p2.PM)
			}
			if p2.MaxRequests == 0 {
				extras = append(extras, c.warn+"max_requests=0"+c.reset)
			} else {
				extras = append(extras, fmt.Sprintf("max_req=%d", p2.MaxRequests))
			}
			if p2.RequestTerminateTimeout == 0 {
				extras = append(extras, c.warn+"no_term_timeout"+c.reset)
			} else {
				extras = append(extras, fmt.Sprintf("term=%ds", p2.RequestTerminateTimeout))
			}
			p("           пул %s: %s%d/%d (%d%%)%s · %s",
				p2.Name, poolCol, p2.WorkersAlive, p2.MaxChildren, p2.UtilizationPercent, c.reset,
				strings.Join(extras, " · "))
			shown++
		}
	}
}

func renderMySQLDiag(p func(string, ...interface{}), m *diag.MySQLState, c colors) {
	if m == nil {
		return
	}
	if !m.AccessOK {
		p("  MySQL:   %sнет доступа: %s%s", c.warn, m.AccessError, c.reset)
		return
	}
	col := c.ok
	if m.UtilizationPercent >= 90 {
		col = c.bad
	} else if m.UtilizationPercent >= 70 {
		col = c.warn
	}
	p("  MySQL:   %d/%d соединений (%s%d%%%s), активных запросов %d",
		m.ThreadsConnected, m.MaxConnections, col, m.UtilizationPercent, c.reset, m.ThreadsRunning)
	if m.LongRunningCount > 0 {
		p("           %sдолгих запросов (>30с): %d%s", c.warn, m.LongRunningCount, c.reset)
		for i, q := range m.LongRunning {
			if i >= 3 {
				break
			}
			info := q.InfoHead
			if info == "" {
				info = "(нет SQL)"
			}
			p("             #%d %ds %s@%s: %s", q.ID, q.TimeSec, q.User, q.DB, info)
		}
	}
}

func renderProcsDiag(p func(string, ...interface{}), pr *diag.ProcsState, c colors) {
	if pr == nil {
		return
	}
	line := fmt.Sprintf("процессов %d", pr.Total)
	if pr.DState > 0 {
		col := c.warn
		if pr.DState >= 5 {
			col = c.bad
		}
		line += fmt.Sprintf(" · %sD-state %d%s", col, pr.DState, c.reset)
	}
	if pr.Zombie > 0 {
		col := c.warn
		if pr.Zombie >= 10 {
			col = c.bad
		}
		line += fmt.Sprintf(" · %szombie %d%s", col, pr.Zombie, c.reset)
	}
	p("  Процессы: %s", line)
	if len(pr.DStateProcs) > 0 {
		for _, d := range pr.DStateProcs {
			p("           %sD-state PID %d (%s): %s%s", c.bad, d.PID, d.Name, d.Cmdline, c.reset)
		}
	}
	if len(pr.TopByRSS) > 0 {
		parts := make([]string, 0, len(pr.TopByRSS))
		for _, t := range pr.TopByRSS {
			parts = append(parts, fmt.Sprintf("%s=%dMB", t.Name, t.RSSMB))
		}
		p("           top RAM: %s", strings.Join(parts, ", "))
	}
}

func renderLogsDiag(p func(string, ...interface{}), l *diag.LogsState, c colors) {
	if l == nil {
		return
	}
	if l.Note != "" {
		p("  Логи:    %s%s%s", c.warn, l.Note, c.reset)
		return
	}
	p("  Логи (%dм, файлов %d): всего запросов %d", l.PeriodMinutes, l.ParsedFiles, l.TotalRequests)
	for i, s := range l.TopSites {
		if i >= 5 {
			break
		}
		col := ""
		if s.RequestsPerSec >= 10 {
			col = c.warn
		}
		if s.RequestsPerSec >= 50 {
			col = c.bad
		}
		p("           %s%-35s %6d req · %.1f rps%s", col, truncate(s.Site, 35), s.Requests, s.RequestsPerSec, c.reset)
	}
}

func orderNotes(in []notes.Note) []notes.Note {
	rank := map[notes.Severity]int{notes.SevCrit: 0, notes.SevWarn: 1, notes.SevInfo: 2}
	out := make([]notes.Note, len(in))
	copy(out, in)
	sort.SliceStable(out, func(i, j int) bool {
		return rank[out[i].Severity] < rank[out[j].Severity]
	})
	return out
}

func severityMarker(s notes.Severity, c colors) (string, string) {
	switch s {
	case notes.SevCrit:
		return c.bad + "✗" + c.reset, c.bad
	case notes.SevWarn:
		return c.warn + "!" + c.reset, c.warn
	default:
		return c.head + "·" + c.reset, ""
	}
}

// renderPHP печатает PHP-версии, сворачивая "пустые" (master запущен,
// 0 пулов, 0 сайтов на этой версии) в одну строку.
func renderPHP(p func(string, ...interface{}), php []stack.PHPVersion, byPHP map[string]int, c colors) {
	if len(php) == 0 {
		p("  PHP-FPM: не обнаружен")
		return
	}

	var empty []string
	for _, v := range php {
		if v.MasterRunning && v.Pools == 0 && byPHP[v.Version] == 0 {
			empty = append(empty, v.Version)
			continue
		}
		state := c.warn + "master не запущен" + c.reset
		if v.MasterRunning {
			state = c.ok + "master запущен" + c.reset
		}
		src := ""
		if v.Service != "" {
			src = " · " + v.Service
		}
		p("  PHP %s: %d пулов · %s%s", v.Version, v.Pools, state, src)
	}
	if len(empty) > 0 {
		p("  PHP %s: установлены, без пулов и сайтов · %smaster запущен%s",
			strings.Join(empty, ", "), c.ok, c.reset)
	}
}

// ---------------------------------------------------------------------------
// Хелперы вывода
// ---------------------------------------------------------------------------

type colors struct{ bold, reset, head, warn, ok, bad string }

func palette(on bool) colors {
	if !on {
		return colors{}
	}
	return colors{
		bold:  "\033[1m",
		reset: "\033[0m",
		head:  "\033[1;36m",
		warn:  "\033[33m",
		ok:    "\033[32m",
		bad:   "\033[31m",
	}
}

func runState(running bool, c colors) string {
	if running {
		return c.ok + "запущен" + c.reset
	}
	return c.bad + "не запущен" + c.reset
}

func dash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func handlerLabel(h string) string {
	switch h {
	case panel.HandlerPHPFPM:
		return "nginx+php-fpm"
	case panel.HandlerApacheFCGID:
		return "apache+fcgid"
	case panel.HandlerApacheModPHP:
		return "apache+mod_php"
	case panel.HandlerApacheMPMITK:
		return "apache+mpm_itk"
	case panel.HandlerCGI:
		return "cgi"
	case panel.HandlerLSAPI:
		return "lsapi"
	case panel.HandlerStatic:
		return "static"
	case panel.HandlerNodeJS:
		return "nodejs"
	case panel.HandlerSystemd:
		return "systemd"
	case panel.HandlerNone:
		return "no-php"
	default:
		return h
	}
}

func joinCounts(m map[string]int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s×%d", k, m[k]))
	}
	return strings.Join(parts, ", ")
}
