package diag

import (
	"os"
	"strconv"
	"strings"
)

// MySQLInstance — один процесс mysqld/mariadbd. Может быть нативным или в контейнере.
type MySQLInstance struct {
	PID         int    `json:"pid"`
	Name        string `json:"name"`         // mysqld / mariadbd
	RSSMB       int    `json:"rss_mb"`
	Containerized bool `json:"containerized"`
	CgroupHint  string `json:"cgroup_hint,omitempty"` // docker/containerd/kubepods если найдено
}

// findMySQLInstances ищет все запущенные mysqld/mariadbd процессы.
// Разделяет нативные и контейнерные через /proc/PID/cgroup.
// Helpful: на хостинговых серверах часто 2+ инстанса (system MySQL + Docker MariaDB),
// и top RAM их путает.
func findMySQLInstances() []MySQLInstance {
	var out []MySQLInstance
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		comm, err := os.ReadFile("/proc/" + e.Name() + "/comm")
		if err != nil {
			continue
		}
		name := strings.TrimSpace(string(comm))
		if name != "mysqld" && name != "mariadbd" {
			continue
		}
		inst := MySQLInstance{
			PID:   pid,
			Name:  name,
			RSSMB: procRSSMB(pid),
		}
		inst.Containerized, inst.CgroupHint = detectContainerCgroup(pid)
		out = append(out, inst)
	}
	return out
}

// detectContainerCgroup проверяет /proc/PID/cgroup на наличие маркеров контейнера.
// На современных системах с cgroup v2 строка имеет вид:
//
//	0::/system.slice/docker-<hash>.scope
//	0::/system.slice/containerd.service
//	0::/kubepods.slice/...
//
// На v1: 12:devices:/docker/<hash>
// Возвращает (containerized, тип маркера).
func detectContainerCgroup(pid int) (bool, string) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cgroup")
	if err != nil {
		return false, ""
	}
	content := string(b)
	switch {
	case strings.Contains(content, "/docker/") || strings.Contains(content, "docker-"):
		return true, "docker"
	case strings.Contains(content, "kubepods"):
		return true, "kubernetes"
	case strings.Contains(content, "/lxc/"):
		return true, "lxc"
	case strings.Contains(content, "containerd"):
		// containerd.service это сам daemon, а не контейнер — но если процесс
		// внутри containerd-managed контейнера, маркер тоже будет.
		// Уточняем: ищем хеш-id который у Docker shim'ов.
		if strings.Contains(content, "cri-containerd") {
			return true, "containerd"
		}
	}
	return false, ""
}
