package diag

import (
	"os"
	"path/filepath"
	"regexp"
	"time"
)

func analyzeMySQLLog() *ServiceLogState {
	path := findMySQLErrorLog()
	if path == "" {
		return &ServiceLogState{Note: "MySQL error.log не найден"}
	}
	return scanServiceLog(path, 24*time.Hour, mysqlPatterns, parseMySQLTimestamp)
}

// findMySQLErrorLog ищет error log MySQL/MariaDB в стандартных местах.
func findMySQLErrorLog() string {
	candidates := []string{
		"/var/log/mysql/error.log",
		"/var/log/mysql/mysql.err",
		"/var/log/mariadb/mariadb.log",
		"/var/log/mysqld.log",
		"/var/log/mariadb/mariadb.err",
	}
	for _, p := range candidates {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Size() > 0 {
			return p
		}
	}
	// Часто MySQL пишет в /var/lib/mysql/<hostname>.err.
	if matches, _ := filepath.Glob("/var/lib/mysql/*.err"); len(matches) > 0 {
		// Берём свежайший.
		newest := matches[0]
		newestMTime := time.Time{}
		for _, p := range matches {
			fi, err := os.Stat(p)
			if err != nil {
				continue
			}
			if fi.ModTime().After(newestMTime) {
				newestMTime = fi.ModTime()
				newest = p
			}
		}
		return newest
	}
	return ""
}

// mysqlPatterns — критические сообщения MySQL/MariaDB error log.
var mysqlPatterns = []logPattern{
	{
		code: "mysql_too_many_connections", severity: "crit",
		description: "Too many connections — упор в max_connections, клиенты не могут подключиться",
		re:          regexp.MustCompile(`Too many connections|max_connections.*exceeded`),
	},
	{
		code: "mysql_oom", severity: "crit",
		description: "InnoDB не смог выделить память — нехватка RAM",
		re:          regexp.MustCompile(`InnoDB: Cannot allocate memory|mmap.*failed|Out of memory`),
	},
	{
		code: "mysql_crash", severity: "crit",
		description: "MySQL/MariaDB упал и был перезапущен (mysqld got signal)",
		re:          regexp.MustCompile(`mysqld got signal|mysqld restarted|InnoDB: Database was not shutdown normally`),
	},
	{
		code: "mysql_table_full", severity: "crit",
		description: "Таблица заполнена — упор в лимит размера (tmp или ENGINE)",
		re:          regexp.MustCompile(`table .* is full|The table .* is full`),
	},
	{
		code: "mysql_deadlock", severity: "warn",
		description: "Deadlock между транзакциями — одна откатилась",
		re:          regexp.MustCompile(`Deadlock found|deadlock detected`),
	},
	{
		code: "mysql_lock_wait_timeout", severity: "warn",
		description: "Lock wait timeout — запросы ждут блокировок дольше innodb_lock_wait_timeout",
		re:          regexp.MustCompile(`Lock wait timeout exceeded`),
	},
	{
		code: "mysql_aborted_connection", severity: "info",
		description: "Aborted connection — клиент оборвал соединение (часто из-за wait_timeout)",
		re:          regexp.MustCompile(`Aborted connection|Got an error reading communication packet`),
	},
	{
		code: "mysql_slow_shutdown", severity: "info",
		description: "Длительное завершение работы — InnoDB сбрасывает буфер",
		re:          regexp.MustCompile(`Waiting for purge|InnoDB: Waiting`),
	},
}

// MySQL timestamp форматы:
//   "2026-05-17T12:34:56.123456Z" (mysqld 8.x, UTC)
//   "2026-05-17 12:34:56" (mariadb)
//   "260517 12:34:56" (старый формат)
var (
	mysqlTimeISORe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})`)
	mysqlTimeRe    = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})`)
	mysqlTimeOldRe = regexp.MustCompile(`^(\d{6} \d{1,2}:\d{2}:\d{2})`)
)

func parseMySQLTimestamp(ln string) time.Time {
	if m := mysqlTimeISORe.FindStringSubmatch(ln); m != nil {
		if t, err := time.Parse("2006-01-02T15:04:05", m[1]); err == nil {
			return t
		}
	}
	if m := mysqlTimeRe.FindStringSubmatch(ln); m != nil {
		if t, err := time.ParseInLocation("2006-01-02 15:04:05", m[1], time.Local); err == nil {
			return t
		}
	}
	if m := mysqlTimeOldRe.FindStringSubmatch(ln); m != nil {
		if t, err := time.ParseInLocation("060102 15:04:05", m[1], time.Local); err == nil {
			return t
		}
	}
	return time.Time{}
}
