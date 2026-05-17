// Package diag — динамическая диагностика: живое состояние Apache/PHP-FPM/MySQL,
// аномалии процессов, нагрузка по логам, error-логи бэкенд-сервисов, OOM.
package diag

import (
	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
)

// Report — общий снимок динамики.
type Report struct {
	Apache    *ApacheState     `json:"apache,omitempty"`
	FPM       []FPMState       `json:"fpm,omitempty"`
	MySQL     *MySQLState      `json:"mysql,omitempty"`
	Procs     *ProcsState      `json:"procs,omitempty"`
	Logs      *LogsState       `json:"logs,omitempty"`
	NginxLog  *ServiceLogState `json:"nginx_log,omitempty"`
	MySQLLog  *ServiceLogState `json:"mysql_log,omitempty"`
	OOM       *OOMState        `json:"oom,omitempty"`
}

// Collect собирает полный снимок динамики.
func Collect(s stack.Stack, pk panel.Kind, sites []panel.Site) Report {
	r := Report{
		Apache: analyzeApache(s.Apache),
		FPM:    analyzeFPM(s.PHP),
		MySQL:  analyzeMySQL(s.MySQL),
		Procs:  analyzeProcs(),
		Logs:   analyzeLogs(pk, sites),
		OOM:    analyzeOOM(),
	}
	if s.Nginx != nil {
		r.NginxLog = analyzeNginxLog()
	}
	if s.MySQL != nil {
		r.MySQLLog = analyzeMySQLLog()
	}
	return r
}
