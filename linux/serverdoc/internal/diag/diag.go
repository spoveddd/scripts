// Package diag — динамическая диагностика: живое состояние Apache/PHP-FPM/MySQL,
// аномалии процессов, нагрузка по логам, error-логи бэкенд-сервисов, OOM.
package diag

import (
	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
)

// Report — общий снимок динамики.
type Report struct {
	Apache         *ApacheState       `json:"apache,omitempty"`
	Nginx          *NginxState        `json:"nginx,omitempty"`
	FPM            []FPMState         `json:"fpm,omitempty"`
	MySQL          *MySQLState        `json:"mysql,omitempty"`
	MySQLInstances []MySQLInstance    `json:"mysql_instances,omitempty"`
	Procs          *ProcsState        `json:"procs,omitempty"`
	Logs           *LogsState         `json:"logs,omitempty"`
	NginxLog       *ServiceLogState   `json:"nginx_log,omitempty"`
	MySQLLog       *ServiceLogState   `json:"mysql_log,omitempty"`
	OOM            *OOMState          `json:"oom,omitempty"`
	Memory         *MemoryBudget      `json:"memory,omitempty"`
	Outbound       *OutboundState     `json:"outbound,omitempty"`
	Stuck          *StuckWorkersState `json:"stuck,omitempty"`
}

// NginxState — конфигурация nginx.
type NginxState struct {
	Config NginxConfig `json:"config"`
}

// MemoryBudget — арифметика памяти: фактическое потребление сейчас
// плюс прогноз при упоре всех воркеров в лимиты.
type MemoryBudget struct {
	TotalMB             int `json:"total_mb"`
	// Сейчас (из meminfo).
	UsedNowMB           int `json:"used_now_mb"`
	AvailNowMB          int `json:"avail_now_mb"`
	SwapTotalMB         int `json:"swap_total_mb,omitempty"`
	SwapUsedMB          int `json:"swap_used_mb,omitempty"`
	// Прогноз при упоре в лимиты.
	ApacheMaxMB         int `json:"apache_max_mb"`
	FPMMaxMB            int `json:"fpm_max_mb"`
	MySQLBufferMB       int `json:"mysql_buffer_mb"`
	SystemBaseMB        int `json:"system_base_mb"`
	CommitMB            int `json:"commit_mb"`
	UtilizationPercent  int `json:"utilization_percent"`
	NowUtilizationPct   int `json:"now_utilization_percent"`
}

// Options — флаги поведения diag.Collect.
type Options struct {
	Quick bool // пропустить ресурсоёмкое (sampling зависших ~3с)
}

// Collect собирает полный снимок динамики.
func Collect(s stack.Stack, sysInfo SysAccess, pk panel.Kind, sites []panel.Site, opts Options) Report {
	r := Report{
		Apache:         analyzeApache(s.Apache),
		FPM:            analyzeFPM(s.PHP),
		MySQL:          analyzeMySQL(s.MySQL),
		MySQLInstances: findMySQLInstances(),
		Procs:          analyzeProcs(),
		Logs:           analyzeLogs(pk, sites),
		OOM:            analyzeOOM(),
		Outbound:       analyzeOutbound(),
	}
	if s.Nginx != nil {
		r.NginxLog = analyzeNginxLog()
		r.Nginx = &NginxState{Config: scanNginxConfig()}
	}
	if s.MySQL != nil {
		r.MySQLLog = analyzeMySQLLog()
	}
	r.Memory = buildMemoryBudget(sysInfo, r.Apache, r.FPM, r.MySQL)

	if opts.Quick {
		r.Stuck = &StuckWorkersState{Skipped: true}
	} else {
		r.Stuck = analyzeStuck(realPools(r.FPM), siteNameSet(sites), sites)
	}
	return r
}

// siteNameSet — множество доменов с панели. Нужно чтобы отличать клиентские
// пулы php-fpm (имя совпадает с доменом) от служебных (www-data, www, apps),
// у которых имя совпадает с системным юзером, а не сайтом.
func siteNameSet(sites []panel.Site) map[string]bool {
	res := map[string]bool{}
	for _, s := range sites {
		res[s.Name] = true
	}
	return res
}

// realPools — карта version → set of реальных pool names (исключает www.conf
// и подобные служебные). Используется в stuck detector чтобы игнорировать
// worker'ов системных пулов которые не обслуживают сайты.
func realPools(fpm []FPMState) map[string]map[string]bool {
	res := map[string]map[string]bool{}
	for _, v := range fpm {
		set := map[string]bool{}
		for _, p := range v.Pools {
			set[p.Name] = true
		}
		res[v.Version] = set
	}
	return res
}

// SysAccess — минимум что нужно diag из sys.Info (без импорта sys —
// иначе циклическая зависимость в будущем).
type SysAccess struct {
	MemTotalMB  int
	MemAvailMB  int
	SwapTotalMB int
	SwapFreeMB  int
}

// buildMemoryBudget собирает картину памяти: сейчас + прогноз.
func buildMemoryBudget(s SysAccess, a *ApacheState, fpm []FPMState, m *MySQLState) *MemoryBudget {
	if s.MemTotalMB == 0 {
		return nil
	}
	b := &MemoryBudget{
		TotalMB:    s.MemTotalMB,
		UsedNowMB:  s.MemTotalMB - s.MemAvailMB,
		AvailNowMB: s.MemAvailMB,
	}
	if s.SwapTotalMB > 0 {
		b.SwapTotalMB = s.SwapTotalMB
		b.SwapUsedMB = s.SwapTotalMB - s.SwapFreeMB
	}
	b.NowUtilizationPct = 100 * b.UsedNowMB / s.MemTotalMB

	if a != nil {
		b.ApacheMaxMB = a.ProjectedRAMMB
	}
	for _, f := range fpm {
		b.FPMMaxMB += f.ProjectedRAMMB
	}
	if m != nil {
		b.MySQLBufferMB = m.Config.InnodbBufferPoolMB + m.Config.KeyBufferMB + m.Config.QueryCacheMB
	}
	b.SystemBaseMB = s.MemTotalMB * 5 / 100
	if b.SystemBaseMB < 150 {
		b.SystemBaseMB = 150
	}
	if b.SystemBaseMB > 500 {
		b.SystemBaseMB = 500
	}

	b.CommitMB = b.ApacheMaxMB + b.FPMMaxMB + b.MySQLBufferMB + b.SystemBaseMB
	b.UtilizationPercent = 100 * b.CommitMB / s.MemTotalMB
	return b
}
