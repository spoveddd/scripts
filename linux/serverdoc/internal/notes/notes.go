// Package notes — фактологические наблюдения по снапшоту состояния.
// Не даёт советов — только корреляции, которые инженер интерпретирует сам.
// База для будущих рекомендаций (Фаза 4).
package notes

import (
	"fmt"

	"serverdoc/internal/panel"
	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

// Severity — уровень замечания. crit — сайты сломаны или сервер на грани.
type Severity string

const (
	SevCrit Severity = "crit"
	SevWarn Severity = "warn"
	SevInfo Severity = "info"
)

// Note — одно наблюдение.
type Note struct {
	Severity Severity `json:"severity"`
	Code     string   `json:"code"` // машинный ID для будущих YAML-правил
	Text     string   `json:"text"`
}

// Collect строит список замечаний по снапшоту.
func Collect(s sys.Info, sites []panel.Site, st stack.Stack) []Note {
	var out []Note

	out = append(out, phpFPMNotes(sites, st.PHP)...)
	out = append(out, resourceNotes(s)...)
	out = append(out, siteNotes(sites)...)

	return out
}

// phpFPMNotes — корреляция между сайтами на php_fpm и состоянием masters.
func phpFPMNotes(sites []panel.Site, php []stack.PHPVersion) []Note {
	var out []Note

	// Сколько активных сайтов использует каждую PHP-версию через php_fpm.
	fpmSitesByVer := map[string]int{}
	for _, s := range sites {
		if !s.Enabled || s.Handler != panel.HandlerPHPFPM || s.PHPVersion == "" {
			continue
		}
		fpmSitesByVer[s.PHPVersion]++
	}

	// Карта Stack.PHP → версия.
	stackByVer := map[string]stack.PHPVersion{}
	for _, p := range php {
		stackByVer[p.Version] = p
	}

	// CRIT: сайты на php_fpm есть, master не запущен → 502.
	for ver, n := range fpmSitesByVer {
		p, ok := stackByVer[ver]
		if !ok {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "php_version_missing",
				Text: fmt.Sprintf(
					"PHP %s используется %d сайтами через php-fpm, но не установлен на сервере",
					ver, n),
			})
			continue
		}
		if !p.MasterRunning {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "php_fpm_master_down",
				Text: fmt.Sprintf(
					"PHP %s: %d активных сайтов через php-fpm, но master не запущен — обращения вернут 502",
					ver, n),
			})
		}
	}

	// INFO: master запущен, но никем не используется (пулов нет и сайтов нет).
	for _, p := range php {
		if !p.MasterRunning {
			continue
		}
		if p.Pools > 0 || fpmSitesByVer[p.Version] > 0 {
			continue
		}
		out = append(out, Note{
			Severity: SevInfo,
			Code:     "php_fpm_master_idle",
			Text: fmt.Sprintf(
				"PHP %s: master запущен, но не обслуживает ни одного сайта",
				p.Version),
		})
	}

	// WARN: пулы есть, master не запущен (конфиги остались от выключенной версии).
	for _, p := range php {
		if p.MasterRunning || p.Pools == 0 {
			continue
		}
		out = append(out, Note{
			Severity: SevWarn,
			Code:     "php_fpm_pools_orphan",
			Text: fmt.Sprintf(
				"PHP %s: %d пулов в %s, master не запущен — конфиги без процесса",
				p.Version, p.Pools, p.PoolDir),
		})
	}

	return out
}

// resourceNotes — давление по памяти/swap/LA.
func resourceNotes(s sys.Info) []Note {
	var out []Note

	if s.MemTotalMB > 0 {
		availPct := 100 * s.MemAvailMB / s.MemTotalMB
		if availPct < 10 {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "ram_starved",
				Text: fmt.Sprintf(
					"Свободной RAM меньше 10%% (%d из %d MB) — риск OOM-килла процессов",
					s.MemAvailMB, s.MemTotalMB),
			})
		} else if availPct < 20 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "ram_tight",
				Text: fmt.Sprintf(
					"Свободной RAM около %d%% (%d из %d MB) — узкое место при пике",
					availPct, s.MemAvailMB, s.MemTotalMB),
			})
		}
	}

	if s.SwapTotalMB > 0 {
		swapUsedPct := 100 * (s.SwapTotalMB - s.SwapFreeMB) / s.SwapTotalMB
		if swapUsedPct >= 50 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "swap_heavy",
				Text: fmt.Sprintf(
					"Swap занят на %d%% (%d из %d MB) — система давно живёт в дефиците RAM",
					swapUsedPct, s.SwapTotalMB-s.SwapFreeMB, s.SwapTotalMB),
			})
		} else if swapUsedPct >= 20 {
			out = append(out, Note{
				Severity: SevInfo,
				Code:     "swap_active",
				Text: fmt.Sprintf(
					"Swap используется на %d%% (%d из %d MB)",
					swapUsedPct, s.SwapTotalMB-s.SwapFreeMB, s.SwapTotalMB),
			})
		}
	}

	if la := parseLoad(s.Load1); la > 0 && s.CPUCount > 0 {
		ratio := la / float64(s.CPUCount)
		if ratio >= 2.0 {
			out = append(out, Note{
				Severity: SevCrit,
				Code:     "la_overload",
				Text: fmt.Sprintf(
					"LA %s при %d ядрах (отношение %.1f×CPU) — сервер перегружен",
					s.Load1, s.CPUCount, ratio),
			})
		} else if ratio >= 1.0 {
			out = append(out, Note{
				Severity: SevWarn,
				Code:     "la_high",
				Text: fmt.Sprintf(
					"LA %s при %d ядрах (отношение %.1f×CPU) — все ядра под нагрузкой",
					s.Load1, s.CPUCount, ratio),
			})
		}
	}

	return out
}

// siteNotes — простые наблюдения по составу сайтов.
func siteNotes(sites []panel.Site) []Note {
	var out []Note

	disabled := 0
	for _, s := range sites {
		if !s.Enabled {
			disabled++
		}
	}
	if disabled > 0 && len(sites) > 0 {
		pct := 100 * disabled / len(sites)
		if pct >= 30 {
			out = append(out, Note{
				Severity: SevInfo,
				Code:     "many_disabled_sites",
				Text: fmt.Sprintf(
					"%d из %d сайтов (%d%%) выключены — можно проверить, не остались ли от ушедших клиентов",
					disabled, len(sites), pct),
			})
		}
	}

	return out
}

// parseLoad — превращает "1.19" в 1.19, "-" в 0.
func parseLoad(s string) float64 {
	var f float64
	_, err := fmt.Sscanf(s, "%f", &f)
	if err != nil {
		return 0
	}
	return f
}
