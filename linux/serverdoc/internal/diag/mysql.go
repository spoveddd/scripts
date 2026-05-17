package diag

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

// MySQLState — живое состояние MySQL/MariaDB.
type MySQLState struct {
	AccessOK           bool         `json:"access_ok"`
	AccessError        string       `json:"access_error,omitempty"`
	MaxConnections     int          `json:"max_connections,omitempty"`
	ThreadsConnected   int          `json:"threads_connected,omitempty"`
	ThreadsRunning     int          `json:"threads_running,omitempty"`
	UtilizationPercent int          `json:"utilization_percent,omitempty"`
	QueriesByState     map[string]int `json:"queries_by_state,omitempty"`
	LongRunning        []MySQLQuery `json:"long_running,omitempty"` // > 30 секунд
	LongRunningCount   int          `json:"long_running_count,omitempty"`
}

// MySQLQuery — один запрос из SHOW PROCESSLIST.
type MySQLQuery struct {
	ID       int    `json:"id"`
	User     string `json:"user"`
	Host     string `json:"host"`
	DB       string `json:"db"`
	Command  string `json:"command"`
	TimeSec  int    `json:"time_sec"`
	State    string `json:"state"`
	InfoHead string `json:"info_head,omitempty"`
}

func analyzeMySQL(m *stack.Service) *MySQLState {
	if m == nil || !m.Running {
		return nil
	}
	st := &MySQLState{}

	// Сначала проверяем доступность: простой SELECT 1 через socket auth.
	if _, err := mysqlQuery("SELECT 1"); err != nil {
		st.AccessOK = false
		st.AccessError = compactErr(err.Error())
		return st
	}
	st.AccessOK = true

	if v, ok := mysqlInt("SELECT @@max_connections"); ok {
		st.MaxConnections = v
	}
	if v, ok := mysqlStatusInt("Threads_connected"); ok {
		st.ThreadsConnected = v
	}
	if v, ok := mysqlStatusInt("Threads_running"); ok {
		st.ThreadsRunning = v
	}
	if st.MaxConnections > 0 {
		st.UtilizationPercent = 100 * st.ThreadsConnected / st.MaxConnections
	}

	if rows, err := mysqlQuery("SHOW FULL PROCESSLIST"); err == nil {
		queries := parseProcesslist(rows)
		st.QueriesByState = countQueriesByState(queries)
		for _, q := range queries {
			if q.TimeSec >= 30 && q.Command != "Sleep" {
				st.LongRunningCount++
				if len(st.LongRunning) < 10 {
					st.LongRunning = append(st.LongRunning, q)
				}
			}
		}
		sort.SliceStable(st.LongRunning, func(i, j int) bool {
			return st.LongRunning[i].TimeSec > st.LongRunning[j].TimeSec
		})
	}

	return st
}

func mysqlQuery(sql string) (string, error) {
	out, err := sys.Run(5*time.Second, "mysql", "-BN", "-e", sql)
	if err != nil {
		return out, err
	}
	return out, nil
}

func mysqlInt(sql string) (int, bool) {
	out, err := mysqlQuery(sql)
	if err != nil {
		return 0, false
	}
	v, err := strconv.Atoi(strings.TrimSpace(out))
	return v, err == nil
}

func mysqlStatusInt(varname string) (int, bool) {
	out, err := mysqlQuery("SHOW GLOBAL STATUS LIKE '" + varname + "'")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(strings.TrimSpace(out))
	if len(fields) < 2 {
		return 0, false
	}
	v, err := strconv.Atoi(fields[len(fields)-1])
	return v, err == nil
}

// parseProcesslist разбирает вывод `mysql -BN -e "SHOW FULL PROCESSLIST"`.
// Колонки: Id  User  Host  db  Command  Time  State  Info — разделены табами.
func parseProcesslist(raw string) []MySQLQuery {
	var out []MySQLQuery
	for _, ln := range strings.Split(raw, "\n") {
		ln = strings.TrimRight(ln, "\r")
		if ln == "" {
			continue
		}
		f := strings.Split(ln, "\t")
		if len(f) < 8 {
			continue
		}
		id, _ := strconv.Atoi(f[0])
		t, _ := strconv.Atoi(f[5])
		q := MySQLQuery{
			ID:      id,
			User:    f[1],
			Host:    f[2],
			DB:      nullify(f[3]),
			Command: f[4],
			TimeSec: t,
			State:   nullify(f[6]),
		}
		info := nullify(f[7])
		if len(info) > 120 {
			info = info[:117] + "..."
		}
		q.InfoHead = info
		out = append(out, q)
	}
	return out
}

func countQueriesByState(qs []MySQLQuery) map[string]int {
	m := map[string]int{}
	for _, q := range qs {
		key := q.State
		if key == "" {
			key = q.Command
		}
		m[key]++
	}
	return m
}

func nullify(s string) string {
	if s == "NULL" {
		return ""
	}
	return s
}

// compactErr вырезает многострочные mysql-сообщения и оставляет первую строку.
func compactErr(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:197] + "..."
	}
	return strings.TrimSpace(s)
}
