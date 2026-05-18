package diag

import (
	"os"
	"sort"
	"strconv"
	"strings"
)

// OutboundState — анализ исходящих TCP соединений у воркеров.
// Часто причина зависаний: PHP-скрипт ждёт ответа от внешнего API/SMTP,
// весь воркер висит вместе с ним.
type OutboundState struct {
	TotalEstablished int             `json:"total_established"`
	TotalSynSent     int             `json:"total_syn_sent"` // ожидание подключения — почти точно зависает
	TopProcesses     []OutboundByPID `json:"top_processes,omitempty"`
	TopRemotes       []OutboundRemote `json:"top_remotes,omitempty"`
}

// OutboundByPID — сводка по PID: куда и сколько коннектов держит.
type OutboundByPID struct {
	PID         int      `json:"pid"`
	ProcessName string   `json:"process_name"`
	CmdHead     string   `json:"cmd_head"`
	Established int      `json:"established"`
	SynSent     int      `json:"syn_sent,omitempty"`
	Remotes     []string `json:"remotes"` // "ip:port" формат
}

// OutboundRemote — сводка по удалённому endpoint: кто и сколько раз стучится.
type OutboundRemote struct {
	Endpoint string `json:"endpoint"` // "ip:port"
	Count    int    `json:"count"`
	PIDs     []int  `json:"pids"`
}

// analyzeOutbound строит сводку по исходящим TCP-соединениям.
// Учитываем только ESTABLISHED + SYN_SENT (висящие коннекты).
// LISTEN и localhost-соединения отфильтрованы.
func analyzeOutbound() *OutboundState {
	conns := readProcNetTCP()
	if len(conns) == 0 {
		return nil
	}
	locals := localIPs()

	// Inode → PID. Здесь добавляем nginx — он может держать proxy_pass коннекты,
	// плюс apache/php-fpm/php-cgi (но через isStuckCandidate — чтобы не ловить ihttpd).
	// Сам фильтр направления "исходящее vs входящее" применяется ниже через
	// well-known listening ports.
	pidByInode := buildInodeToPID(isWebOrPHPProcess)
	if len(pidByInode) == 0 {
		return nil
	}

	// Listening порты web-сервера — чтобы отличить входящих клиентов
	// (которых тут не должно быть) от исходящих коннектов.
	listenPorts := listeningPorts()

	st := &OutboundState{}
	byPID := map[int]*OutboundByPID{}
	byRemote := map[string]*OutboundRemote{}

	for _, c := range conns {
		if c.State != tcpEstablished && c.State != tcpSynSent {
			continue
		}
		// Это исходящий? Локальный IP — наш; remote — НЕ наш и не loopback.
		if isLoopback(c.RemoteIP) || locals[c.RemoteIP.String()] {
			continue
		}
		// Локальный порт совпадает с listening — это входящий клиент (accept-side),
		// не исходящий коннект. Игнорируем — у nginx таких сотни.
		if listenPorts[c.LocalPort] {
			continue
		}
		pid, ok := pidByInode[c.Inode]
		if !ok {
			continue
		}
		endpoint := c.RemoteIP.String() + ":" + itoa(c.RemotePort)

		if c.State == tcpEstablished {
			st.TotalEstablished++
		} else {
			st.TotalSynSent++
		}

		// Per-PID
		bp, exists := byPID[pid]
		if !exists {
			bp = &OutboundByPID{
				PID:         pid,
				ProcessName: procName(pid),
				CmdHead:     readCmdlineShort(pid),
			}
			byPID[pid] = bp
		}
		if c.State == tcpEstablished {
			bp.Established++
		} else {
			bp.SynSent++
		}
		if !contains(bp.Remotes, endpoint) {
			bp.Remotes = append(bp.Remotes, endpoint)
		}

		// Per-remote
		br, exists := byRemote[endpoint]
		if !exists {
			br = &OutboundRemote{Endpoint: endpoint}
			byRemote[endpoint] = br
		}
		br.Count++
		if !containsInt(br.PIDs, pid) {
			br.PIDs = append(br.PIDs, pid)
		}
	}

	// Топы.
	for _, v := range byPID {
		st.TopProcesses = append(st.TopProcesses, *v)
	}
	sort.SliceStable(st.TopProcesses, func(i, j int) bool {
		a := st.TopProcesses[i].Established + st.TopProcesses[i].SynSent*2 // SYN_SENT вес больше — это уже зависание
		b := st.TopProcesses[j].Established + st.TopProcesses[j].SynSent*2
		return a > b
	})
	if len(st.TopProcesses) > 10 {
		st.TopProcesses = st.TopProcesses[:10]
	}

	for _, v := range byRemote {
		st.TopRemotes = append(st.TopRemotes, *v)
	}
	sort.SliceStable(st.TopRemotes, func(i, j int) bool {
		return st.TopRemotes[i].Count > st.TopRemotes[j].Count
	})
	if len(st.TopRemotes) > 10 {
		st.TopRemotes = st.TopRemotes[:10]
	}

	return st
}

// isWebOrPHPProcess — расширенный фильтр для outbound: добавляет nginx
// к worker-процессам apache/php (которые покрывает isStuckCandidate).
// nginx может держать proxy_pass-коннекты к API/upstream, это важно увидеть.
// ihttpd/containerd-shim сюда не попадают — проверка по basename бинаря.
func isWebOrPHPProcess(cmdline string) bool {
	if cmdline == "" {
		return false
	}
	if isStuckCandidate(cmdline) {
		return true
	}
	fields := strings.Fields(cmdline)
	if len(fields) == 0 {
		return false
	}
	bin := fields[0]
	if idx := strings.LastIndex(bin, "/"); idx >= 0 {
		bin = bin[idx+1:]
	}
	return bin == "nginx"
}

// listeningPorts — все локальные порты в состоянии LISTEN. Используется
// чтобы отличить accept-side соединения (клиенты к нам) от connect-side
// (мы к внешнему миру).
func listeningPorts() map[int]bool {
	res := map[int]bool{}
	for _, c := range readProcNetTCP() {
		if c.State == tcpListen {
			res[c.LocalPort] = true
		}
	}
	return res
}

func procName(pid int) string {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/comm")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func itoa(i int) string {
	return strconv.Itoa(i)
}

func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

func containsInt(slice []int, s int) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}
