package diag

import (
	"os"
	"sort"
	"strconv"
	"strings"
)

// ProcsState — общие аномалии в процессах.
type ProcsState struct {
	Total      int        `json:"total"`
	DState     int        `json:"d_state"` // uninterruptible I/O — обычно дисковые тормоза
	Zombie     int        `json:"zombie"`
	TopByRSS   []TopProc  `json:"top_by_rss,omitempty"`
	DStateProcs []TopProc `json:"d_state_procs,omitempty"` // первые несколько висящих в D
}

// TopProc — описание одного процесса для топа.
type TopProc struct {
	PID     int    `json:"pid"`
	Name    string `json:"name"`
	RSSMB   int    `json:"rss_mb"`
	State   string `json:"state,omitempty"`
	Cmdline string `json:"cmdline,omitempty"`
}

func analyzeProcs() *ProcsState {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	st := &ProcsState{}
	all := make([]TopProc, 0, 256)

	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		p, ok := readProcStatus(pid)
		if !ok {
			continue
		}
		st.Total++
		switch p.State {
		case "D":
			st.DState++
			if len(st.DStateProcs) < 5 {
				p.Cmdline = readCmdlineShort(pid)
				st.DStateProcs = append(st.DStateProcs, p)
			}
		case "Z":
			st.Zombie++
		}
		all = append(all, p)
	}

	// Топ-5 по RSS, для отчёта.
	sort.Slice(all, func(i, j int) bool { return all[i].RSSMB > all[j].RSSMB })
	if len(all) > 5 {
		all = all[:5]
	}
	for i := range all {
		all[i].Cmdline = readCmdlineShort(all[i].PID)
	}
	st.TopByRSS = all
	return st
}

// readProcStatus достаёт Name/State/VmRSS из /proc/<pid>/status.
func readProcStatus(pid int) (TopProc, bool) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return TopProc{}, false
	}
	p := TopProc{PID: pid}
	for _, ln := range strings.Split(string(b), "\n") {
		switch {
		case strings.HasPrefix(ln, "Name:"):
			p.Name = strings.TrimSpace(strings.TrimPrefix(ln, "Name:"))
		case strings.HasPrefix(ln, "State:"):
			// "State:  S (sleeping)" → "S"
			s := strings.TrimSpace(strings.TrimPrefix(ln, "State:"))
			if len(s) > 0 {
				p.State = string(s[0])
			}
		case strings.HasPrefix(ln, "VmRSS:"):
			fields := strings.Fields(strings.TrimPrefix(ln, "VmRSS:"))
			if len(fields) > 0 {
				kb, _ := strconv.Atoi(fields[0])
				p.RSSMB = kb / 1024
			}
		}
	}
	return p, true
}

func readCmdlineShort(pid int) string {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
	if err != nil {
		return ""
	}
	cl := strings.ReplaceAll(string(b), "\x00", " ")
	cl = strings.TrimSpace(cl)
	if len(cl) > 100 {
		cl = cl[:97] + "..."
	}
	return cl
}
