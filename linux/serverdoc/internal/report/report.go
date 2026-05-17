// Package report формирует отчёт — человекочитаемый текст или JSON.
package report

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"

	"serverdoc/internal/notes"
	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

// Report — полный снимок состояния сервера (Фаза 1).
type Report struct {
	Sys      sys.Info     `json:"system"`
	Panel    string       `json:"panel"`
	Sites    []panel.Site `json:"sites"`
	SiteWarn string       `json:"sites_warning,omitempty"`
	Stack    stack.Stack  `json:"stack"`
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

	// --- Замечания ---
	if len(r.Notes) > 0 {
		p("")
		p("%sЗАМЕЧАНИЯ%s", c.head, c.reset)
		// Сортируем по убыванию severity.
		ordered := orderNotes(r.Notes)
		for _, n := range ordered {
			marker, col := severityMarker(n.Severity, c)
			p("  %s %s%s%s", marker, col, n.Text, c.reset)
		}
	}

	p("")
}

// renderPHP печатает PHP-версии, сворачивая "пустые" (master запущен,
// 0 пулов, 0 сайтов на этой версии) в одну строку — иначе на серверах
// с 10+ установленными версиями (Hestia) отчёт переполняется шумом.
func renderPHP(p func(string, ...interface{}), php []stack.PHPVersion, byPHP map[string]int, c colors) {
	if len(php) == 0 {
		p("  PHP-FPM: не обнаружен")
		return
	}

	var empty []string
	for _, v := range php {
		// "Пустая": сайтов на этой версии нет, пулов нет, master крутится без работы.
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

// handlerLabel — короткий человеческий ярлык для константы из panel.Handler*.
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
