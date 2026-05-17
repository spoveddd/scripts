// Команда serverdoc — диагностический инструмент для серверов хостинга
// с панелями управления (ISPmanager, FastPanel, HestiaCP).
package main

import (
	"flag"
	"fmt"
	"os"

	"serverdoc/internal/diag"
	"serverdoc/internal/notes"
	"serverdoc/internal/panel"
	"serverdoc/internal/report"
	"serverdoc/internal/stack"
	"serverdoc/internal/sys"
)

// version задаётся при сборке через -ldflags "-X main.version=...".
var version = "dev"

func main() {
	asJSON := flag.Bool("json", false, "вывод в формате JSON")
	noColor := flag.Bool("no-color", false, "отключить цветной вывод")
	showVer := flag.Bool("version", false, "показать версию и выйти")
	flag.Parse()

	if *showVer {
		fmt.Println("serverdoc", version)
		return
	}

	report.Version = version
	info := sys.Collect()
	pk := panel.Detect()
	sites, warn, err := panel.ListSites(pk)
	if err != nil && warn == "" {
		warn = "не удалось получить список сайтов: " + err.Error()
	}
	st := stack.Collect()
	d := diag.Collect(st, pk, sites)

	rep := report.Report{
		Sys:      info,
		Panel:    string(pk),
		Sites:    sites,
		SiteWarn: warn,
		Stack:    st,
		Diag:     d,
		Notes:    notes.Collect(info, sites, st, d),
	}

	if *asJSON {
		rep.JSON(os.Stdout)
		return
	}
	rep.Text(os.Stdout, !*noColor && isTerminal(os.Stdout))
}

// isTerminal сообщает, является ли вывод терминалом (для цветов).
func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}
