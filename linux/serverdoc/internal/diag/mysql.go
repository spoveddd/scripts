package diag

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

// MySQLState — живое состояние MySQL/MariaDB.
type MySQLState struct {
	AccessOK           bool           `json:"access_ok"`
	AccessError        string         `json:"access_error,omitempty"`
	MaxConnections     int            `json:"max_connections,omitempty"`
	ThreadsConnected   int            `json:"threads_connected,omitempty"`
	ThreadsRunning     int            `json:"threads_running,omitempty"`
	UtilizationPercent int            `json:"utilization_percent,omitempty"`
	QueriesByState     map[string]int `json:"queries_by_state,omitempty"`
	LongRunning        []MySQLQuery   `json:"long_running,omitempty"` // > 30 секунд
	LongRunningCount   int            `json:"long_running_count,omitempty"`
	Config             MySQLConfig    `json:"config,omitempty"`
}

// MySQLConfig — критичные глобальные переменные.
type MySQLConfig struct {
	InnodbBufferPoolMB int     `json:"innodb_buffer_pool_mb,omitempty"`
	InnodbLogFileMB    int     `json:"innodb_log_file_mb,omitempty"`
	KeyBufferMB        int     `json:"key_buffer_mb,omitempty"`
	QueryCacheMB       int     `json:"query_cache_mb,omitempty"`
	TmpTableMB         int     `json:"tmp_table_mb,omitempty"`
	MaxHeapTableMB     int     `json:"max_heap_table_mb,omitempty"`
	MaxAllowedPacketMB int     `json:"max_allowed_packet_mb,omitempty"`
	WaitTimeout        int     `json:"wait_timeout,omitempty"`
	InteractiveTimeout int     `json:"interactive_timeout,omitempty"`
	TableOpenCache     int     `json:"table_open_cache,omitempty"`
	SlowQueryLog       string  `json:"slow_query_log,omitempty"` // "ON"/"OFF"
	SlowQueryLogFile   string  `json:"slow_query_log_file,omitempty"`
	LongQueryTime      float64 `json:"long_query_time,omitempty"`
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

	// Проверяем доступность через простой SELECT 1.
	// Пробуем три варианта по очереди (без аргументов → socket-auth root;
	// потом известные .my.cnf файлы) — для надёжности на разных дистрибутивах.
	if err := mysqlProbe(); err != nil {
		st.AccessOK = false
		st.AccessError = compactErr(err.Error())
		return st
	}
	st.AccessOK = true

	if v, ok := mysqlVarInt("max_connections"); ok {
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

	st.Config = readMySQLConfig()

	if rows, err := mysqlQuery("SHOW FULL PROCESSLIST"); err == nil {
		queries := parseProcesslist(rows)
		st.QueriesByState = countQueriesByState(queries)
		for _, q := range queries {
			if q.TimeSec < 30 || q.Command == "Sleep" {
				continue
			}
			// Системные потоки висят вечно по дизайну — не считаем их runaway.
			if isSystemMySQLUser(q.User) {
				continue
			}
			st.LongRunningCount++
			if len(st.LongRunning) < 10 {
				st.LongRunning = append(st.LongRunning, q)
			}
		}
		sort.SliceStable(st.LongRunning, func(i, j int) bool {
			return st.LongRunning[i].TimeSec > st.LongRunning[j].TimeSec
		})
	}

	return st
}

// readMySQLConfig читает критичные глобальные переменные через один SHOW.
func readMySQLConfig() MySQLConfig {
	var cfg MySQLConfig

	intFromBytes := func(varname string) int {
		v, ok := mysqlVarInt(varname)
		if !ok {
			return 0
		}
		return v / (1024 * 1024)
	}

	cfg.InnodbBufferPoolMB = intFromBytes("innodb_buffer_pool_size")
	cfg.InnodbLogFileMB = intFromBytes("innodb_log_file_size")
	cfg.KeyBufferMB = intFromBytes("key_buffer_size")
	cfg.QueryCacheMB = intFromBytes("query_cache_size")
	cfg.TmpTableMB = intFromBytes("tmp_table_size")
	cfg.MaxHeapTableMB = intFromBytes("max_heap_table_size")
	cfg.MaxAllowedPacketMB = intFromBytes("max_allowed_packet")

	if v, ok := mysqlVarInt("wait_timeout"); ok {
		cfg.WaitTimeout = v
	}
	if v, ok := mysqlVarInt("interactive_timeout"); ok {
		cfg.InteractiveTimeout = v
	}
	if v, ok := mysqlVarInt("table_open_cache"); ok {
		cfg.TableOpenCache = v
	}
	if s, ok := mysqlVarStr("slow_query_log"); ok {
		cfg.SlowQueryLog = strings.ToUpper(s)
	}
	if s, ok := mysqlVarStr("slow_query_log_file"); ok {
		cfg.SlowQueryLogFile = s
	}
	if s, ok := mysqlVarStr("long_query_time"); ok {
		var f float64
		fmtScan(s, &f)
		cfg.LongQueryTime = f
	}
	return cfg
}

// fmtScan — упрощённый Sscanf для float (стандартный Sscanf "%f" работает).
func fmtScan(s string, f *float64) {
	_, _ = fmt.Sscanf(s, "%f", f)
}

func mysqlVarStr(varname string) (string, bool) {
	out, err := mysqlQuery("SHOW GLOBAL VARIABLES LIKE '" + varname + "'")
	if err != nil {
		return "", false
	}
	for _, ln := range strings.Split(strings.TrimSpace(out), "\n") {
		fields := strings.Fields(ln)
		if len(fields) < 2 {
			continue
		}
		if !strings.EqualFold(fields[0], varname) {
			continue
		}
		return fields[len(fields)-1], true
	}
	return "", false
}

// mysqlClientArgs — какие аргументы передавать mysql клиенту.
// По умолчанию пусто (socket-auth от root). Если нашли работающий
// --defaults-extra-file — используем его на все последующие команды.
var mysqlClientArgs []string

// mysqlProbe пытается подключиться разными способами. Сохраняет рабочие
// аргументы в mysqlClientArgs чтобы все последующие SHOW использовали их.
func mysqlProbe() error {
	candidates := [][]string{
		nil, // как есть, socket-auth для root
		{"--defaults-extra-file=/root/.my.cnf"},
		{"--defaults-file=/root/.my.cnf"},
		{"--login-path=client"},
	}
	var lastErr error
	for _, args := range candidates {
		// Проверяем существование файла для file-варианта.
		if len(args) > 0 && strings.Contains(args[0], "=/") {
			path := args[0][strings.Index(args[0], "=")+1:]
			if _, err := os.Stat(path); err != nil {
				continue
			}
		}
		mysqlClientArgs = args
		_, err := mysqlQuery("SELECT 1")
		if err == nil {
			return nil
		}
		lastErr = err
	}
	mysqlClientArgs = nil
	return lastErr
}

func mysqlQuery(sql string) (string, error) {
	args := append([]string{}, mysqlClientArgs...)
	args = append(args, "-BN", "-e", sql)
	out, err := sys.Run(5*time.Second, "mysql", args...)
	if err != nil {
		// out обычно содержит реальное сообщение mysql client'а
		// ("ERROR 1045: Access denied", "ERROR 2002: Can't connect to socket" и т.п.)
		// — пробрасываем вместо безликого "exit status 1".
		msg := strings.TrimSpace(out)
		if msg == "" {
			return out, err
		}
		return out, fmt.Errorf("%s", msg)
	}
	return out, nil
}

func mysqlStatusInt(varname string) (int, bool) {
	return mysqlShowInt("STATUS", varname)
}

func mysqlVarInt(varname string) (int, bool) {
	return mysqlShowInt("VARIABLES", varname)
}

// mysqlShowInt — общий путь для SHOW GLOBAL {STATUS|VARIABLES} LIKE 'X'.
// Возвращает целое из последней колонки последней строки.
func mysqlShowInt(kind, varname string) (int, bool) {
	out, err := mysqlQuery("SHOW GLOBAL " + kind + " LIKE '" + varname + "'")
	if err != nil {
		return 0, false
	}
	// Берём именно строку с искомым именем, чтобы не наткнуться на warning-строки.
	for _, ln := range strings.Split(strings.TrimSpace(out), "\n") {
		fields := strings.Fields(ln)
		if len(fields) < 2 {
			continue
		}
		if !strings.EqualFold(fields[0], varname) {
			continue
		}
		v, err := strconv.Atoi(fields[len(fields)-1])
		return v, err == nil
	}
	return 0, false
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

// isSystemMySQLUser — внутренние пользователи MySQL/MariaDB, чьи "запросы"
// в processlist это вечные системные потоки (event scheduler, репликация и т.п.).
func isSystemMySQLUser(user string) bool {
	switch user {
	case "event_scheduler", "system user":
		return true
	}
	return false
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
