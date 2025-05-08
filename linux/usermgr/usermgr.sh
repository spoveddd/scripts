#!/bin/bash
# Скрипт управления пользователями для Linux
# Создан spoveddd

# Переменные окружения
# ---------------------------------------------------\
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
SCRIPT_PATH=$(cd `dirname "${BASH_SOURCE[0]}"` && pwd)
cd $SCRIPT_PATH

# Переменные
# ---------------------------------------------------\
ME=`basename "$0"`
BACKUPS=$SCRIPT_PATH/backups
SERVER_NAME=`hostname`
SERVER_IP=`hostname -I | cut -d' ' -f1`
LOG=$SCRIPT_PATH/actions.log
DISTRO_UNAME=`uname`

# Форматирование вывода
# ---------------------------------------------------\
RED='\033[0;91m'
GREEN='\033[0;92m'
CYAN='\033[0;96m'
YELLOW='\033[0;93m'
PURPLE='\033[0;95m'
BLUE='\033[0;94m'
BOLD='\033[1m'
WHiTE="\e[1;37m"
NC='\033[0m'

ON_SUCCESS="ГОТОВО"
ON_FAIL="ОШИБКА"
ON_ERROR="Упс"
ON_CHECK="✓"

# Определение группы для админов в зависимости от дистрибутива
ADMIN_GROUP="sudo"  # По умолчанию для Debian/Ubuntu

Info() {
  echo -en "[${1}] ${GREEN}${2}${NC}\n"
}

Warn() {
  echo -en "[${1}] ${PURPLE}${2}${NC}\n"
}

Success() {
  echo -en "[${1}] ${GREEN}${2}${NC}\n"
}

Error () {
  echo -en "[${1}] ${RED}${2}${NC}\n"
}

Splash() {
  echo -en "${WHiTE} ${1}${NC}\n"
}

space() { 
  echo -e ""
}


# Функции
# ---------------------------------------------------\

logthis() {
    echo "$(date): $(whoami) - $@" >> "$LOG"
    # "$@" 2>> "$LOG"
}

isRoot() {
    if [ $(id -u) -ne 0 ]; then
        Error "Ошибка" "Вы должны быть пользователем root для продолжения"
        exit 1
    fi
    RID=$(id -u root 2>/dev/null)
    if [ $? -ne 0 ]; then
        Error "Ошибка" "Пользователь root не найден. Необходимо создать его для продолжения"
        exit 1
    fi
    if [ $RID -ne 0 ]; then
        Error "Ошибка" "UID пользователя root не равен 0. Пользователь root должен иметь UID 0"
        exit 1
    fi
}

# Проверка поддерживаемых дистрибутивов
checkDistro() {
    # Проверка дистрибутива
    if [ -e /etc/centos-release ]; then
        DISTRO=`cat /etc/redhat-release | awk '{print $1,$4}'`
        RPM=1
        ADMIN_GROUP="wheel"
    elif [ -e /etc/fedora-release ]; then
        DISTRO=`cat /etc/fedora-release | awk '{print ($1,$3~/^[0-9]/?$3:$4)}'`
        RPM=2
        ADMIN_GROUP="wheel"
    elif [ -e /etc/os-release ]; then
        DISTRO=`lsb_release -d | awk -F"\t" '{print $2}'`
        RPM=0
        DEB=1
        ADMIN_GROUP="sudo"
    fi

    if [[ "$DISTRO_UNAME" == 'Linux' ]]; then
        _LINUX=1
        Warn "Информация о сервере" "${SERVER_NAME} ${SERVER_IP} (${DISTRO}"
    else
        _LINUX=0
        Error "Ошибка" "Ваш дистрибутив пока не поддерживается"
    fi
}

# Подтверждение Да / Нет - поддерживает и английские и русские варианты
confirm() {
    # вызывается с запросом или использует значение по умолчанию
    read -r -p "${1:-Вы уверены? [y/д/N/н]} " response
    case "$response" in
        [дД][аА]|[дД]|[yY][eE][sS]|[yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

check_bkp_folder() {
    if [[ ! -d "$BACKUPS" ]]; then
        mkdir -p $BACKUPS
    fi
}

gen_pass() {
  local l=$1
  [ "$l" == "" ] && l=9
  tr -dc A-Za-z0-9 < /dev/urandom | head -c ${l} | xargs
}

create_user() {
    space
    read -p "Введите имя пользователя: " user

    if id -u "$user" >/dev/null 2>&1; then
        Error "Ошибка" "Пользователь $user уже существует. Попробуйте другое имя."
    else
        Info "Информация" "Пользователь $user будет создан..."

        local pass=$(gen_pass)
        
        # Создаем пользователя
        useradd -m -s /bin/bash ${user}
        
        if confirm "Сделать пользователя администратором? (y/д/n/н или Enter для н)"; then
            # Проверяем существование группы
            if ! getent group $ADMIN_GROUP >/dev/null; then
                # Если группы нет, создаем её
                groupadd $ADMIN_GROUP
                Info "Информация" "Создана группа $ADMIN_GROUP"
            fi
            
            # Добавляем пользователя в группу админов
            usermod -aG $ADMIN_GROUP ${user}
            
            # Создаем sudoers файл для пользователя
            echo "$user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$user
            chmod 440 /etc/sudoers.d/$user
        fi

        # установка пароля
        echo "$user:$pass" | chpasswd

        Info "Информация" "Пользователь создан. Имя: $user. Пароль: $pass"
        logthis "Пользователь создан. Имя: $user. Пароль: $pass"

    fi
    space
}

list_users() {
    space
    Info "Информация" "Список пользователей с /bin/bash: "
    users=$(awk -F: '$7=="/bin/bash" { print $1}' /etc/passwd)
    for user in $users
    do
        echo "Пользователь: $user , $(id $user | cut -d " " -f 1)"
    done
    root_info=$(cat /etc/passwd | grep root)
    Info "Информация о root" "${root_info}"
    space
}

reset_password() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if id $user >/dev/null 2>&1
        then
            
            if confirm "Сгенерировать пароль автоматически? (y/д/n/н или Enter для н)"; then
                local pass=$(gen_pass)
                echo "$user:$pass" | chpasswd
                Info "Информация" "Пароль изменен. Имя: $user. Пароль: $pass"
                logthis "Пароль изменен. Имя: $user. Пароль: $pass"
            else
                read -p "Введите пароль: " password
                echo "$user:$password" | chpasswd
                Info "Информация" "Пароль изменен. Имя: $user. Пароль: $password"
                logthis "Пароль изменен. Имя: $user. Пароль: $password"
            fi
            space
            return 0
        else
            Error "Ошибка" "Пользователь $user не найден!"
            space
        fi
    done
}

lock_user() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if [ -z $user ]
        then
            Error "Ошибка" "Имя пользователя не может быть пустым"
        else
            if id $user >/dev/null 2>&1
            then
                passwd -l $user
                Info "Информация" "Пользователь $user заблокирован"
                logthis "Пользователь $user заблокирован"
                space
                return 0
            else
                Error "Ошибка" "Пользователь $user не найден!"
                space
            fi
        fi
    done
}

unlock_user() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if [ -z $user ]
        then
            Error "Ошибка" "Имя пользователя не может быть пустым"
        else
            if id $user >/dev/null 2>&1
            then

                local locked=$(cat /etc/shadow | grep $user | grep !)

                if [[ -z $locked ]]; then
                    Info "Информация" "Пользователь $user не заблокирован"
                else
                    passwd -u $user
                    Info "Информация" "Пользователь $user разблокирован"
                    logthis "Пользователь $user разблокирован"
                fi
                space
                return 0
            else
                Error "Ошибка" "Пользователь $user не найден!"
                space
            fi
        fi
    done
}

list_locked_users() {
    space
    Info "Информация" "Заблокированные пользователи:"
    cat /etc/shadow | grep '!'
    space
}

backup_user() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if [ -z $user ]
        then
            Error "Ошибка" "Имя пользователя не может быть пустым"
        else
            if id $user >/dev/null 2>&1
            then
                check_bkp_folder
                homedir=$(grep ${user}: /etc/passwd | cut -d ":" -f 6)
                Info "Информация" "Домашний каталог для $user: $homedir "
                Info "Информация" "Создание резервной копии..."
                ts=$(date +%F)
                tar -zcvf $BACKUPS/${user}-${ts}.tar.gz $homedir
                Info "Информация" "Резервная копия для $user создана с именем ${user}-${ts}.tar.gz"
                space
                return 0
            else
                Error "Ошибка" "Пользователь $user не найден!"
                space
                return 1
            fi
        fi
    done
}

generate_ssh_key() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if [ -z $user ]
        then
            Error "Ошибка" "Имя пользователя не может быть пустым"
        else
            if id $user >/dev/null 2>&1
            then
                local sshf="/home/$user/.ssh"
                if [[ ! -d "$sshf" ]]; then
                    mkdir -p $sshf
                    chown $user:$user $sshf
                    chmod 700 $sshf
                fi

                su - $user -c "ssh-keygen -t rsa -b 4096 -C '${user}@local' -f ~/.ssh/id_rsa_${user} -N ''"
                space
                Info "Информация" "Публичный ключ пользователя:"
                space
                su - $user -c "cat ~/.ssh/id_rsa_${user}.pub" 
                space
                logthis "Для пользователя $user создан SSH-ключ - id_rsa_$user"
                return 0
            else
                Error "Ошибка" "Пользователь $user не найден!"
                space
                return 1
            fi
        fi
    done
}

delete_user() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if [ -z $user ]
        then
            Error "Ошибка" "Имя пользователя не может быть пустым"
        else
            if id $user >/dev/null 2>&1
            then
                
                if confirm "Полностью удалить пользователя (y/д/n/н или Enter для н)"; then
                    userdel -r -f $user
                    if [[ -f /etc/sudoers.d/$user ]]; then
                        yes | rm -r /etc/sudoers.d/$user
                    fi
                    
                    Info "Информация" "Пользователь $user удален"
                    space
                fi
                return 0
            else
                Error "Ошибка" "Пользователь $user не найден!"
                space
                return 1
            fi
        fi
    done
}

promote_user() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if [ -z $user ]
        then
            Error "Ошибка" "Имя пользователя не может быть пустым"
        else
            if id $user >/dev/null 2>&1
            then
                
                if id $user | grep -q "$ADMIN_GROUP" 
                then
                    Info "Информация" "Пользователь уже входит в группу $ADMIN_GROUP"
                    space
                else
                    # Проверяем существование группы
                    if ! getent group $ADMIN_GROUP >/dev/null; then
                        # Если группы нет, создаем её
                        groupadd $ADMIN_GROUP
                        Info "Информация" "Создана группа $ADMIN_GROUP"
                    fi
                    
                    usermod -aG $ADMIN_GROUP $user
                    echo "$user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$user
                    chmod 440 /etc/sudoers.d/$user
                    logthis "Пользователь $user повышен до $ADMIN_GROUP"
                    Info "Информация" "Пользователь добавлен в группу $ADMIN_GROUP"
                    space
                fi
                return 0
            else
                Error "Ошибка" "Пользователь $user не найден!"
                space
                return 1
            fi
        fi
    done
}

degrate_user() {
    space
    while :
    do
        read -p "Введите имя пользователя: " user
        if [ -z $user ]
        then
            Error "Ошибка" "Имя пользователя не может быть пустым"
        else
            if id $user >/dev/null 2>&1
            then
                
                if id $user | grep -q "$ADMIN_GROUP"
                then
                    Info "Информация" "Пользователь входит в группу $ADMIN_GROUP. Понижение прав..."
                    gpasswd -d $user $ADMIN_GROUP
                    if [[ -f /etc/sudoers.d/$user ]]; then
                        yes | rm -r /etc/sudoers.d/$user
                    fi
                    space
                else
                    Info "Информация" "Пользователь не входит в группу $ADMIN_GROUP"
                    space
                fi
                return 0
            else
                Error "Ошибка" "Пользователь $user не найден!"
                space
                return 1
            fi
        fi
    done
}

# Действия
# ---------------------------------------------------\
isRoot
checkDistro

# Меню пользователя
  while true
    do
        PS3='Выберите действие: '
        options=(
        "Создать нового пользователя"
        "Список пользователей"
        "Сбросить пароль пользователя"
        "Заблокировать пользователя"
        "Разблокировать пользователя"
        "Показать заблокированных пользователей"
        "Сделать резервную копию пользователя"
        "Сгенерировать SSH-ключ для пользователя"
        "Повысить пользователя до администратора"
        "Понизить администратора до обычного пользователя"
        "Удалить пользователя"
        "Выход"
        )
        select opt in "${options[@]}"
        do
         case $opt in
            "Создать нового пользователя")
                create_user
                break
                ;;
            "Список пользователей")
                list_users
                break
                ;;
            "Сбросить пароль пользователя")
                reset_password
                break
                ;;
            "Заблокировать пользователя")
                lock_user
                break
                ;;
            "Разблокировать пользователя")
                unlock_user
                break
                ;;
            "Показать заблокированных пользователей")
                list_locked_users
                break
                ;;
            "Сделать резервную копию пользователя")
                backup_user
                break
                ;;
            "Сгенерировать SSH-ключ для пользователя")
                generate_ssh_key
                break
                ;;     
            "Удалить пользователя")
                delete_user
                break
                ;;
            "Повысить пользователя до администратора")
                 promote_user
                 break
             ;;
            "Понизить администратора до обычного пользователя")
                 degrate_user
                 break
            ;;
            "Выход")
                 Info "Выход" "До свидания"
                 exit
             ;;
            *) echo "Неверный вариант";;
         esac
    done
   done