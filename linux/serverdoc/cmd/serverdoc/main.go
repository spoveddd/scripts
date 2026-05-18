// Команда serverdoc — диагностический инструмент для серверов хостинга
// с панелями управления (ISPmanager, FastPanel, HestiaCP).
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"

	"serverdoc/internal/collect"
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
	asJSON := flag.Bool("json", false, "вывод в формате JSON (для скриптов и парсинга)")
	noColor := flag.Bool("no-color", false, "отключить ANSI-цвета (для записи в файл)")
	quick := flag.Bool("quick", false, "пропустить sampling зависших воркеров (быстрее на ~3с)")
	collectDump := flag.Bool("collect", false, "собрать диагностический dump /tmp/serverdoc-dump-*.md")
	showVer := flag.Bool("version", false, "показать версию и выйти")
	flag.Usage = printUsage
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
	d := diag.Collect(st, diag.SysAccess{MemTotalMB: info.MemTotalMB}, pk, sites, diag.Options{Quick: *quick})

	rep := report.Report{
		Sys:      info,
		Panel:    string(pk),
		Sites:    sites,
		SiteWarn: warn,
		Stack:    st,
		Diag:     d,
		Notes:    notes.Collect(info, sites, st, d),
	}

	if *collectDump {
		var buf bytes.Buffer
		rep.JSON(&buf)
		path, err := collect.Dump(buf.Bytes())
		if err != nil {
			fmt.Fprintln(os.Stderr, "не удалось создать dump:", err)
			os.Exit(1)
		}
		fmt.Println("Dump создан:", path)
		fmt.Println("")
		fmt.Println("ВНИМАНИЕ: содержит хвосты логов и список процессов —")
		fmt.Println("проверьте на наличие чувствительной информации перед отправкой.")
		fmt.Println("")
		fmt.Println("Удобные способы переслать:")
		fmt.Println("  • прислать сам файл .md")
		fmt.Println("  • cat", path, "| nc termbin.com 9999")
		fmt.Println("  • залить на gist:  gh gist create --secret --filename dump.md", path)
		return
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

func printUsage() {
	fmt.Fprintf(os.Stderr, `serverdoc — диагностика серверов с панелями ISPmanager/FastPanel/HestiaCP.

Запускать от root: для доступа к CLI панелей, /proc других процессов и MySQL
через socket-auth.

Использование:
  serverdoc                  — полный отчёт (с sampling зависших воркеров, ~3с)
  serverdoc --quick          — быстрый отчёт без sampling
  serverdoc --json           — машинный формат для скриптов
  serverdoc --no-color       — без ANSI-цветов (для записи в файл)
  serverdoc --collect        — собрать диагностический dump.md (для разработчика)
  serverdoc --version        — версия и выход

Примеры:
  serverdoc                          # стандартный запуск
  serverdoc --json > report.json     # сохранить структурный отчёт
  serverdoc --no-color > report.txt  # сохранить текстовый отчёт
  serverdoc --quick                  # когда нужно быстро без 3-сек паузы
  serverdoc --collect                # создать /tmp/serverdoc-dump-*.md
                                     # для отправки разработчику (beta)

Документация и issues: https://github.com/spoveddd/scripts/tree/main/linux/serverdoc
`)
}
