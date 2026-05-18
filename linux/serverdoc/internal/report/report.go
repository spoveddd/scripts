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
	if s.HasDocker {
		p("  Docker:  обнаружен — некоторые процессы могут быть из контейнеров")
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
		renderApacheDiag(p, r.Diag.Apache, r.Stack.Apache, c)
		renderNginxDiag(p, r.Diag.Nginx, c)
		renderFPMDiag(p, r.Diag.FPM, c)
		renderMySQLDiag(p, r.Diag.MySQL, r.Diag.MySQLInstances, c)
		renderProcsDiag(p, r.Diag.Procs, c)
		renderLogsDiag(p, r.Diag.Logs, c)
	}

	// --- Память ---
	if r.Diag.Memory != nil {
		p("")
		p("%sПАМЯТЬ ПРИ MAX НАГРУЗКЕ%s", c.head, c.reset)
		renderMemoryBudget(p, r.Diag.Memory, c)
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

	// --- Исходящие соединения ---
	if r.Diag.Outbound != nil && (r.Diag.Outbound.TotalEstablished > 0 || r.Diag.Outbound.TotalSynSent > 0) {
		p("")
		p("%sИСХОДЯЩИЕ СОЕДИНЕНИЯ (apache/php/nginx)%s", c.head, c.reset)
		renderOutbound(p, r.Diag.Outbound, c)
	}

	// --- Зависшие воркеры ---
	if r.Diag.Stuck != nil {
		p("")
		p("%sЗАВИСАНИЯ (sampling /proc)%s", c.head, c.reset)
		renderStuck(p, r.Diag.Stuck, c)
	}

	// --- Замечания ---
	if len(r.Notes) > 0 {
		p("")
		p("%sЗАМЕЧАНИЯ%s", c.head, c.reset)
		const wrapWidth = reportWidth - 4 // - "  X " (4 руны)
		for _, n := range orderNotes(r.Notes) {
			marker, col := severityMarker(n.Severity, c)
			// Текст ноты — с word-wrap.
			lines := wrapText(n.Text, wrapWidth)
			for i, ln := range lines {
				if i == 0 {
					p("  %s %s%s%s", marker, col, ln, c.reset)
				} else {
					p("    %s%s%s", col, ln, c.reset)
				}
			}
			// Рекомендации — другим цветом и с маркером "→".
			for j, act := range n.Action {
				prefix := "    → "
				if j > 0 {
					prefix = "      "
				}
				// Action может содержать многострочные блоки конфига — wrap не применяем.
				p("%s%s%s%s", prefix, c.dim, act, c.reset)
			}
		}
	}

	p("")
	p("  %sserverdoc --help для опций · --json для машинного вывода · --quick без sampling%s",
		c.dim, c.reset)
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

	// reportWidth — общая визуальная ширина рамки (включая ║ слева и справа).
	// Внутри: ║ + " " + content + " " + ║ → contentWidth = reportWidth-4.
	const contentWidth = reportWidth - 4
	line := strings.Repeat("═", reportWidth-2)

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
	p("%s║%s %s%s%s %s║%s", c.bold, c.reset, c.bold, padRunes(title, contentWidth), c.reset, c.bold, c.reset)
	p("%s║%s %s %s║%s", c.bold, c.reset, padRunes(subtitle, contentWidth), c.bold, c.reset)
	p("%s╚%s╝%s", c.bold, line, c.reset)
	p("  Статус:  %s", status)
}

// reportWidth — стандартная ширина отчёта.
const reportWidth = 80

// padRunes обрезает строку до n рун или дополняет пробелами справа.
// Используется потому что fmt.Sprintf %-*s считает по runes ОК, но если
// строка случайно длиннее лимита, она ломает рамку. Здесь жёстко.
func padRunes(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		r = r[:n-1]
		r = append(r, '…')
	}
	for len(r) < n {
		r = append(r, ' ')
	}
	return string(r)
}

// printJoined печатает строку "label: a · b · c" с переносом частей на
// следующую строку если общая длина больше maxWidth рун. Continuation
// выравнивается под содержимое (длина label + ": " пробелов).
// Это нужно чтобы конфиг-параметры (Timeout, KeepAlive, fcgid, mysql conf и т.п.)
// не вылезали за ширину отчёта.
func printJoined(p func(string, ...interface{}), prefix string, parts []string, maxWidth int) {
	if len(parts) == 0 {
		return
	}
	indent := strings.Repeat(" ", runeLen(prefix))
	cur := prefix + parts[0]
	curLen := runeLen(cur)
	for _, part := range parts[1:] {
		seg := " · " + part
		segLen := runeLen(seg)
		if curLen+segLen > maxWidth {
			p("%s", cur)
			cur = indent + part
			curLen = runeLen(cur)
		} else {
			cur += seg
			curLen += segLen
		}
	}
	p("%s", cur)
}

// wrapText переносит длинный текст по словам. Возвращает срез строк, каждая
// не длиннее width рун. Слова длиннее width оставляем как есть (не режем).
func wrapText(s string, width int) []string {
	words := strings.Fields(s)
	if len(words) == 0 {
		return []string{""}
	}
	var lines []string
	cur := words[0]
	curLen := runeLen(cur)
	for _, w := range words[1:] {
		wl := runeLen(w)
		if curLen+1+wl <= width {
			cur += " " + w
			curLen += 1 + wl
		} else {
			lines = append(lines, cur)
			cur = w
			curLen = wl
		}
	}
	lines = append(lines, cur)
	return lines
}

func runeLen(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
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

func renderMemoryBudget(p func(string, ...interface{}), b *diag.MemoryBudget, c colors) {
	col := c.ok
	verdict := "запас есть"
	switch {
	case b.UtilizationPercent >= 100:
		col, verdict = c.bad, "не хватит RAM на пике"
	case b.UtilizationPercent >= 70:
		col, verdict = c.warn, "запас невелик"
	}
	p("  Всего RAM:            %d MB", b.TotalMB)
	if b.ApacheMaxMB > 0 {
		p("  Apache @ max:         %d MB", b.ApacheMaxMB)
	}
	if b.FPMMaxMB > 0 {
		p("  PHP-FPM @ max:        %d MB", b.FPMMaxMB)
	}
	if b.MySQLBufferMB > 0 {
		p("  MySQL buffers:        %d MB", b.MySQLBufferMB)
	}
	if b.SystemBaseMB > 0 {
		p("  Система (база):       %d MB", b.SystemBaseMB)
	}
	p("  ──────────────────────────────")
	p("  При full load:        %s%d MB / %d MB (%d%%) — %s%s",
		col, b.CommitMB, b.TotalMB, b.UtilizationPercent, verdict, c.reset)
}

func renderOutbound(p func(string, ...interface{}), o *diag.OutboundState, c colors) {
	totals := fmt.Sprintf("%d ESTABLISHED", o.TotalEstablished)
	if o.TotalSynSent > 0 {
		totals += fmt.Sprintf(" · %s%d SYN_SENT (висят на коннекте)%s", c.warn, o.TotalSynSent, c.reset)
	}
	p("  %s", totals)
	if len(o.TopProcesses) > 0 {
		p("  По процессам:")
		for i, pp := range o.TopProcesses {
			if i >= 6 {
				break
			}
			extras := fmt.Sprintf("%d ESTABLISHED", pp.Established)
			if pp.SynSent > 0 {
				extras += fmt.Sprintf(" + %s%d SYN_SENT%s", c.warn, pp.SynSent, c.reset)
			}
			ep := strings.Join(pp.Remotes, ", ")
			if len(ep) > 100 {
				ep = ep[:97] + "..."
			}
			p("    PID %d %s — %s → %s", pp.PID, pp.ProcessName, extras, ep)
		}
	}
	if len(o.TopRemotes) > 0 {
		p("  Топ remote endpoints:")
		for i, r := range o.TopRemotes {
			if i >= 5 {
				break
			}
			p("    %s — %d коннектов от %d процессов", r.Endpoint, r.Count, len(r.PIDs))
		}
	}
}

func renderStuck(p func(string, ...interface{}), s *diag.StuckWorkersState, c colors) {
	if s.Skipped {
		p("  %sпропущено (--quick)%s", c.warn, c.reset)
		return
	}
	p("  %d снимков /proc за %.1fс · worker-процессов %d · подозрительных %d",
		s.Samples, float64(s.SampleSpanMs)/1000.0, s.WorkersTotal, s.StuckCount)
	if s.WorkersTotal == 0 {
		p("  %sworker-процессов нет — Apache/PHP не обслуживают запросы прямо сейчас%s", c.warn, c.reset)
		return
	}
	if s.StuckCount == 0 {
		p("  %sне найдено зависших — воркеры либо активны, либо нормально спят на epoll%s", c.ok, c.reset)
		return
	}
	for i, w := range s.Workers {
		if i >= 8 {
			break
		}
		col := c.warn
		if w.State == "D" {
			col = c.bad
		}
		site := w.Site
		if site == "" {
			site = "?"
		}
		p("    %sPID %d %s state=%s%s · сайт: %s · wchan: %s",
			col, w.PID, w.Process, w.State, c.reset, site, dash(w.Wchan))
		p("      cmd: %s", w.CmdHead)
		if len(w.Outbound) > 0 {
			ep := strings.Join(w.Outbound, ", ")
			if len(ep) > 120 {
				ep = ep[:117] + "..."
			}
			p("      %sждёт ответа от: %s%s", c.bad, ep, c.reset)
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

func renderApacheDiag(p func(string, ...interface{}), a *diag.ApacheState, stk *stack.Apache, c colors) {
	if a == nil {
		return
	}
	mpm := ""
	if stk != nil {
		mpm = stk.MPM
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

	// Estimated memory at full load. RSS-based — реальное потребление ниже
	// из-за shared memory (libphp/libapr).
	if a.ProjectedRAMMB > 0 {
		p("           средний RSS %d MB · при упоре ~%d MB (RSS-оценка, реально меньше)",
			a.AvgWorkerRSSMB, a.ProjectedRAMMB)
	}

	// Конфиг — компактной строкой.
	cfg := a.Config
	parts := []string{}
	if cfg.Timeout > 0 {
		parts = append(parts, fmt.Sprintf("Timeout=%ds", cfg.Timeout))
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
	// ThreadsPerChild релевантен только для threaded MPM (event/worker).
	// При prefork Apache его игнорирует — не зашумляем.
	if cfg.ThreadsPerChild > 0 && (mpm == "event" || mpm == "worker") {
		parts = append(parts, fmt.Sprintf("ThreadsPerChild=%d", cfg.ThreadsPerChild))
	}
	if len(parts) > 0 {
		printJoined(p, "           конфиг: ", parts, reportWidth)
	}

	// mod_fcgid — если найден в конфигах.
	if f := cfg.Fcgid; f != nil {
		fparts := []string{}
		if f.IOTimeout > 0 {
			col := ""
			if f.IOTimeout >= 120 {
				col = c.warn
			}
			fparts = append(fparts, fmt.Sprintf("%sIOTimeout=%ds%s", col, f.IOTimeout, c.reset))
		}
		if f.ConnectTimeout > 0 {
			fparts = append(fparts, fmt.Sprintf("ConnectTimeout=%ds", f.ConnectTimeout))
		}
		if f.BusyTimeout > 0 {
			fparts = append(fparts, fmt.Sprintf("BusyTimeout=%ds", f.BusyTimeout))
		}
		if f.IdleTimeout > 0 {
			fparts = append(fparts, fmt.Sprintf("IdleTimeout=%ds", f.IdleTimeout))
		}
		if f.ProcessLifeTime > 0 {
			fparts = append(fparts, fmt.Sprintf("LifeTime=%ds", f.ProcessLifeTime))
		}
		if f.MaxProcesses > 0 {
			fparts = append(fparts, fmt.Sprintf("MaxProcesses=%d", f.MaxProcesses))
		}
		if f.MaxProcessesPerClass > 0 {
			fparts = append(fparts, fmt.Sprintf("PerClass=%d", f.MaxProcessesPerClass))
		}
		if f.MaxRequestsPerProcess > 0 {
			fparts = append(fparts, fmt.Sprintf("MaxReq=%d", f.MaxRequestsPerProcess))
		}
		if len(fparts) > 0 {
			printJoined(p, "           fcgid:  ", fparts, reportWidth)
		}
	}

	// mpm_itk — если найден.
	if itk := cfg.MPMITK; itk != nil {
		iparts := []string{}
		if itk.MaxRequestWorkers > 0 {
			iparts = append(iparts, fmt.Sprintf("MaxRequestWorkers=%d", itk.MaxRequestWorkers))
		}
		if itk.MaxConnectionsPerChild > 0 {
			iparts = append(iparts, fmt.Sprintf("MaxConnPerChild=%d", itk.MaxConnectionsPerChild))
		}
		if itk.NiceValue != 0 {
			iparts = append(iparts, fmt.Sprintf("NiceValue=%d", itk.NiceValue))
		}
		if len(iparts) > 0 {
			printJoined(p, "           itk:    ", iparts, reportWidth)
		}
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

func renderMySQLDiag(p func(string, ...interface{}), m *diag.MySQLState, instances []diag.MySQLInstance, c colors) {
	if m == nil {
		return
	}
	// Список инстансов: если их >1, показываем явно — это часто Docker+native.
	if len(instances) > 1 {
		p("  MySQL инстансы: %d (mysql client отвечает на один)", len(instances))
		for _, inst := range instances {
			label := "native"
			if inst.Containerized {
				label = inst.CgroupHint
				if label == "" {
					label = "containerized"
				}
			}
			p("           PID %d %s · RSS %d MB · %s",
				inst.PID, inst.Name, inst.RSSMB, label)
		}
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

	// Config — компактной строкой.
	cfg := m.Config
	parts := []string{}
	if cfg.InnodbBufferPoolMB > 0 {
		parts = append(parts, fmt.Sprintf("innodb_buffer=%dMB", cfg.InnodbBufferPoolMB))
	}
	if cfg.KeyBufferMB > 0 {
		parts = append(parts, fmt.Sprintf("key_buffer=%dMB", cfg.KeyBufferMB))
	}
	if cfg.WaitTimeout > 0 {
		parts = append(parts, fmt.Sprintf("wait_timeout=%ds", cfg.WaitTimeout))
	}
	if cfg.MaxAllowedPacketMB > 0 {
		parts = append(parts, fmt.Sprintf("max_packet=%dMB", cfg.MaxAllowedPacketMB))
	}
	if cfg.SlowQueryLog != "" {
		slow := "slow_log=" + cfg.SlowQueryLog
		if cfg.LongQueryTime > 0 {
			slow += fmt.Sprintf(" (long_query=%.1fs)", cfg.LongQueryTime)
		}
		parts = append(parts, slow)
	}
	if len(parts) > 0 {
		printJoined(p, "           конфиг: ", parts, reportWidth)
	}

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

func renderNginxDiag(p func(string, ...interface{}), n *diag.NginxState, c colors) {
	if n == nil {
		return
	}
	cfg := n.Config
	parts := []string{}
	if cfg.WorkerProcesses != "" {
		parts = append(parts, "worker_processes="+cfg.WorkerProcesses)
	}
	if cfg.WorkerConnections > 0 {
		parts = append(parts, fmt.Sprintf("worker_connections=%d", cfg.WorkerConnections))
	}
	if cfg.EffectiveCapacity > 0 {
		parts = append(parts, fmt.Sprintf("capacity=%d", cfg.EffectiveCapacity))
	}
	if cfg.FastcgiReadTimeout > 0 {
		parts = append(parts, fmt.Sprintf("fastcgi_read_timeout=%ds", cfg.FastcgiReadTimeout))
	}
	if cfg.ProxyReadTimeout > 0 {
		parts = append(parts, fmt.Sprintf("proxy_read_timeout=%ds", cfg.ProxyReadTimeout))
	}
	if cfg.KeepaliveTimeout > 0 {
		parts = append(parts, fmt.Sprintf("keepalive_timeout=%ds", cfg.KeepaliveTimeout))
	}
	if cfg.ClientMaxBodySize != "" {
		parts = append(parts, "client_max_body="+cfg.ClientMaxBodySize)
	}
	if len(parts) > 0 {
		printJoined(p, "  nginx:   ", parts, reportWidth)
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
		if a, b := rank[out[i].Severity], rank[out[j].Severity]; a != b {
			return a < b
		}
		return out[i].Code < out[j].Code
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

// renderPHP печатает PHP-версии, сворачивая шумные категории в одну строку
// каждая: "idle masters" (запущены, никем не используются — съедают RAM)
// и "dormant" (установлены, не запущены, не используются — alt-php пакеты).
func renderPHP(p func(string, ...interface{}), php []stack.PHPVersion, byPHP map[string]int, c colors) {
	if len(php) == 0 {
		p("  PHP-FPM: не обнаружен")
		return
	}

	var idle, dormant []string
	for _, v := range php {
		unused := v.Pools == 0 && byPHP[v.Version] == 0
		if unused && v.MasterRunning {
			idle = append(idle, v.Version)
			continue
		}
		if unused && !v.MasterRunning {
			dormant = append(dormant, v.Version)
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
	if len(idle) > 0 {
		p("  PHP %s: %smaster запущен, но не обслуживает сайты%s",
			strings.Join(idle, ", "), c.warn, c.reset)
	}
	if len(dormant) > 0 {
		p("  PHP %s: установлены, не запущены, без сайтов", strings.Join(dormant, ", "))
	}
}

// ---------------------------------------------------------------------------
// Хелперы вывода
// ---------------------------------------------------------------------------

type colors struct{ bold, reset, head, warn, ok, bad, dim string }

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
		dim:   "\033[2m",
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
