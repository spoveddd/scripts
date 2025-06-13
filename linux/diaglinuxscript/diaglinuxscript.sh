#!/bin/bash
# Vladislav Pavlovich
# v 1.0.0


# Color
RED='\033[1;31m'
LIGHT_RED='\033[0;31m'
GREEN='\033[1;32m'
DARK_GREEN='\033[0;32m'
DARK_GRAY='\033[1;30m'
YELLOW='\033[1;33m'
DARK_YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
bg_bright_black='\033[48;5;237m'
bg_green='\033[0;97m\033[42m'
bg_blue='\033[44m'
bg_cyan='\033[1;37m\033[46m'
bold='\033[1m'
NC='\033[0m' # reset

if [[ "${LNS}" =~ ^[0-9]+$ ]]; then
    export tail_depth="${LNS}"
else
    export tail_depth="10000"
fi
if [[ "${TAIL_LOG}" =~ ^[0-9]+$ ]]; then
    export log_tail="${TAIL_LOG}"
else
    export log_tail="30"
fi
if [[ "${SMARTCTL_DEBUG}" =~ ^[0-9]+$ ]]; then
    export debug_smartctl="${SMARTCTL_DEBUG}"
else
    export debug_smartctl="0"
fi
if [[ "${DEBUG}" =~ ^[0-9]+$ ]]; then
    export debug="${DEBUG}"
else
    export debug="0"
fi

# No bc
if ! type bc &>/dev/null; then
    bc() {
        local input
        local scale=0
        local result
        local debug=${debug:-0}

        read -r input

        if echo "$input" | grep -q "scale=[0-9]\+;"; then
            scale=$(echo "$input" | awk -F'scale=|;' '{print $2}')
            input=$(echo "$input" | sed 's/scale=[0-9]\+;//')
        fi

        input=$(echo "$input" | sed 's/ *\([+/*><=!]\{1,2\}\) */ \1 /g')
        local tokens=($input)

        if (( ${#tokens[@]} < 3 )); then
            if [[ "$debug" -ne "0" ]]; then
                echo "Ошибка: недостаточно токенов для выполнения операции" >&2
            fi
            return 1
        fi

        result=${tokens[0]}
        local i=1
        while [[ $i -lt ${#tokens[@]} ]]; do
            local operator=${tokens[i]}
            local operand=${tokens[i+1]}

            if [[ -z "$operator" || -z "$operand" ]]; then
                if [[ "$debug" -ne "0" ]]; then
                    echo "Ошибка: отсутствует оператор или операнд" >&2
                fi
                return 1
            fi

            if ! [[ $result =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || ! [[ $operand =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                if [[ "$debug" -ne "0" ]]; then
                    echo "Ошибка: некорректные операнды [$result] и/или [$operand]" >&2
                fi
                return 1
            fi

            result=${result%%.*}
            operand=${operand%%.*}

            if [[ "$debug" -ne "0" ]]; then
                echo -e "alt bc: scale: [${scale}] result: [${result}] operator: [${operator}] operand: [${operand}]" >&2
            fi

            case "$operator" in
                "+")
                    result=$((result + operand))
                    ;;
                "-")
                    result=$((result - operand))
                    ;;
                "*")
                    result=$((result * operand))
                    ;;
                "/")
                    if [[ "$operand" -eq 0 ]]; then
                        if [[ "$debug" -ne "0" ]]; then
                            echo "Ошибка: деление на ноль" >&2
                        fi
                        return 1
                    fi
                    result=$((result / operand))
                    ;;
                ">")
                    [[ $result -gt $operand ]] && result=1 || result=0
                    ;;
                "<")
                    [[ $result -lt $operand ]] && result=1 || result=0
                    ;;
                "==")
                    [[ $result -eq $operand ]] && result=1 || result=0
                    ;;
                ">=")
                    [[ $result -ge $operand ]] && result=1 || result=0
                    ;;
                "<=")
                    [[ $result -le $operand ]] && result=1 || result=0
                    ;;
                "!=")
                    [[ $result -ne $operand ]] && result=1 || result=0
                    ;;
                *)
                    if [[ "$debug" -ne "0" ]]; then
                        echo "Ошибка: неизвестный оператор [$operator]" >&2
                    fi
                    return 1
                    ;;
            esac

            i=$((i + 2))
        done

        echo "$result"
    }
fi


# Detect OS
os_name=$(grep -E "^NAME=" /etc/*release* | cut -d'=' -f2 | tr -d '"')
os_version=$(grep -E "^VERSION_ID=" /etc/*release* | cut -d'=' -f2 | tr -d '"')

if [[ -z "$os_version" ]]; then
    os_version=0
fi

# OS colours
if [[ "$os_name" == *"Debian"* ]]; then
    if echo "$os_version <= 9" | bc -l | grep -q 1; then
        os_color="${bg_bright_black}"  # Old Debian
    elif echo "$os_version == 10" | bc -l | grep -q 1; then
        os_color="${bg_blue}"  # Not new Debian
    else
        os_color="${bg_green}"  # Good Debian
    fi
elif [[ "$os_name" == *"Ubuntu"* ]]; then
    if echo "$os_version <= 18" | bc -l | grep -q 1; then
        os_color="${bg_bright_black}"  # Old Ubuntu
    elif echo "$os_version == 20" | bc -l | grep -q 1; then
        os_color="${bg_blue}"  # Not new Ubuntu
    else
        os_color="${bg_green}"  # Good Ubuntu
    fi
elif [[ "$os_name" == *"CentOS"* ]]; then
    if echo "$os_version <= 7" | bc -l | grep -q 1; then
        os_color="${DARK_GRAY}"  # Old CentOS
    elif echo "$os_version == 8" | bc -l | grep -q 1; then
        os_color="${CYAN}"  # Not new CentOS
    else
        os_color="${WHITE}"  # Good, but not good, because CentOS
    fi
else
    os_color="${bg_cyan}"  # Other OS
fi

#because uptime -p is not available on some OS
uptimep=$(uptime | sed -E 's/^.+up[ \t]{1,7}([0-9]+)[ \t]{1,7}([^ \t]{2,12})[ \t]{1,7}([0-9]{1,2}):([0-9]{1,2}).+/up \1 \2 \3 hours \4 minutes/; s/^.+up[ \t]{1,7}([0-9]{1,2}):([0-9]{1,2}).+/up \1 hours \2 minutes/; s/^.+up[ \t]{1,7}([0-9]+)[ \t]{1,7}([^ \t]{2,12})[ \t]{1,7}([0-9]{1,2}[ \t]{1,7}min).+/up \1 \2 \3/')
echo -e "${os_color}$os_name ${os_version}, ${uptimep}${NC}\n"

if type curl >/dev/null 2>&1; then
    rip=$(timeout 7 curl --insecure -4 -L --max-time 7 --connect-timeout 7 https://ifconfig.me 2>/dev/null)
fi
if ! echo "${rip}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    if type wget >/dev/null 2>&1; then
        rip=$(timeout 7 wget --no-check-certificate --inet4-only --prefer-family=IPv4 --timeout=7 --tries=1 -qO- https://ifconfig.me)
    fi
fi
if ! echo "${rip}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    if type curl >/dev/null 2>&1; then
        rip=$(timeout 7 curl --insecure -4 -L --max-time 7 --connect-timeout 7 https://ipinfo.io/ip 2>/dev/null)
    fi
fi
if ! echo "${rip}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    if type wget >/dev/null 2>&1; then
        rip=$(timeout 7 wget --no-check-certificate --inet4-only --prefer-family=IPv4 --timeout=7 --tries=1 -qO- https://ipinfo.io/ip)
    fi
fi
if echo "${rip}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then 
    echo -e "The \033[3mremote${NC} IPv4 address of this server is [\033[38;5;51m${rip}${NC}]\n";
    echo_ip_notfound() {
        echo -e "    \033[38;5;168mIP \033[38;5;51m${rip}\033[38;5;168m is not found on the local interfaces.${NC}"
    }
    if type ip >/dev/null 2>&1; then
        if ! ip a | grep -E 'inet(6)? ' | awk '{print $2}'| awk -F '/' '{print $1}' | grep -q "${rip}"; then 
            echo_ip_notfound
        fi
    elif type ifconfig >/dev/null 2>&1; then
        if ! ifconfig | grep -E 'inet(6)? ' | awk '{print $2}'| awk -F '/' '{print $1}' | grep -q "${rip}"; then
            echo_ip_notfound
        fi
    else
        echo -e "Where are we? Cannot find ifconfig or ip installed."
    fi
else
    echo -e "Unable to get remote IPv4-addr of this server via HTTP request to https://ifconfig.me and https://ipinfo.io/ip\n - may be network or another problem or no curl/wget installed. [\033[38;5;68m${rip}${NC}]\n";
fi
if echo "${rip}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    CPIP="${rip}"
else
    if  which ip; then
        CPIP=$(ip a | grep inet | grep -E 'brd|scope global' | awk '{print $2}' | awk -F '/' '{print $1}' |head -1 | awk '{print $1}');
    else
        CPIP=$(ifconfig | grep 'inet addr' | grep -v 127.0 | awk '{print $2}' | awk -F ':' '{print $2}' | head -1 | awk '{print $1}');
    fi;
fi
isplogin() {
    local CPIP="$1"
    FVK=$(date | md5sum | head -c16);
    if [ -f "/usr/local/mgr5/sbin/mgrctl" ]; then
        /usr/local/mgr5/sbin/mgrctl -m ispmgr session.newkey username=root key="$FVK" sok=o;
        echo "https://${CPIP}:1500/manager/ispmgr?func=auth&username=root&key=${FVK}&checkcookie=no";
        echo "https://${CPIP}/manager/ispmgr?func=auth&username=root&key=${FVK}&checkcookie=no";
    fi;
    if [ -f "/usr/local/ispmgr/sbin/mgrctl" ]; then
        /usr/local/ispmgr/sbin/mgrctl -m ispmgr session.newkey username=root key="$FVK" sok=o; 
        echo "https://${CPIP}:1500/manager/ispmgr?func=auth&username=root&key=${FVK}&checkcookie=no";
        echo "https://${CPIP}/manager/ispmgr?func=auth&username=root&key=${FVK}&checkcookie=no"; 
    fi;
}
fp2login() {
    local CPIP="$1"
    fp2url=$(mogwai usrlogin)
    echo "https://${CPIP}:${fp2url##*:}"
}
vestalogin() {
    local CPIP="$1"
    curl -s -X POST "https://${CPIP}:8083/api/" -d "user=admin&password=$(grep 'PASSWORD=' /usr/local/vesta/conf/mysql.conf | awk -F\' '{print $2}')"
}
dalogin() {
    local CPIP="$1"
    curl -s --request POST "https://${CPIP}:2222/CMD_LOGIN?username=admin" --data "passwd=$(grep adminpass= /usr/local/directadmin/scripts/setup.txt | cut -d= -f2)" | grep -oP '(?<=Location: ).*'
}
fplogin() {
    local CPIP="$1"
    if ! type htpasswd >/dev/null 2>&1; then
        return
    fi
#    if grep -q "^t2fpsupport:" /var/www/.htpasswd; then
#        echo "User t2fpsupport already exists."
#        return
#    fi
    cpassword=$(date +%s | md5sum | head -c 32)
    if [[ -f /var/www/.htpasswd ]]; then
        htpasswd -b /var/www/.htpasswd t2fpsupport "${cpassword}"
        /etc/init.d/lighttpd restart
#        (sleep 600 && sed -i '/^t2fpsupport:/d' /var/www/.htpasswd && /etc/init.d/lighttpd restart) &
        echo "https://t2fpsupport:${cpassword}@${CPIP}:8888/"
    fi
}
whmlogin() {
    local CPIP="$1"
    whmapi1 create_user_session user=root service=cpaneld | grep -oP '(?<=url: ).*'
}
detect_panel() {
    directories=(fastpanel fastpanel2 mgr5 ispmgr cpanel vesta directadmin)
    found_dirs=()
    for dir in "${directories[@]}"; do
        if [ -d "/usr/local/$dir" ]; then
            found_dirs+=("$dir")
            case "$dir" in
                fastpanel2)
                    echo -e "Найден \033[38;5;21mF\033[38;5;20mA\033[38;5;19mS\033[38;5;54mT\033[38;5;55mP\033[38;5;56mA\033[38;5;57mN\033[38;5;21mE\033[38;5;20mL\033[38;5;39m2${NC}"
                    panel_login_url=$(timeout 7 bash -c 'source /dev/stdin && fp2login "'"${CPIP}"'"' < <(declare -f fp2login))
                    ;;
                fastpanel)
                    echo -e "Найден \033[38;5;54mFastPanel (старая версия)${NC}"
                    panel_login_url=$(timeout 7 bash -c 'source /dev/stdin && fplogin "'"${CPIP}"'"' < <(declare -f fplogin))
                    ;;
                mgr5)
                    echo -e "Найден \033[38;5;51mmgr5${NC}"
                    panel_login_url=$(timeout 7 bash -c 'source /dev/stdin && isplogin "'"${CPIP}"'"' < <(declare -f isplogin))
                    ;;
                ispmgr)
                    echo -e "Найден \033[38;5;54mispmgr (старая версия)${NC}"
                    panel_login_url=$(timeout 7 bash -c 'source /dev/stdin && isplogin "'"${CPIP}"'"' < <(declare -f isplogin))
                    ;;
                cpanel)
                    echo -e "Найден \033[38;5;76mcPanel${NC}"
                    panel_login_url=$(timeout 7 bash -c 'source /dev/stdin && whmlogin "'"${CPIP}"'"' < <(declare -f whmlogin))
                    ;;
                vesta)
                    echo -e "Найден \033[38;5;93mVestaCP${NC}"
                    panel_login_url=$(timeout 7 bash -c 'source /dev/stdin && vestalogin "'"${CPIP}"'"' < <(declare -f vestalogin))
                    ;;
                directadmin)
                    echo -e "Найден \033[38;5;51mDirectAdmin${NC}"
                    panel_login_url=$(timeout 7 bash -c 'source /dev/stdin && dalogin "'"${CPIP}"'"' < <(declare -f dalogin))
                    ;;
            esac
            if [[ "$panel_login_url" =~ ^https:// ]]; then
                echo -e "Ссылка для входа:\n\033[38;5;39m\033[48;5;16m${panel_login_url}${NC}"
            else
                echo "Не удалось сгенерировать ссылку для входа в ${dir}"
                echo -e "Ссылка для входа:\n\033[38;5;39m\033[48;5;16m${panel_login_url}${NC}"
                panel_login_url=""
            fi
        fi
    done

    if [ ${#found_dirs[@]} -gt 1 ]; then
        echo "Найдено более одной панели управления: ${found_dirs[*]}"
    elif [ ${#found_dirs[@]} -eq 0 ]; then
        echo "Панель управления не найдена."
    fi
}

detect_panel

echo ""

# LA
la="$(uptime | awk -F 'load average: ' '{print $2}' | awk '{print $1}'|sed -E 's#,$##'|sed -E 's#,#.#')"

if (( $(bc -l <<< "${la} > 8.01") )); then
    echo -e "${DARK_YELLOW}Средняя нагрузка${NC} \t\t\t${RED}[${la}]${NC}"
elif (( $(bc -l <<< "${la} > 4.01") )); then
    echo -e "${DARK_YELLOW}Средняя нагрузка${NC} \t\t\t${YELLOW}[${la}]${NC}"
else
    echo -e "${WHITE}Средняя нагрузка${NC} \t\t\t${GREEN}[${la}]${NC}"
fi


# Disk space and inodes
df_output=$(df -h --exclude-type=squashfs --exclude-type=tmpfs --exclude-type=devtmpfs | grep -vE "/var/lib/docker")
df_inodes_output=$(df -i --exclude-type=squashfs --exclude-type=tmpfs --exclude-type=devtmpfs | grep -vE "/var/lib/docker")

function check_usage() {
    local line="$1"
    local usage
    local mount
    usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
    mount=$(echo "$line" | awk '{print $6}')
    if [[ "${usage}" != "-" ]]; then
        if [[ "$usage" -ge 90 ]]; then
            echo -e "${DARK_YELLOW}Disk space|inodes \t${RED}[ATTENTION]${NC}"
            if [[ "$mount" == "/" || "$mount" == "/var" || "$mount" == "/usr" || "$mount" == "/home" || "$mount" == "/tmp" ]]; then
                echo -e "${RED}$line${NC}"
            else
                echo -e "${LIGHT_RED}$line${NC}"
            fi
        fi
    fi
}

# Функция для получения максимального использования дискового пространства
get_max_disk_usage() {
    echo "$df_output" | tail -n +2 | awk '{print $5}' | sed 's/%//' | sort -n | tail -1
}

# Функция для получения информации о свободном месте
get_disk_free_info() {
    local max_usage=0
    local min_free=""
    local min_free_mount=""
    
    while read -r line; do
        local usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        local available=$(echo "$line" | awk '{print $4}')
        local mount=$(echo "$line" | awk '{print $6}')
        
        if [[ "${usage}" != "-" && "${usage}" =~ ^[0-9]+$ ]]; then
            if [[ $usage -gt $max_usage ]]; then
                max_usage=$usage
            fi
            
            # Конвертируем в GB
            if [[ "$available" =~ ^[0-9]+(\.[0-9]+)?[KMGT]?$ ]]; then
                local size_gb
                if [[ "$available" =~ G$ ]]; then
                    size_gb=$(echo "$available" | sed 's/G$//')
                elif [[ "$available" =~ T$ ]]; then
                    size_gb=$(echo "$available * 1024" | bc | sed 's/G$//')
                elif [[ "$available" =~ M$ ]]; then
                    size_gb=$(echo "scale=1; ${available%M} / 1024" | bc)
                elif [[ "$available" =~ K$ ]]; then
                    size_gb=$(echo "scale=1; ${available%K} / 1024 / 1024" | bc)
                else
                    size_gb=$(echo "scale=1; $available / 1024 / 1024 / 1024" | bc)
                fi
                
                if [[ -z "$min_free" ]] || (( $(echo "$size_gb < $min_free" | bc -l) )); then
                    min_free=$size_gb
                    min_free_mount=$mount
                fi
            fi
        fi
    done <<< "$(echo "$df_output" | tail -n +2)"
    
    echo "макс: ${max_usage}%, своб: ${min_free}GB"
}

# Функция для получения максимального использования inodes
get_max_inode_usage() {
    echo "$df_inodes_output" | tail -n +2 | awk '{print $5}' | sed 's/%//' | grep -E '^[0-9]+$' | sort -n | tail -1
}

# Disk space
echo "$df_output" | tail -n +2 | while read -r line; do
    check_usage "$line"
done

disk_info=$(get_disk_free_info)
if ! echo "$df_output" | awk '{print $5}' | sed 's/%//' | grep -qE '^(9[0-9]+|100)'; then
    echo -e "Место на диске \t\t\t\t${GREEN}[ОК] (${disk_info})${NC}";
else
    echo -e "Место на диске \t\t\t\t${RED}[ВНИМАНИЕ]${NC}";
fi

# Inodes
echo "$df_inodes_output" | tail -n +2 | while read -r line; do
    check_usage "$line"
done

max_inode_usage=$(get_max_inode_usage)
if ! echo "$df_inodes_output" | tail -n +2 | awk '{print $5}' | sed 's/%//' | grep -qE '^(9[0-9]+|100)'; then
    if [[ -n "$max_inode_usage" ]]; then
        echo -e "Inodes диска \t\t\t\t${GREEN}[ОК] (макс: ${max_inode_usage}%)${NC}";
    else
        echo -e "Inodes диска \t\t\t\t${GREEN}[ОК]${NC}";
    fi
else
    echo -e "Inodes диска \t\t\t\t${RED}[ВНИМАНИЕ]${NC}";
fi

check_read_only_mounts() {
    echo -ne "Проверка разделов только для чтения"
    read_only_mounts=$(mount | awk '$3 == "ro" && $1 !~ /^(ramfs|tmpfs|devtmpfs|proc|sysfs|cgroup|overlay|shm|mqueue)/ { print }')

    if [[ -z "$read_only_mounts" ]]; then
        echo -e " \t${GREEN}[ОК]${NC}"
    else
        echo -e " \t${RED}[ВНИМАНИЕ]${NC}\n${DARK_YELLOW}Найдены разделы только для чтения:${NC}"
        echo "$read_only_mounts"
    fi
}

check_read_only_mounts

check_mdstat() {
    if [[ ! -e /proc/mdstat ]]; then
        return
    fi
    if ! type mdadm &> /dev/null; then
        echo -e "${DARK_YELLOW}/proc/mdstat exists, but mdadm is not available${NC}"
        return
    fi
    mdstat_content=$(cat /proc/mdstat)

    if ls /dev/md[0-9]* 1> /dev/null 2>&1; then
        for raid in /dev/md[0-9]*; do
            raid_data=$(mdadm --detail "${raid}")
            raid_level=$(echo "${raid_data}" | grep -i level | awk -F ':' '{print $2}' | xargs )
            if [[ "${raid_level}" == "raid0" ]]; then
                echo -e "${DARK_YELLOW}/proc/mdstat - RAID-0 detected${NC}"
            fi
        done
    else
        echo -e "${DARK_YELLOW}/proc/mdstat exists, but no RAID arrays found${NC}"
    fi
    if echo "$mdstat_content" | grep -qiE "\[.{0,5}(_U|U_).{0,5}\]"; then
        echo -e "${LIGHT_RED}/proc/mdstat - DEGRADED${NC}\n\n\033[38;5;179m\033[48;5;234m${mdstat_content}${NC}\n\n"
        return
    fi
    if echo "$mdstat_content" | grep -qiE "repair|rebuilding|recovery"; then
        abnormal_status=$(echo "$mdstat_content" | grep -iE "repair|rebuilding|recovery" | awk '{print $NF}' | sort | uniq | tr '\n' ' ')
        echo -e "${DARK_YELLOW}/proc/mdstat - $abnormal_status${NC}"
        return
    fi

    echo -e "/proc/mdstat \t\t\t\t${GREEN}[OK]${NC}"  # No problems
}

check_mdstat

check_value() {
    local name="$1"
    local val="$2"
    local max="$3"
    local errors="$4"
    local desc="${5:-}"

    if [[ "$val" =~ ^[0-9]+$ ]]; then
        if [[ "$val" -ge "$max" ]]; then
            if [[ -n "$desc" ]]; then
                errors=$(echo -e "${DARK_YELLOW}${name} is ${YELLOW}${val}${NC}\t- ${desc}\n${errors}")
            else
                errors=$(echo -e "${DARK_YELLOW}${name} is ${YELLOW}${val}${NC}\n${errors}")
            fi
        fi
    fi

    echo "$errors"
}

check_disks_and_controllers() {
    local disknvme
    disknvme="no"
    if type smartctl > /dev/null 2>&1; then
        lsdisk=$(ls /dev/sd* /dev/hd* /dev/nvme* tests/sd* 2>/dev/null)
        disks=$(echo "$lsdisk" | grep -E 'tests/sd[a-z][0-9]+$|/dev/sd[a-z]+$|/dev/hd[a-z]+$|/dev/nvme[0-9]n[0-9]$')
        for disk in $disks; do
            if [[ "${debug_smartctl}" -gt "0" ]]; then echo -e "\n------------------------------------------------------------\nDEBUG 1: Disk: [${disk}]\n"; fi
            if [[ "${disk}" == /dev/nvme* ]]; then
                # For NVME-disks make two calls
                smart_output=$(smartctl -a "$disk" 2>/dev/null)
                alt_smart_output=$(smartctl -a "${disk%n*}" 2>/dev/null)
                smart_output="$smart_output"$'\n'"$alt_smart_output"
                disknvme="yes"
            else
                # For other disks
                if [[ "${disk}" =~ ^tests/sd.* ]]; then
                    smart_output=$(cat "$disk" 2>/dev/null)
                else
                    smart_output=$(smartctl -a "$disk" 2>/dev/null)
                fi
                disknvme="no"
            fi
            if [[ "${debug_smartctl}" -gt "2" ]]; then echo -e "\nDEBUG 3: disknvme: [${disknvme}]\n"; fi
            if [[ "${debug_smartctl}" -gt "6" ]]; then echo -e "DEBUG 7: smartctl output:\n----------------------\n---------->%----------\n\n${smart_output}\n\n----------%<----------\n----------------------\n"; fi
            # Search hours
            smartheader=$(echo "$smart_output" |sort -u | grep -Ei 'Num\s+Test_Description\s+Status')
            hours_column=$(echo "${smartheader}" | awk '{
                for (i = 1; i <= NF; i++) {
                    if (tolower($i) ~ /hours/) {
                        print i;
                        exit;
                    }
                }
            }')
            if [[ "${debug_smartctl}" -gt "2" ]]; then echo -e "\nDEBUG 3:\nsmartheader: [${smartheader}]\nhours_column: [${hours_column}]\n"; fi

            if [[ -n "$hours_column" ]]; then
                hours_line=$(echo "$smart_output" | grep -E "^\s*[#]?\s*[0-1]?\s+(Extended|Offline|Short).{1,128}(Completed|progress).{1,128}[0-9]{1,10}" | head -1)
                hours_value=$(echo "$hours_line" | sed 's/Self-test routine in progress /Self-test routine in progress  /g' | sed 's/^[ \t]*//' |sed 's/^[ \t]*//'| sed -E 's/([^ ])[ ]([^ ])/\1\2/g'| sed -E 's/[ \t]{2,}/;esd;/g' | awk -v col="${hours_column}" -F';esd;' '{print $col}')
                if [[ "${debug_smartctl}" -gt "2" ]]; then echo -e "\nDEBUG 3: hours_line: [${hours_line}]\nhours_value: [${hours_value}]\n"; fi
            fi
            errors=$(echo "${smart_output}" | grep -iE 'SMART overall-health self-assessment test result:\s{1,10}FAILED|Completed:\s{1,10}read failure|[^_\-]error[^_\-]|[^_\-]fail|critical|SMART overall-health self-assessment test result: FAILED' | grep -viE 'without error|Power_on_Hours\s+Failing_LBA|Critical.*:|Error.*:|Media.*Errors:|No Errors Logged|Error Information\s*\(.*\)|SMART Error Log not supported|SCT Error Recovery Control supported')
            if [[ "${debug_smartctl}" -gt "2" ]]; then echo -e "\nDEBUG 3: INIT errors:\n-------------\n-----------\n${errors}\n-------------\n-------------\n"; fi
            serial=$(echo "$smart_output" | grep -i 'serial number' | sort -u | awk -F: '{print $2}')
            Percentage_Used=$(echo "$smart_output" | grep -i 'Percentage Used' | sort -u | awk -F: '{print $2}' | sed 's/[^[:digit:]]//g')
            altPower_On_Hours=$(echo "$smart_output" | grep -i 'Power On Hours' | sort | uniq | awk -F: '{print $2}' | sed 's/[^[:digit:]]//g')

            Reallocated_Sector_Ct=$(echo "$smart_output" | grep -i 'Reallocated_Sector_Ct' | sort -u |awk '{print $(NF)}' | sed 's/[^[:digit:]]//g')
            Power_On_Hours=$(echo "$smart_output" | grep -i 'Power_On_Hours' | sort | uniq | awk '{print $(NF)}' | sed 's/[^[:digit:]h].*//g')
            Offline_Uncorrectable=$(echo "$smart_output" | grep -i 'Offline_Uncorrectable' | sort -u |awk '{print $(NF)}' | sed 's/[^[:digit:]]//g')
            Current_Pending_Sector=$(echo "$smart_output" | grep -i 'Current_Pending_Sector' | sort -u |awk '{print $(NF)}' | sed 's/[^[:digit:]]//g')
            Offline_Uncorrectable=$(echo "$smart_output" | grep -i 'Offline_Uncorrectable' | sort -u |awk '{print $(NF)}' | sed 's/[^[:digit:]]//g')
            Reported_Uncorrect=$(echo "$smart_output" | grep -i 'Reported_Uncorrect' | sort -u |awk '{print $(NF)}' | sed 's/[^[:digit:]]//g')
            Percent_Lifetime_Used=$(echo "$smart_output" | grep -i 'Percent_Lifetime_Used' | sort -u |awk '{print $(NF)}' | sed 's/[^[:digit:]]//g')
            FAILING_NOW=$(echo "$smart_output" | grep 'FAILING_NOW')
            errors=$(echo -e "${FAILING_NOW}\n${errors}")
            errors=$(check_value "Percentage_Used" "${Percentage_Used}" 100 "$errors" "Old disk")
            errors=$(check_value "Percent_Lifetime_Used" "${Percent_Lifetime_Used}" 100 "$errors" "Old disk")
            errors=$(check_value "Reallocated_Sector_Ct" "${Reallocated_Sector_Ct}" 500 "$errors")
            errors=$(check_value "Offline_Uncorrectable" "${Offline_Uncorrectable}" 200 "$errors")
            errors=$(check_value "Current_Pending_Sector" "${Current_Pending_Sector}" 200 "$errors")
            errors=$(check_value "Reported_Uncorrect" "${Reported_Uncorrect}" 200 "$errors")

            if [[ -z "${hours_value}" ]]; then
                hours_value="0"
                if [[ "${debug_smartctl}" -gt "2" ]]; then echo -e "\nDEBUG 3: no hours_value, so set hours_value to 0\n"; fi
            fi
            if [[ -n "${altPower_On_Hours}" && "${altPower_On_Hours}" =~ ^[0-9]+$ ]]; then
                PoH="${altPower_On_Hours}"
            elif [[ -n "${Power_On_Hours}" && "${Power_On_Hours}" =~ ^[0-9]+$ ]]; then
                PoH="${Power_On_Hours}"
            fi
            if [[ -n "${PoH}" ]]; then
                PoH2="${PoH}"
                if [[ "${PoH}" -gt 65535 ]]; then
                    PoH2=$((PoH % 65535))
                fi
                if [[ "${PoH2}" -ge "${hours_value}" ]]; then
                    hdelay=$((PoH2 - hours_value))
                    if [[ "${debug_smartctl}" -gt "2" ]]; then echo -e "\nDEBUG 3: PowerOnHours2: [${PoH2}], delay: [${hdelay}]\n"; fi
                else
                    hdelay=$((PoH - hours_value))
                    if [[ "${debug_smartctl}" -gt "2" ]]; then echo -e "\nDEBUG 3: PowerOnHours: [${PoH}], delay: [${hdelay}]\n"; fi
                fi
                if [[ "${hdelay}" -gt "168" ]]; then
                    if [[ "${disknvme}" == "yes" && "${hours_value}" == "0" ]]; then
                        errors=$(echo -e "\033[38;5;55mCan't check when the S.M.A.R.T. tests were last run.${NC}\n${errors}")
                    else
                        errors=$(echo -e "${RED}No disk monitoring?${NC} It seems that the last ${WHITE}${disk}${NC} smartctl test was run ${RED}${hdelay}${NC} hours ago!\n${errors}")
                    fi
                fi
            fi

            if [[ "${disk}" == /dev/sd* ]]; then
                is_ssd=$(echo "$smart_output" | grep -i 'rotation rate' | grep -E 'Solid State|0')
                if [[ -n "${is_ssd}" ]]; then
                    disk_type="SSD"
                else
                    disk_type="HDD"
                fi
            elif [[ "${disk}" == /dev/nvme* ]]; then
                disk_type="NVMe"
                if [[ -n "${serial}" ]]; then
                    errors=$(echo "${errors}" | grep -viE 'Read Self-test Log failed: Invalid Field in Command\s+\(0x002\)')
                fi
            else
                disk_type="OLD HDD or ERROR"
            fi

            if [[ -n "${errors}" ]]; then
                echo -e "smartctl ${disk} \t\t${RED}[ВНИМАНИЕ]${NC}"
                echo -e "Диск: ${WHITE}$disk${NC} ($disk_type), S/N: ${YELLOW}$serial${NC}"
                echo -e "${WHITE}Ошибки:${NC}"
                echo -e "\033[38;5;179m\033[48;5;234m$errors${NC}"
            else
                echo -e "smartctl ${WHITE}${disk}${NC} \t\t${GREEN}[ОК]${NC}"
            fi
        done
    else
        if type compgen >/dev/null 2>&1; then
            if compgen -G "/dev/sd*" > /dev/null || compgen -G "/dev/hd*" > /dev/null || compgen -G "/dev/nvme*" > /dev/null; then
                echo -e "smartctl \t\t\t\t\033[38;5;242m[не найден]${NC}"
            fi
        fi
        return
    fi

    # Check megacli and arcconf
    if type megacli > /dev/null 2>&1; then
        echo -e "${DARK_YELLOW}RAID megacli${NC} найден. Проверьте это:"
        megacli_output=$(megacli -LDInfo -Lall -aALL 2>/dev/null)
        megacli_errors=$(echo "$megacli_output" | grep -E 'Fail|Degraded|Offline')
        if [[ -n "${megacli_errors}" ]]; then
            echo -e "${RED}Ошибки в megacli:${NC}"
            echo "$megacli_errors"
        else
            echo -e "megacli \t\t\t\t${GREEN}[ОК]${NC}"
        fi
    fi

    if type arcconf > /dev/null 2>&1; then
        echo -e "${DARK_YELLOW}RAID adaptec${NC} arcconf найден. Проверьте это:"
        arcconf_output=$(arcconf getconfig 1 ld 2>/dev/null)
        arcconf_errors=$(echo "$arcconf_output" | grep -E 'Group.*Segment.*: Missing')
        if [[ -n "${arcconf_errors}" ]]; then
            echo -e "${RED}Ошибки в arcconf:${NC}"
            echo "$arcconf_errors"
        else
            echo -e "arcconf \t\t\t\t${GREEN}[ОК]${NC}"
        fi
    fi
}

check_disks_and_controllers

# RAM SWAP
check_swap_ps() {
    echo "    ${DARK_YELLOW}TOP-10 swap usage:${NC}";
    current_line=0
    ps_out=$(ps -e -o pid --no-headers)
    ps_rows=$(echo "${ps_out}" | wc -l)
    echo -e "${ps_out}" | while read -r pid; do
        ((current_line++))
        percent=$(( 100 * current_line / ps_rows ))
        echo -ne "\033[2K\rProcessing swap: $percent%" >&2
        comm=$(awk '/^Name:/{print $2}' "/proc/${pid}/status" 2>/dev/null)
        awk '/VmSwap/{print $2 " " "'"$comm"'"}' "/proc/$pid/status" 2>/dev/null;
    done | awk '{proc[$2] += $1} END {for (p in proc) printf "        %.2f MB\t\t%s\n", proc[p]/1024, p}' | sort -nr | head -10
    echo -ne "\033[2K\r                                               " >&2
    echo -ne "\033[2K\r" >&2
    echo -e "    \n"
}

check_ram_swap() {
    local min_free_mem
    local min_available_mem
    local max_swap_usage
    local free_mem
    local available_mem
    local used_swap
    local result

    min_free_mem=50
    min_available_mem=200
    max_swap_usage=100
    # Get current values
    free_mem=$(free -m | awk '/^Mem:/ {print $4}')
    available_mem=$(free -m | awk '/^Mem:/ {print $7}')
    used_swap=$(free -m | awk '/^Swap:/ {print $3}')

    result=""
    if (( free_mem < min_free_mem )); then
        result+="    ${DARK_YELLOW}Warning: Low free memory (${YELLOW}${free_mem}MB${NC})\n"
    fi
    if (( available_mem < min_available_mem )); then
        result+="    ${DARK_YELLOW}Warning: Low available memory (${YELLOW}${available_mem}MB${NC})\n"
    fi
    if (( used_swap > max_swap_usage )); then
        result+="    ${DARK_YELLOW}Warning: Swap usage is high (${YELLOW}${used_swap}MB${NC})\n"
        result+=$(check_swap_ps)
    fi
    if [[ -n "$result" ]]; then
        echo -e "$result"
    fi
}

# Функция для получения детальной информации о RAM/SWAP
get_ram_swap_details() {
    local total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    local used_mem=$(free -m | awk '/^Mem:/ {print $3}')
    local total_swap=$(free -m | awk '/^Swap:/ {print $2}')
    local used_swap=$(free -m | awk '/^Swap:/ {print $3}')
    
    echo "RAM: ${used_mem}MB/${total_mem}MB, SWAP: ${used_swap}MB/${total_swap}MB"
}

ram_swap_status=$(check_ram_swap)
ram_swap_details=$(get_ram_swap_details)
if [[ -n "${ram_swap_status}" ]]; then
    echo -e "${DARK_YELLOW}Использование RAM|SWAP \t\t${RED}[ВНИМАНИЕ] (${ram_swap_details})${NC}"
    echo -e "${ram_swap_status}"
else
    echo -e "Использование RAM|SWAP \t\t\t${GREEN}[ОК] (${ram_swap_details})${NC}"
fi

# Large logs
check_log_dir() {
    local path
    local depth
    local size_threshold
    path=$1
    depth=$2
    size_threshold=${3:-50M}
    find "$path" -maxdepth "$depth" -type f -size +"$size_threshold" ! -name "*.gz" 2>/dev/null
}
find_large_logs() {
    local size_threshold
    local paths
    size_threshold=${1:-50M}
    paths=(
        "/var/log/ 3"
        "/var/www/*/data/logs/ 1"
        "/var/www/httpd-logs/ 1"
        "/home/*/logs/ 1"
    )
    local result=""
    for path_info in "${paths[@]}"; do
        local path
        path=
        local depth
        local log_files
        path=$(echo "$path_info" | awk '{print $1}')
        depth=$(echo "$path_info" | awk '{print $2}')
        log_files=$(check_log_dir "$path" "$depth" "$size_threshold")
        if [[ -n "$log_files" ]]; then
            while IFS= read -r file; do
                local file_size
                file_size=$(du -h "$file" | awk '{print $1}')
                result+="    ${DARK_YELLOW}$file_size${NC} \t $file"$'\n'
            done <<< "$log_files"
        fi
    done
    result=$(echo "$result" | sed '/^$/d' | sort -nrk1)
    echo "$result"
}

# find_large_logs "100M"
large_logs=$(find_large_logs "500M");

if [[ -n "${large_logs}" ]]; then
    echo -e "Большие логи \t\t\t\t${RED}[НАЙДЕНЫ]${NC}"
    echo -e "Вероятно нарушена ротация логов или другие проблемы. Большие логи:"
    echo -e "${large_logs}"
else
    echo -e "Большие логи \t\t\t\t${GREEN}[ОК]${NC}"
fi

check_lastlogs() {
    local size_limit
    local size_limit_bytes
    size_limit=${1:-50}
    if [[ $size_limit == *M ]]; then
        size_limit=${size_limit%M}
    fi
    #local size_limit_bytes=$((size_limit * 1024 * 1024))  # Convert MB to bytes
    size_limit_bytes=$(echo "$size_limit * 1024 * 1024" | bc)
    for file in /var/log/[a-z]tmp; do
        if [[ -f "$file" ]]; then
            local file_size
            local file_size_mb
            file_size=$(stat -c%s "$file")  # Get file size in bytes
            file_size_mb=$(bc <<< "scale=2; $file_size / 1024 / 1024")
            if [[ $file_size_mb == .* ]]; then
                file_size_mb="0$file_size_mb"
            fi
            if (( $(bc <<< "$file_size > $size_limit_bytes") )); then
                echo -e "    ${DARK_YELLOW}${file_size_mb}M${NC} \t ${file}"
            fi
        fi
    done | sort -nrk1
}

# find_large_lastlogs "for example: 100M"
large_lastlogs=$(check_lastlogs "128M");

if [[ -n "${large_lastlogs}" ]]; then
    echo -e "Большие last-логи \t\t\t${RED}[НАЙДЕНЫ]${NC}"
    echo -e "${bold}\tЭто может привести к задержкам и зависанию CRON-задач при запуске su-сессий,\n\tвходе на сервер и других операциях, требующих открытия пользовательской сессии. Найденные файлы:${NC}"
    echo -e "${large_lastlogs}"
else
    echo -e "Большие last-логи \t\t\t${GREEN}[ОК]${NC}"
fi

# Failed services
if type systemctl >/dev/null 2>&1; then
    if systemctl list-units --state=failed &>/dev/null; then
        failed_list=$(systemctl list-units --state=failed | grep -vE '(LOAD|ACTIVE|SUB).+(Reflects.+unit.+loaded|high-level.+unit.+SUB|low-level.+unit.+unit.+type)')
    else
        failed_list=$(systemctl list-units --all | grep "failed" | grep -vE '(LOAD|ACTIVE|SUB).+(Reflects.+unit.+loaded|high-level.+unit.+SUB|low-level.+unit.+unit.+type)')
    fi
    if [[ $(echo "${failed_list}" | grep -cE '0[ \t]+loaded units listed') -ne "1" && $(echo "${failed_list}"| grep -cvE "^$") -gt "0" ]]; then
        echo -e "Упавшие systemd сервисы \t\t${RED}[НАЙДЕНЫ]${NC}"
        echo -e "\033[38;5;88m${failed_list}${NC}\n"
    else
            echo -e "Упавшие systemd сервисы \t\t${GREEN}[ОК]${NC}"
    fi
else
    echo -e "Упавшие systemd сервисы \t\t${DARK_GRAY}[Н/Д]${NC}"
fi

# Check nginx/apache
if type nginx >/dev/null 2>&1; then
    nginx_test=$(nginx -t 2>&1)
    nginx_status=$(echo "${nginx_test}" |grep -ci 'test failed')
    if [[ "${nginx_status}" -ne "0" ]]; then
        echo -e "Тест Nginx \t\t\t\t${RED}[ОШИБКА]${NC}"
        echo -e "${nginx_test}\n"
    else
        echo -e "Тест Nginx \t\t\t\t${GREEN}[ОК]${NC}"
    fi 
else
    echo -e "Тест Nginx \t\t\t\t${DARK_GRAY}[Н/Д]${NC}"
fi
if type apache2ctl >/dev/null 2>&1; then
    apache2_test=$(apache2ctl -t 2>&1)
    apache2_status=$(echo "${apache2_test}" |grep -ci 'Syntax OK')
    if [[ "${apache2_status}" -lt "1" ]]; then
        echo -e "Проверка Apache2 \t\t\t${RED}[ОШИБКА]${NC}"
        echo -e "${apache2_test}\n"
    else
        echo -e "Тест Apache2 \t\t\t\t${GREEN}[ОК]${NC}"
    fi
elif type apachectl >/dev/null 2>&1; then
    apache_test=$(apachectl -t 2>&1)
    apache_status=$(echo "${apache_test}" |grep -ci 'Syntax OK')
    if [[ "${apache_status}" -lt "1" ]]; then
        echo -e "Проверка Apache \t\t\t${RED}[ОШИБКА]${NC}"
        echo -e "${apache_test}\n"
    else
        echo -e "Тест Apache \t\t\t\t${GREEN}[ОК]${NC}"
    fi
else
    echo -e "Тест Apache \t\t\t\t${DARK_GRAY}[Н/Д]${NC}"
fi
if [ -e /proc/user_beancounters ]; then
    if [ "$(grep -v failcnt /proc/user_beancounters | grep -v Version | grep -cvE ' 0$')" -gt "0" ]; then
        echo -e "/proc/user_beancounters \t\t${RED}[ВНИМАНИЕ]${NC}"
        echo -e "${DARK_YELLOW}/proc/user_beancounters обнаружены ошибки:${NC}"; grep -v failcnt /proc/user_beancounters  | grep -v Version | grep -vE " 0$";
    else
        echo -e "/proc/user_beancounters \t\t${GREEN}[ОК]${NC}"
    fi
fi





# DL

echo -e "\n\033[38;5;109m\033[3m Помните - это приложение не заменяет ваш \n мозг и знания, оно только экономит ваше время.\033[0m"

# TOP Ratings
# Cooldown before make CPU rating
for i in {16..51}; do echo -ne "\033[38;5;${i}m.\\033[0m"; sleep 0.05; done
echo -e "\nМой PID: $BASHPID"
echo -e "\n${bg_bright_black}\033[38;5;253mТОП 5 процессов по \033[38;5;43mиспользованию CPU:${NC}"
strip_ps() {
    grep -v 'ps -eo %cpu,pid,args --sort=-%cpu'
}
ps -eo %cpu,pid,args --sort=-%cpu | strip_ps | awk 'NR > 1 {
    cmd = "";
    for (i=3; i<=NF; i++) cmd = cmd $i " ";
    if (length(cmd) > 172) cmd = substr(cmd, 1, 169) "...";
    cmd_name = "";
    args = "";
    first_space = index(cmd, " ");
    if (first_space > 0) {
        cmd_name = substr(cmd, 1, first_space - 1);
        args = substr(cmd, first_space + 1);
    } else {
        cmd_name = cmd;
    }
    if (length(args) > 0) {
        args = substr(args, 1, length(args) - 1);
        cmd = cmd_name " \033[1;30m" args "\033[0m";
    } else {
        cmd = cmd_name;
    }
    printf "%6.2f%%   %d   %s\n", $1, $2, cmd
}' | head -5


echo -e "\n${bg_bright_black}\033[38;5;253mТОП 5 процессов по \033[38;5;178mиспользованию RAM:${NC}"
ps -eo %mem,pid,args --sort=-%mem | awk 'NR > 1 {
    cmd = ""; 
    for (i=3; i<=NF; i++) cmd = cmd $i " "; 
    if (length(cmd) > 172) cmd = substr(cmd, 1, 169) "...";
    cmd_name = "";
    args = "";
    first_space = index(cmd, " ");
    if (first_space > 0) {
        cmd_name = substr(cmd, 1, first_space - 1);
        args = substr(cmd, first_space + 1);
    } else {
        cmd_name = cmd;
    }
    if (length(args) > 0) {
        args = substr(args, 1, length(args) - 1);
        cmd = cmd_name " \033[1;30m" args "\033[0m";
    } else {
        cmd = cmd_name;
    }
    printf "%6.2f%%   %d   %s\n", $1, $2, cmd
}' | head -5


check_disk_load() {
    if ! type atop >/dev/null 2>&1; then
        return
    fi
    atop_output=$(timeout 7 atop -d 1 1); 
    if [[ -z "${atop_output}" ]]; then
        echo -e "${RED}ОШИБКА:${NC} не удалось запустить atop с таймаутом 7 секунд. Вероятно atop сломан или другая проблема.";
        return
    fi
    atop_output=$(echo "$atop_output" | grep -E '^[ \t]*[0-9]+[ \t]+[-]?[^%]+[0-9]{1,3}%' | grep -vE '[ \t]+0%')
    atop_rows=$(echo "$atop_output" | wc -l)

    if [[ -z "$atop_output" ]]; then
        echo "Неожиданный формат atop - требуются права root."
        return
    fi

    declare -A processess

    if [[ ! -r /proc ]]; then
        echo "Нет доступа к /proc, используются имена команд вместо имен пользователей."
        access_proc=false
    else
        access_proc=true
    fi
    current_line=0
    while IFS= read -r line; do
        ((current_line++))
        percent=$(( 100 * current_line / atop_rows ))
        echo -ne "\033[2K\rОбработка: $percent%"
        if echo "$line" | grep -Eq '^[ \t]*[0-9]+[ \t]+[-]?[^%]+[0-9]{1,3}%'; then
            pid=$(echo "$line" | awk '{print $1}')
            disk_load=$(echo "$line" | awk '{print $(NF-1)}' | sed 's/%//')
            cmd=$(echo "$line" | awk '{print $NF}')
            name=""
            if (( $(echo "$disk_load > 0" | bc -l) )); then
                if [[ $access_proc == true ]]; then
                    if [[ -d "/proc/$pid" ]]; then
                        user=$(stat -c '%U' /proc/"$pid" 2>/dev/null)
                        if [[ -n "$user" ]]; then
                            name="$user"
                        fi
                    fi
                    if [[ -z "$name" ]]; then
                        name="$cmd"
                    fi
                else
                    name="$cmd"
                fi
            else
                continue
            fi
            if [[ -n "${processess[$name]}" ]]; then
                processess["$name"]=$(echo "${processess[$name]} + $disk_load" | bc)
            else
                processess["$name"]=$disk_load
            fi
        fi
    done <<< "$atop_output"
    echo -ne "\033[2K\r                                        "
    echo -ne "\033[2K\r"
    ncnt=0
    printf "\033[38;5;247m%12s  %-32s \033[38;5;240m%-7s   %-7s   %s${NC}\n" "%Нагрузка " "Пользователь" "PID" "%Нагрузка" "Процесс"
    for name in "${!processess[@]}"; do
        ((ncnt++))
        nextpid=$(echo "${atop_output}"| awk '{print $1}' | sed -n "${ncnt}p")
        nextload=$(echo "${atop_output}"| awk '{print $(NF-1)}' | sed -n "${ncnt}p")
        nextcmd=$(echo "${atop_output}"| awk '{print $NF}' | sed -n "${ncnt}p")
        printf "\033[38;5;253m%10.2f%%   %-32s \033[38;5;247m%-7d   %-7s   %s${NC}\n" "${processess[$name]}" "$name" "$nextpid" "$nextload" "$nextcmd"
    done | sort -k1 -n -r | head -5
}

echo -e "\n${bg_bright_black}\033[38;5;253mТОП 5 пользователей/процессов по \033[38;5;159mнагрузке на диск:${NC}"
check_disk_load

top_u_proc=$(echo -e "\n${bg_bright_black}\033[38;5;253mпо \033[38;5;159mпроцессам${NC}${bg_bright_black}                    ${NC}"; ps aux | awk 'NR > 1 {count[$1]++} END {for (user in count) printf "%4d   %s\n", count[user], user}' | sort -nr | head -7);
top_u_cpu=$(echo -e "\n${bg_bright_black}\033[38;5;253mпо \033[38;5;43mCPU${NC}${bg_bright_black}\033[38;5;253m нагрузке (%CPU usage)           ${NC}"; ps aux --sort=-%cpu | awk 'NR > 1 {cpu[$1]+=$3} END {for (user in cpu) printf "%10.2f%%   %s\n", cpu[user], user}' | sort -nr | head -7);
top_u_ram=$(echo -e "\n${bg_bright_black}\033[38;5;253mпо \033[38;5;178mRAM${NC}${bg_bright_black}\033[38;5;253m (использование памяти)     ${NC}"; ps aux --sort=-%mem | awk 'NR > 1 {ram[$1]+=$6/1024} END {for (user in ram) printf "%10.2fMB   %s\n", ram[user], user}' | sort -nr | head -7);
echo -ne "\nТОП 7 пользователей:"
top_u_lines=""
for i in {1..9}; do
    top_u_proc_l=$(echo -e "${top_u_proc}"| sed -n "${i}p")
    top_u_cpu_l=$(echo -e "${top_u_cpu}"| sed -n "${i}p")
    top_u_ram_l=$(echo -e "${top_u_ram}"| sed -n "${i}p")
    top_u_lines=$(printf "%-30s %-37s %-38s\n" "${top_u_proc_l}" "${top_u_cpu_l}" "${top_u_ram_l}")
    echo "${top_u_lines}"
done


sort_by_date() {
    while read -r line; do
        if [[ "$line" =~ [[:space:]]([A-Z][a-z]{2}[[:space:]][0-9]{1,2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
            # Mon Sep 30 15:38:01 2024
            timestamp=$(date -d "${BASH_REMATCH[1]}" +%s)
        elif [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
            # 2024-09-30T12:37:37.708356+03:00
            timestamp=$(date -d "${BASH_REMATCH[1]}" +%s)
        elif [[ "$line" =~ [[:space:]]([A-Z][a-z]{2}[[:space:]][0-9]{1,2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]][0-9]{4}) ]]; then
            # Oct 01 01:10:45 2024
            timestamp=$(date -d "${BASH_REMATCH[1]}" +%s)
        else
            timestamp=$(date +%s)
        fi
        echo "$timestamp     $line"
    done | sort -n | cut -d' ' -f2-
}

# Logw patterns
grep_patterns="Cannot allocate memory|Too many open files|marked as crashed|Table corruption|Database page corruption|errno: 145|SYN flooding|emerg|error|temperature|[^e]fault|fail[^2]|i/o.*(error|fail|fault)|ata.*FREEZE|ata.*LOCK|ata3.*hard resetting link|EXT4-fs error|Input/output error|memory corruption|Remounting filesystem read-only|Corrupted data|Buffer I/O error|XFS.{1,20}Corruption|Superblock last mount time is in the future|degraded array|array is degraded|disk failure|Failed to write to block|failed to read/write block|slab corruption|Segmentation fault|segfault|Failed to allocate memory|Low memory|Out of memory|oom_reaper|link down|SMART error|kernel BUG|EDAC MC0:"
exclude_patterns="Scanning for low memory corruption every [0-9]{1,5} seconds$|Scanning [0-9]{1,3} areas for low memory corruption$|No matching DirectoryIndex|error log file re-opened|xrdp_(sec|rdp|process|iso)_|plasmashell\[.*wayland|chrom.*Fontconfig error|plasmashell\[.*Image: Error decoding|Playing audio notification failed|systemd\[.*plasma-.*\.service|uvcvideo.*: Failed to|kioworker\[.*: kf.kio.core|(plasmashell|wayland)\[.*TypeError:|org_kde_powerdevil.*org\.kde\.powerdevil|Failed to set global shortcut|wayland_wrapper\[.*not fatal|RAS: Correctable Errors collector initialized|spectacle\[.*display"

strip_log() {
    sed -E '
        s/^.+(\[Warning\][ \t]{1,7}Aborted[ \t]{1,7}connection).+/\1/
        s/^.+(Temperature_Celsius[ \t]{1,7}changed[ \t]{1,7}from).+/\1/
        s/^.+(ERROR[ \t]{1,7}Cannot[ \t]{1,7}reissue|can[ \t]{1,7}not[ \t]{1,7}be[ \t]{1,7}issued[ \t]{1,7}as[ \t]{1,7}URL).+/\1/
        s/^.+routines:tls_parse_ctos_key_share:bad.+/routines:tls_parse_ctos_key_share:bad/
        s/^[^\[]+\[[^\]+\]([^\[]+)/\1/
        s/^.+((is[ \t]{1,7}not[ \t]{1,7}found|failed).+No[ \t]{1,7}such[ \t]{1,7}file[ \t]{1,7}or[ \t]{1,7}directory).+HTTP.+/\1/
        s/^.+(pci[ \t]{1,7}.+:).+\[.+\]:.+failed to assign.*/\1/
        s/^.+(mysql\.service:[ \t]{1,7}Failed[ \t]{1,7}with[ \t]{1,7}result[ \t]{1,7}.+)/\1/
        s/^.+(mysql.service:[ \t]{1,7}Unit[ \t]{1,7}entered[ \t]{1,7}failed[ \t]{1,7}state).+/\1/
        s/^.+(systemd\[[0-9]{1,9}\]:[ \t]{1,7}Failed[ \t]{1,7}to[ \t]{1,7}start[ \t]{1,7}.+)/\1/
        s/^.+pci.+:[ \t]{1,7}BAR[ \t]{1,7}[0-9]{1,7}:[ \t]{1,7}(failed[ \t]{1,7}to[ \t]{1,7}assign[ \t]{1,7}\[io[ \t]{1,7}size).+\]/\1/
        s/^.+dovecot:.+Connection[ \t]{1,7}closed:[ \t]{1,7}read.+(failed:[ \t]{1,7}Connection[ \t]{1,7}reset[ \t]{1,7}by[ \t]{1,7}peer).+/\1/
        # [Tue Oct 01 17:36:19 2024] [error] mod_fcgid: process /var/www/zilforum/data/php-bin/php(8505) exit(communication error), get unexpected signal 7
        s/^.+fcgid:[ \t]{1,7}process.+(exit.+unexpected[ \t]{1,7}signal[ \t]{1,7}[^ \t]{1,12}).*/\1/
        # [error] 2911#2911: *2853281 open() "/var/www/index.html/blog/wp-includes/wlwmanifest.xml" failed (20: Not a directory)
        s/^.+\[error\].+open\(\).+(failed[ \t]{1,7}\(20: Not a directory\)).+/\1/
        # cloud-init[632]: 2024-10-02 19:29:17,593 - url_helper.py[WARNING]
        s/^.+cloud-init\[.+url_helper\.py\[WARNING\]:.+/url_helper.py[WARNING]:/
        # [crit] 28029#28029: *30946025 SSL_do_handshake() failed (SSL: error:140944E7:SSL
        s/^.+\[crit\][ \t]{1,7}.+:[ \t]{1,7}.+(SSL_do_handshake\(\)[ \t]{1,7}failed[ \t]{1,7}\(SSL:[ \t]{1,7}error:.+:SSL).+/\1/
        # dovecot: pop3-login: Error: Diffie-Hellman key exchange requested, but
        s/^.+(dovecot:[ \t]{1,7}.+-login:[ \t]{1,7}Error:[ \t]{1,7}Diffie-Hellman[ \t]{1,7}key[ \t]{1,7}exchange[ \t]{1,7}requested,[ \t]{1,7}but).+$/\1/
        # Search: Device: /dev/sda [SAT], SMART Usage Attribute: 194 Temperature_Celsius changed from 72 to 71
        s/^.+(Device:[ \t]{1,7}.+SMART[ \t]{1,7}Usage[ \t]{1,7}Attribute:.+Temperature_Celsius[ \t]{1,7}changed[ \t]{1,7}from).+$/\1/
        # Search: pam_unix(sshd:auth): authentication failure
        s/^.+(pam_unix\([^:]+:auth\):[ \t]{1,7}authentication[ \t]{1,7}failure).+$/\1/
        # Search: Failed password for username/invalid user username from
        s/^.+(Failed[ \t]{1,7}password[ \t]{1,7}for[ \t]{1,7}invalid[ \t]{1,7}user).+$/\1/
        s/^.+(Failed[ \t]{1,7}password[ \t]{1,7}for[ \t]{1,7}.+[ \t]{1,7}from).+$/\1/
        # Search: mod_fcgid: process 1229 graceful kill fail, sending SIGKILL
        s/^.+mod_fcgid:[ \t]{1,7}process[ \t]{1,7}[0-9]{1,12}[ \t]{1,7}(graceful[ \t]{1,7}kill[ \t]{1,7}fail,[ \t]{1,7}sending[ \t]{1,7}.+)$/\1/
        # Search: *pid 123456
        s/^.+(:.+, pid )[0-9]+$/\1/
        # Search: systemd-modules-load[402]: Failed to find module
        s/^.*(systemd-modules-load\[[0-9]{1,9}\]: Failed to find module).*/\1/
        # Search: for [^ ]+: Invalid Parameters
        s/^.*(for [^ ]+: Invalid Parameters).*/\1/
        # Search: HANDLING IBECC MEMORY ERROR
        s/^.*HANDLING IBECC MEMORY ERROR.*/HANDLING IBECC MEMORY ERROR/
        # Search: (nginx) 2024/09/25 22:44:20 [emerg] 392703#392703: unknown directive "testfail" in /etc/nginx/nginx.conf:31
        s/^[0-9]{4}\/[0-9]{2}\/[0-9]{2}[ \t]{1,12}[0-9]{2}:[0-9]{2}:[0-9]{2}[ \t]{1,12}[^:]{1,32}://
        # Search: Possible SYN flooding on port
        s/^.{1,128}Possible SYN flooding on port([ \t]{1,3}[0-9]{1,5}).+/Possible SYN flooding on port\1/
        # Search: pop3-login|imap-login
        s/^.+(pop3-login|imap-login):.+rip.+$/\1:/
        # Search: (start|stop)_traps.sh
        s/^.+((start|stop)_traps\.sh)\[[0-9]{1,11}\]:.+$/\1:/
        # Search: netfilter-persistent[378]: Error occurred at line: 10
        s/^.+netfilter-persistent\[[0-9]{1,11}\]:[ \t]{1,3}([^$]{1,})$/\1/
        # Search: Sep 24 01:45:01 servername appname[828338]: message
        s/^[A-Za-z]{3}[ \t]{1,3}[0-9]{1,2}[ \t]{1,3}[0-9]{2}:[0-9]{2}:[0-9]{2}[ \t]{1,3}[^:]{5,32}\]: //
        # Search: Sep 24 01:45:01
        s/^[A-Za-z]{3}[ \t]{1,3}[0-9]{1,2}[ \t]{1,3}[0-9]{2}:[0-9]{2}:[0-9]{2}[ \t]{1,3}[^ ]+ //
        # Search: 2024-09-24T01:42:01.469131+03:00 srv appname[2935502]: message
        s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+[+-][0-9]{2}:[0-9]{2}[ \t]{1,3}[^ ]{2,32} [^ ]{2,12}\[[0-9]+\]: [^ ]+ //
        # Search: 2024-09-24T01:42:01.469131+03:00
        s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+[+-][0-9]{2}:[0-9]{2}[ \t]{1,3}[^ ]+ //
        # Search: Mon Sep 23 20:58:26 2024
        s/^\s*[A-Za-z]{3}\s*[A-Za-z]{3}\s*[0-9]{1,2}\s*[0-9]{2}:[0-9]{2}:[0-9]{2}\s*[0-9]{4}\s*//
        # Search: [Fri Sep  6 04:41:47 2024] copyq[1309443]: segfault at 50
        s/^\s*\[[A-Za-z]{3}\s*[A-Za-z]{3}\s*[0-9]{1,2}\s*[0-9]{2}:[0-9]{2}:[0-9]{2}\s*[0-9]{4}\s*\][ \t]{1,3}[^ ]{2,12}\[[0-9]+\]: segfault at( [^ \t]{1,32}).+/segfault at\1/
        # Search: [Fri Sep  6 04:41:47 2024]
        s/^\s*\[[A-Za-z]{3}\s*[A-Za-z]{3}\s*[0-9]{1,2}\s*[0-9]{2}:[0-9]{2}:[0-9]{2}\s*[0-9]{4}\s*\]//
        # Search: *asm_exc_page_fault+0x1e/0x30
        s/^.+\[[\s*[0-9]+\.[0-9]+\].+[a-z]{1,32}(_fault\+[0-9]?x)[^$]{1,}$/\1/
        # Search: Network service crashed, restarting service
        s/^.+([ \t][^ \t]{1,128} service crashed, restarting service.+)$/\1/
        # Search: [1527399.492467]
        s/^\s*\[\s*[0-9]+\.[0-9]+\] //
        s/^[ \t]*\[[0-9TZ:\-]{20,}\] (.+)/\1/
        s/^.+(Failed[ \t]{1,7}to[ \t]{1,7}canonicalize[ \t]{1,7}path).+Permission[ \t]{1,7}denied.*/\1/
        s/^.+:[ \t]{1,7}(\[[^]]{32,}\]).*/\1/
    '
}

# Log analyze
analyze_log() {
    local log_name=$1
    local log_command=$2
    local filter_command=$3
    local super_danger="(i/o\s*(error|fail|fault)|EXT4-fs error|Input/output error|FAILED SMART self-check.+BACK UP DATA NOW!|BACK UP DATA NOW!)"
    local danger="(FAILED SMART self-check|Too many open files|Remounting filesystem read-only|Corrupted data|Buffer I/O error|XFS.{1,20}Corruption|Superblock last mount time is in the future|degraded array|array is degraded|disk failure|Failed to write to block|failed to read/write block|slab corruption)"
    local warn="(memory corruption|Cannot allocate memory|marked as crashed|Table corruption|Database page corruption|errno: 145|Segmentation fault|segfault|Failed to allocate memory|Low memory|Out of memory|oom_reaper|link down|SMART error|kernel BUG|EDAC MC0:|service: Failed)"
    local regex_trigger="(${grep_patterns})"

    get_log_rows() {
        local lines=0
        while IFS= read -r line; do
            echo -e "${line}"
            ((lines++))
        done
        if [[ "${lines}" -eq "0" ]]; then
            printf "    %-32s \t%s\n" "${log_name}" "$(echo -e "\033[1;32m[ОК]\033[0m")"
        fi
    }
    # If log it is file
    if [[ "$log_command" =~ ^tail\ - ]]; then
        log_file=$(echo "${log_command}" | awk '{print $3}')  # Get filename from tail
        if [[ -f "$log_file" ]]; then  # Check file exist
            echo -e "\n${bg_bright_black}\033[38;5;253mАнализ ${log_name}:${NC}"
            current_line=0
            if [[ -n $filter_command ]]; then
                while IFS= read -r line; do
                    ((current_line++))
                    percent=$(( 100 * current_line / log_tail ))
                    echo -ne "\033[2K\rОбработка ${log_name}: $percent%" >&2
                    logcnt=$(echo "${line}" | awk '{print $1}')
                    cntcolor="\033[38;5;244m";
                    if [[ "${logcnt}" -ge "3" ]]; then
                        cntcolor='\033[38;5;172m';
                    fi
                    if [[ "${logcnt}" -ge "10" ]]; then
                        cntcolor='\033[38;5;166m';
                    fi
                    if [[ "${logcnt}" -ge "20" ]]; then
                        cntcolor='\033[38;5;161m';
                    fi
                    if [[ "${logcnt}" -ge "50" ]]; then
                        cntcolor='\033[38;5;160m';
                    fi
                    logsearch=$(echo "${line}" | sed -E 's/^[ \t]{0,30}[0-9]{1,10}[ \t]{0,30}//g; s/^[\t \-]{1,30}//g')
                    #echo "line [${line}]"
                    #echo "logsearch [${logsearch}]"
                    echo -ne "    [${cntcolor}${logcnt}${NC}] "
                    output=$($log_command | grep -F "${logsearch}" | tail -1 |awk '{s=substr($0,1,512); if(length($0)>512) s=s"…"; print s}' | sed -E "s#(${super_danger})#\\x1b[1;37m\\\x1b[41m\\1\\x1b[0m#Ig; t end; s#(${danger})#\\x1b[0;31m\\1\\x1b[0m#Ig; t end; s#(${warn})#\\x1b[1;33m\\1\\x1b[0m#Ig; t end; s#(${regex_trigger})#\\x1b[0;97m\\1\\x1b[0m#Ig; :end")
                    printf "%b\n" "${output}"
                done < <(eval "$log_command | $filter_command" | grep -iE "$grep_patterns" | grep -vE "$exclude_patterns" | strip_log | sort | uniq -c | sort -nk1 | tail -"${log_tail}")
                echo -ne "\033[2K\r                                               " >&2
                echo -ne "\033[2K\r" >&2
            else
                while IFS= read -r line; do
                    ((current_line++))
                    percent=$(( 100 * current_line / log_tail ))
                    echo -ne "\033[2K\rОбработка ${log_name}: $percent%" >&2
                    logcnt=$(echo "${line}" | awk '{print $1}')
                    cntcolor="\033[38;5;244m";
                    if [[ "${logcnt}" -ge "3" ]]; then
                        cntcolor='\033[38;5;172m';
                    fi
                    if [[ "${logcnt}" -ge "10" ]]; then
                        cntcolor='\033[38;5;166m';
                    fi
                    if [[ "${logcnt}" -ge "20" ]]; then
                        cntcolor='\033[38;5;161m';
                    fi
                    if [[ "${logcnt}" -ge "50" ]]; then
                        cntcolor='\033[38;5;160m';
                    fi
                    logsearch=$(echo "${line}" | sed -E 's/^[ \t]{0,30}[0-9]{1,10}[ \t]{0,30}//g; s/^[\t \-]{1,30}//g')
                    #echo "line [${line}]"
                    #echo "logsearch [${logsearch}]"
                    echo -ne "    [${cntcolor}${logcnt}${NC}] "
                    output=$($log_command | grep -F "${logsearch}" | tail -1 |awk '{s=substr($0,1,512); if(length($0)>512) s=s"…"; print s}' | sed -E "s#(${super_danger})#\\x1b[1;37m\\\x1b[41m\\1\\x1b[0m#Ig; t end; s#(${danger})#\\x1b[0;31m\\1\\x1b[0m#Ig; t end; s#(${warn})#\\x1b[1;33m\\1\\x1b[0m#Ig; t end; s#(${regex_trigger})#\\x1b[0;97m\\1\\x1b[0m#Ig; :end")
                    printf "%b\n" "${output}"
                done < <($log_command | grep -iE "$grep_patterns" | grep -vE "$exclude_patterns" | strip_log | sort | uniq -c | sort -nk1 | tail -"${log_tail}")
                echo -ne "\033[2K\r                                               " >&2
                echo -ne "\033[2K\r" >&2
            fi | get_log_rows | sort_by_date
        fi
    else
        # If command is not tail, check that command available in system
        command=$(echo "${log_command}" | awk '{print $1}')
        if type "$command" > /dev/null 2>&1; then #check command available
            current_line=0
            echo -e "\n${bg_bright_black}\033[38;5;253mАнализ ${log_name}:${NC}"
            if [[ -n $filter_command ]]; then
                while IFS= read -r line; do
                    ((current_line++))  
                    percent=$(( 100 * current_line / log_tail ))
                    echo -ne "\033[2K\rОбработка ${log_name}: $percent%" >&2
                    logcnt=$(echo "${line}" | awk '{print $1}')
                    cntcolor="\033[38;5;244m";
                    if [[ "${logcnt}" -ge "3" ]]; then
                        cntcolor='\033[38;5;172m';
                    fi
                    if [[ "${logcnt}" -ge "10" ]]; then
                        cntcolor='\033[38;5;166m';
                    fi
                    if [[ "${logcnt}" -ge "20" ]]; then
                        cntcolor='\033[38;5;161m';
                    fi
                    if [[ "${logcnt}" -ge "50" ]]; then
                        cntcolor='\033[38;5;160m';
                    fi
                    logsearch=$(echo "${line}" | sed -E 's/^[ \t]{0,30}[0-9]{1,10}[ \t]{0,30}//g; s/^[\t \-]{1,30}//g')
                    #echo "line [${line}]"
                    #echo "logsearch [${logsearch}]"
                    echo -ne "    [${cntcolor}${logcnt}${NC}] "
                    output=$($log_command | grep -F "${logsearch}" | tail -1 |awk '{s=substr($0,1,512); if(length($0)>512) s=s"…"; print s}' | sed -E "s#(${super_danger})#\\x1b[1;37m\\\x1b[41m\\1\\x1b[0m#Ig; t end; s#(${danger})#\\x1b[0;31m\\1\\x1b[0m#Ig; t end; s#(${warn})#\\x1b[1;33m\\1\\x1b[0m#Ig; t end; s#(${regex_trigger})#\\x1b[0;97m\\1\\x1b[0m#Ig; :end")
                    printf "%b\n" "${output}"
                done < <(eval "$log_command | $filter_command" | tail "-${tail_depth}" | grep -iE "$grep_patterns" | grep -vE "$exclude_patterns" | strip_log | sort | uniq -c | sort -nk1 | tail -"${log_tail}")
                echo -ne "\033[2K\r                                               " >&2
                echo -ne "\033[2K\r" >&2
            else
                while IFS= read -r line; do
                    ((current_line++))  
                    percent=$(( 100 * current_line / log_tail ))
                    echo -ne "\033[2K\rОбработка ${log_name}: $percent%" >&2
                    logcnt=$(echo "${line}" | awk '{print $1}')
                    cntcolor="\033[38;5;244m";
                    if [[ "${logcnt}" -ge "3" ]]; then
                        cntcolor='\033[38;5;172m';
                    fi
                    if [[ "${logcnt}" -ge "10" ]]; then
                        cntcolor='\033[38;5;166m';
                    fi
                    if [[ "${logcnt}" -ge "20" ]]; then
                        cntcolor='\033[38;5;161m';
                    fi
                    if [[ "${logcnt}" -ge "50" ]]; then
                        cntcolor='\033[38;5;160m';
                    fi
                    logsearch=$(echo "${line}" | sed -E 's/^[ \t]{0,30}[0-9]{1,10}[ \t]{0,30}//g; s/^[\t \-]{1,30}//g')
                    #echo "line [${line}]"
                    #echo "logsearch [${logsearch}]"
                    echo -ne "    [${cntcolor}${logcnt}${NC}] "
                    output=$($log_command | grep -F "${logsearch}" | tail -1 |awk '{s=substr($0,1,512); if(length($0)>512) s=s"…"; print s}' | sed -E "s#(${super_danger})#\\x1b[1;37m\\\x1b[41m\\1\\x1b[0m#Ig; t end; s#(${danger})#\\x1b[0;31m\\1\\x1b[0m#Ig; t end; s#(${warn})#\\x1b[1;33m\\1\\x1b[0m#Ig; t end; s#(${regex_trigger})#\\x1b[0;97m\\1\\x1b[0m#Ig; :end")
                    printf "%b\n" "${output}"
                done < <($log_command | tail "-${tail_depth}" | grep -iE "$grep_patterns" | grep -vE "$exclude_patterns" | strip_log | sort | uniq -c | sort -nk1 | tail -"${log_tail}")
                echo -ne "\033[2K\r                                               " >&2
                echo -ne "\033[2K\r" >&2
            fi | get_log_rows | sort_by_date
        fi
    fi
}

tail_small_depth=$(( tail_depth / 4 ))

# Check logs
analyze_log "syslog" "tail -${tail_depth} /var/log/syslog" "grep -vE 'auth failed|no auth attempts'"
analyze_log "journalctl" "journalctl -n ${tail_depth}"
analyze_log "dmesg" "dmesg -T" "grep -vE 'Possible SYN flooding'"
analyze_log "kern.log" "tail -${tail_depth} /var/log/kern.log"
analyze_log "rsyslog" "tail -${tail_depth} /var/log/rsyslog"
analyze_log "messages" "tail -${tail_depth} /var/log/messages"
analyze_log "apache2 error.log" "tail -${tail_depth} /var/log/apache2/error.log"
analyze_log "apache2 error_log" "tail -${tail_depth} /var/log/apache2/error_log"
analyze_log "httpd error.log" "tail -${tail_depth} /var/log/httpd/error.log"
analyze_log "httpd error_log" "tail -${tail_depth} /var/log/httpd/error_log"
analyze_log "nginx error.log" "tail -${tail_depth} /var/log/nginx/error.log" "grep -v '13: Permission denied'"
analyze_log "nginx error.log" "tail -${tail_depth} /var/log/nginx/error_log" "grep -v '13: Permission denied'"
analyze_log "daemon.log" "tail -${tail_small_depth} /var/log/daemon.log"
analyze_log "FASTPANEL fast.log" "tail -${tail_small_depth} /var/log/fastpanel2/fast.log"
analyze_log "FASTPANEL backup.log" "tail -${tail_small_depth} /var/log/fastpanel2/backup.log"

for tl in /var/log/php*fpm.log; do 
    analyze_log "${tl##*/}" "tail -${tail_small_depth} ${tl}"
done

analyze_log "TESTLOG" "tail -${tail_small_depth} tests/testlog"
echo -e "${DARK_GREEN}Готово.${NC}"

# Красивое завершение
echo -e "\n${DARK_GRAY}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Создано Vladislav Pavlovich для технической поддержки${NC}"
echo -e "${DARK_GRAY}═══════════════════════════════════════════════════════════════${NC}\n"

#esdfulldwnldok
