// Package report формирует отчёт — человекочитаемый текст или JSON.
package report

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"

	"serverdoc/internal/diag"
	"serverdoc/internal/notes"
	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

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

	p("")
	p("%sserverdoc — снимок состояния сервера%s", c.bold, c.reset)

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

func hasDiag(d diag.Report) bool {
	return d.Apache != nil || len(d.FPM) > 0 || d.MySQL != nil || d.Procs != nil || d.Logs != nil
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
		maxStr = fmt.Sprintf("%d (%s%d%%%s)", a.MaxRequestWorkers, col, a.UtilizationPercent, c.reset)
	}
	p("  Apache:  воркеров живо %d из %s", a.WorkersAlive, maxStr)
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
		p("  PHP %s: воркеров %d из %d (%s%d%%%s), пулов %d",
			s.Version, s.WorkersTotal, s.MaxChildrenTotal, col, s.UtilizationPercent, c.reset, len(s.Pools))
		// Топ-3 пулов с наибольшей утилизацией.
		shown := 0
		for _, p2 := range s.Pools {
			if shown >= 3 || p2.UtilizationPercent < 50 {
				break
			}
			poolCol := c.warn
			if p2.UtilizationPercent >= 95 {
				poolCol = c.bad
			}
			p("           пул %s: %d/%d (%s%d%%%s)",
				p2.Name, p2.WorkersAlive, p2.MaxChildren, poolCol, p2.UtilizationPercent, c.reset)
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
