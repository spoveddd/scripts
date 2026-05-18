package diag

import (
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"serverdoc/internal/sys"
)

// OOMState — события OOM-killer за последние 7 дней.
type OOMState struct {
	Source       string         `json:"source"`             // путь к файлу или "dmesg"
	EventCount   int            `json:"event_count"`        // за 7 дней
	ByProcess    map[string]int `json:"by_process,omitempty"` // сколько раз убит каждый процесс
	RecentEvents []OOMEvent     `json:"recent_events,omitempty"`
	Note         string         `json:"note,omitempty"`
}

// OOMEvent — одно событие OOM-killer.
type OOMEvent struct {
	Time     string `json:"time,omitempty"`
	Process  string `json:"process"`
	PID      int    `json:"pid,omitempty"`
	AnonRSSKB int   `json:"anon_rss_kb,omitempty"`
	TotalVMKB int   `json:"total_vm_kb,omitempty"`
	Raw      string `json:"raw,omitempty"` // исходная строка для копи-паста
}

const oomMaxAge = 7 * 24 * time.Hour

// analyzeOOM ищет события OOM-killer в системных логах.
func analyzeOOM() *OOMState {
	// Предпочитаем именно syslog-файлы — там есть timestamps.
	candidates := []string{
		"/var/log/kern.log",
		"/var/log/syslog",
		"/var/log/messages",
	}
	for _, p := range candidates {
		if fi, err := os.Stat(p); err != nil || fi.IsDir() || fi.Size() == 0 {
			continue
		}
		return scanOOMFile(p)
	}

	// Fallback на dmesg, если файлов нет (часто на минималистичных systemd).
	if sys.Have("dmesg") {
		out, err := sys.Run(5*time.Second, "dmesg", "-T")
		if err != nil {
			return &OOMState{Note: "OOM-логи недоступны (нет kern.log/syslog/messages, dmesg тоже)"}
		}
		return parseOOM("dmesg", []byte(out))
	}
	return &OOMState{Note: "системные логи недоступны, OOM-события не проверены"}
}

func scanOOMFile(path string) *OOMState {
	// Логи могут быть огромными — читаем последние 4 MB.
	data, err := readTail(path, 4*1024*1024)
	if err != nil {
		return &OOMState{Source: path, Note: "не удалось прочитать: " + err.Error()}
	}
	return parseOOM(path, data)
}

var (
	// Старый формат kernel: "Out of memory: Killed process 12345 (mysqld) total-vm:...kB, anon-rss:...kB"
	// Новый формат (cgroup v2): "Memory cgroup out of memory: Killed process 12345 (mysqld) total-vm:..."
	oomLineRe = regexp.MustCompile(
		`(?i)Killed process (\d+) \(([^)]+)\)(?:.*total-vm:(\d+)kB)?(?:.*anon-rss:(\d+)kB)?`)

	// syslog timestamp: "May 17 12:34:56" или "2026-05-17T12:34:56+03:00".
	syslogTimeRe = regexp.MustCompile(`^([A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2}|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})`)

	// dmesg -T timestamp: "[Sun May 17 12:34:56 2026]"
	dmesgTimeRe = regexp.MustCompile(`^\[([A-Z][a-z]{2} [A-Z][a-z]{2} \s?\d+ \d{2}:\d{2}:\d{2} \d{4})\]`)
)

func parseOOM(source string, data []byte) *OOMState {
	st := &OOMState{Source: source, ByProcess: map[string]int{}}
	cutoff := time.Now().Add(-oomMaxAge)
	now := time.Now()

	for _, ln := range strings.Split(string(data), "\n") {
		if !strings.Contains(ln, "Killed process") &&
			!strings.Contains(ln, "Out of memory") &&
			!strings.Contains(ln, "oom-kill") {
			continue
		}
		m := oomLineRe.FindStringSubmatch(ln)
		if m == nil {
			continue
		}
		ts := parseOOMTime(ln, now)
		if !ts.IsZero() && ts.Before(cutoff) {
			continue
		}
		pid, _ := strconv.Atoi(m[1])
		totalVM, _ := strconv.Atoi(m[3])
		anonRSS, _ := strconv.Atoi(m[4])
		ev := OOMEvent{
			Process:   m[2],
			PID:       pid,
			TotalVMKB: totalVM,
			AnonRSSKB: anonRSS,
			Raw:       compactLine(ln),
		}
		if !ts.IsZero() {
			ev.Time = ts.Format("2006-01-02 15:04:05")
		}
		st.RecentEvents = append(st.RecentEvents, ev)
		st.ByProcess[m[2]]++
		st.EventCount++
	}
	// Ограничим вывод последними 10 — но ByProcess уже содержит ВСЕ события.
	if len(st.RecentEvents) > 10 {
		st.RecentEvents = st.RecentEvents[len(st.RecentEvents)-10:]
	}
	return st
}

func parseOOMTime(ln string, now time.Time) time.Time {
	if m := dmesgTimeRe.FindStringSubmatch(ln); m != nil {
		for _, layout := range []string{
			"Mon Jan 2 15:04:05 2006",
			"Mon Jan  2 15:04:05 2006",
		} {
			if t, err := time.Parse(layout, m[1]); err == nil {
				return t
			}
		}
	}
	if m := syslogTimeRe.FindStringSubmatch(ln); m != nil {
		// ISO-формат с годом.
		if t, err := time.Parse(time.RFC3339, m[1]); err == nil {
			return t
		}
		// "May 17 12:34:56" — без года, подставляем текущий, учитывая
		// что событие в будущем не может быть.
		if t, err := time.ParseInLocation("Jan 2 15:04:05", m[1], time.Local); err == nil {
			t = t.AddDate(now.Year(), 0, 0)
			if t.After(now) {
				t = t.AddDate(-1, 0, 0)
			}
			return t
		}
	}
	return time.Time{}
}

func compactLine(ln string) string {
	ln = strings.TrimSpace(ln)
	if len(ln) > 200 {
		ln = ln[:197] + "..."
	}
	return ln
}
