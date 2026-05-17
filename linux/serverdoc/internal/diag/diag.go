// Package diag — динамическая диагностика: живое состояние Apache/PHP-FPM/MySQL,
// аномалии процессов, нагрузка по логам. В отличие от stack (инвентаризация),
// здесь смотрим что сейчас происходит, а не что установлено.
package diag

import (
	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
)

// Report — общий снимок динамики.
type Report struct {
	Apache *ApacheState `json:"apache,omitempty"`
	FPM    []FPMState   `json:"fpm,omitempty"`
	MySQL  *MySQLState  `json:"mysql,omitempty"`
	Procs  *ProcsState  `json:"procs,omitempty"`
	Logs   *LogsState   `json:"logs,omitempty"`
}

// Collect собирает полный снимок динамики.
// Принимает результаты stack и panel — чтобы переиспользовать уже полученное
// (версии PHP, путь к pool_dir, тип панели для лог-путей).
func Collect(s stack.Stack, pk panel.Kind, sites []panel.Site) Report {
	return Report{
		Apache: analyzeApache(s.Apache),
		FPM:    analyzeFPM(s.PHP),
		MySQL:  analyzeMySQL(s.MySQL),
		Procs:  analyzeProcs(),
		Logs:   analyzeLogs(pk, sites),
	}
}
