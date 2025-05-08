#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
ServerRescue Pro - Продвинутый диагностический инструмент для Linux серверов
Автор: На основе оригинального скрипта Владислава Павловича
"""

import os
import sys
import time
import signal
import logging
import argparse
import subprocess
import platform
import json
import socket
import pwd
import datetime
import re
import curses
import shutil
from pathlib import Path
from typing import Dict, List, Tuple, Any, Optional, Union, Set

# Пробуем импортировать опциональные зависимости, но не прерываемся при их отсутствии
try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False

try:
    import distro
    DISTRO_AVAILABLE = True
except ImportError:
    DISTRO_AVAILABLE = False

# --------- Версия ---------
VERSION = "2.1.5"

# --------- Константы ---------
# Пороговые значения для предупреждений и проблем
CPU_WARNING_THRESHOLD = 85  # Порог использования CPU в процентах
MEMORY_WARNING_THRESHOLD = 85  # Порог использования памяти в процентах
DISK_WARNING_THRESHOLD = 85  # Порог заполнения диска в процентах
LOAD_FACTOR = 1.5  # Фактор для определения высокой нагрузки (кол-во ядер * LOAD_FACTOR)
INODE_WARNING_THRESHOLD = 85  # Порог использования inode в процентах
ZOMBIE_PROCESS_THRESHOLD = 10  # Максимальное допустимое количество зомби-процессов
HIGH_IO_WAIT_THRESHOLD = 15  # Порог ожидания ввода-вывода в процентах
HIGH_NETWORK_THRESHOLD = 80  # Порог использования сети в процентах
HIGH_CONTEXT_SWITCH_THRESHOLD = 100000  # Порог контекстных переключений в секунду
HIGH_INTERRUPTS_THRESHOLD = 10000  # Порог прерываний в секунду

# Определение цветов для вывода в терминал
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'
    WHITE = '\033[97m'
    BLACK_BG = '\033[40m'
    BLUE_BG = '\033[44m'
    CYAN = '\033[96m'

KNOWN_PORTS = {
    21: "FTP",
    22: "SSH",
    25: "SMTP",
    53: "DNS",
    80: "HTTP",
    110: "POP3",
    123: "NTP",
    143: "IMAP",
    443: "HTTPS",
    465: "SMTPS",
    587: "SMTP",
    993: "IMAPS",
    995: "POP3S",
    3306: "MySQL",
    5432: "PostgreSQL",
    6379: "Redis",
    8080: "HTTP-Alt",
    8443: "HTTPS-Alt",
    9000: "PHP-FPM",
    9090: "Prometheus",
    27017: "MongoDB"
}


# --------- Глобальные переменные ---------
# Хранилище для проблем и рекомендаций
issues = []  # Список обнаруженных проблем
warnings = []  # Список предупреждений
suggestions = []  # Список рекомендаций
log_samples = {}  # Примеры ошибок из логов
service_status = {}  # Статусы сервисов
service_descriptions = {}  # Описания сервисов
fixes_applied = []  # Примененные исправления

# Диагностические данные
system_info = {}  # Информация о системе
cpu_info = {}  # Информация о процессоре
memory_info = {}  # Информация о памяти
disk_info = {}  # Информация о дисках
network_info = {}  # Информация о сети
process_info = {}  # Информация о процессах

# Флаги
fix_enabled = False  # Включено ли автоматическое исправление
verbose_mode = False  # Режим подробного вывода
skip_menu = False  # Пропустить меню

# --------- Утилитарные функции ---------
class Logger:
    """Класс для логирования с поддержкой файлового и консольного вывода."""
    
    def __init__(self, log_file="serverrescue.log", verbose=False):
        self.verbose = verbose
        self.log_file = log_file
        
        # Настройка файлового логирования
        logging.basicConfig(
            filename=log_file,
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        
        # Создаем обработчик для вывода в консоль в режиме verbose
        if self.verbose:
            console = logging.StreamHandler()
            console.setLevel(logging.INFO)
            formatter = logging.Formatter('%(levelname)s - %(message)s')
            console.setFormatter(formatter)
            logging.getLogger('').addHandler(console)
    
    def info(self, message):
        """Логировать информационное сообщение."""
        logging.info(message)
    
    def warning(self, message):
        """Логировать предупреждение."""
        logging.warning(message)
    
    def error(self, message):
        """Логировать ошибку."""
        logging.error(message)
    
    def debug(self, message):
        """Логировать отладочную информацию."""
        logging.debug(message)

# Инициализация логгера (будет правильно установлен в главной функции)
logger = Logger()

def is_root():
    """Проверка запуска скрипта с правами root."""
    return os.geteuid() == 0

def which(program):
    """Проверка наличия программы в PATH."""
    def is_exe(fpath):
        return os.path.isfile(fpath) and os.access(fpath, os.X_OK)

    fpath, _ = os.path.split(program)
    if fpath:
        if is_exe(program):
            return program
    else:
        for path in os.environ["PATH"].split(os.pathsep):
            exe_file = os.path.join(path, program)
            if is_exe(exe_file):
                return exe_file
    return None

def run_command(command, shell=False, timeout=30):
    """Выполнить системную команду и вернуть вывод или None при ошибке."""
    try:
        if shell:
            output = subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT, timeout=timeout)
        else:
            output = subprocess.check_output(command.split(), stderr=subprocess.STDOUT, timeout=timeout)
        return output.decode('utf-8', errors='replace')
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
        logger.error(f"Ошибка выполнения команды '{command}': {e}")
        return None

def add_issue(issue):
    """Добавить проблему в список."""
    issues.append(issue)
    logger.info(f"Обнаружена проблема: {issue}")

def add_warning(warning):
    """Добавить предупреждение в список."""
    warnings.append(warning)
    logger.warning(f"Предупреждение: {warning}")

def add_suggestion(suggestion):
    """Добавить рекомендацию в список."""
    suggestions.append(suggestion)
    logger.info(f"Добавлена рекомендация: {suggestion}")

def bytes_to_human(bytes_value):
    """Преобразовать байты в читаемый формат (КБ, МБ, ГБ)."""
    if not isinstance(bytes_value, (int, float)):
        return "?"
    
    for unit in ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']:
        if bytes_value < 1024:
            return f"{bytes_value:.2f} {unit}"
        bytes_value /= 1024
    return f"{bytes_value:.2f} ПБ"

def print_colored(text, color):
    """Вывести цветной текст в терминал."""
    return f"{color}{text}{Colors.ENDC}"

def print_header(title):
    """Вывести форматированный заголовок для секции."""
    try:
        width = shutil.get_terminal_size().columns
    except:
        width = 80
    
    padding = (width - len(title) - 4) // 2
    padding = max(0, padding)
    
    header_line = "=" * padding
    header_line += f" {title} "
    header_line += "=" * padding
    
    # Убедимся, что строка заполняет всю ширину терминала
    while len(header_line) < width:
        header_line += "="
    
    print(f"\n{print_colored(header_line, Colors.BOLD + Colors.BLUE)}")

def clear_screen():
    """Очистить экран терминала."""
    os.system('cls' if os.name == 'nt' else 'clear')

# --------- Функции диагностики системы ---------
def get_basic_info():
    """Собрать основную информацию о системе."""
    global system_info
    
    system_info['hostname'] = socket.gethostname()
    
    try:
        system_info['ip_address'] = get_external_ip()
    except socket.gaierror:
        system_info['ip_address'] = "Н/Д"
    
    # Получение информации о дистрибутиве
    if DISTRO_AVAILABLE:
        system_info['distro'] = f"{distro.name()} {distro.version()}"
    else:
        if os.path.exists('/etc/os-release'):
            with open('/etc/os-release', 'r') as f:
                os_release = {}
                for line in f:
                    if '=' in line:
                        key, value = line.rstrip().split('=', 1)
                        os_release[key] = value.strip('"')
            system_info['distro'] = f"{os_release.get('NAME', 'Неизвестно')} {os_release.get('VERSION', '')}"
        else:
            system_info['distro'] = platform.platform()
    
    system_info['kernel'] = platform.release()
    
    # Получение аптайма
    if os.path.exists('/proc/uptime'):
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
        uptime_days = int(uptime_seconds // 86400)
        uptime_hours = int((uptime_seconds % 86400) // 3600)
        uptime_minutes = int((uptime_seconds % 3600) // 60)
        system_info['uptime'] = f"{uptime_days} дней, {uptime_hours} часов, {uptime_minutes} минут"
    else:
        system_info['uptime'] = "Н/Д"
    
    # Получение времени последней перезагрузки
    last_reboot = run_command("last reboot -1")
    if last_reboot:
        system_info['last_reboot'] = last_reboot.strip().split('\n')[0]
    else:
        system_info['last_reboot'] = "Н/Д"
    
    logger.info("Собрана основная информация о системе")

def get_cpu_info():
    """Собрать информацию о процессоре."""
    global cpu_info
    
    # Попытка получить информацию о CPU с помощью psutil или запасными методами
    if PSUTIL_AVAILABLE:
        cpu_info['count'] = psutil.cpu_count(logical=True)
        cpu_info['physical_count'] = psutil.cpu_count(logical=False)
        
        # Использование CPU (с помощью psutil)
        cpu_usage = psutil.cpu_percent(interval=1, percpu=False)
        cpu_info['usage_percent'] = cpu_usage
        
        # Использование CPU по ядрам
        cpu_info['per_cpu_percent'] = psutil.cpu_percent(interval=0.1, percpu=True)
        
        # Времена CPU
        cpu_times = psutil.cpu_times_percent(interval=1)
        cpu_info['user'] = cpu_times.user
        cpu_info['system'] = cpu_times.system
        cpu_info['idle'] = cpu_times.idle
        cpu_info['iowait'] = getattr(cpu_times, 'iowait', 0)  # Доступно не на всех платформах
        
        # Средняя нагрузка CPU
        if hasattr(psutil, 'getloadavg'):
            cpu_info['loadavg'] = psutil.getloadavg()
        else:
            try:
                with open('/proc/loadavg', 'r') as f:
                    load = f.read().split()
                    cpu_info['loadavg'] = (float(load[0]), float(load[1]), float(load[2]))
            except:
                cpu_info['loadavg'] = (0, 0, 0)
        
        # Проверка на высокую нагрузку
        load_threshold = cpu_info['count'] * LOAD_FACTOR
        if cpu_info['loadavg'][2] > load_threshold:
            add_issue(f"Высокая нагрузка системы: {cpu_info['loadavg'][2]:.2f} (порог: {load_threshold:.2f})")
            add_suggestion("Проверьте top/htop для выявления ресурсоемких процессов")
        
        # Проверка на высокое использование CPU
        if cpu_info['usage_percent'] > CPU_WARNING_THRESHOLD:
            add_issue(f"Высокое использование CPU: {cpu_info['usage_percent']:.2f}% (порог: {CPU_WARNING_THRESHOLD}%)")
            add_suggestion("Запустите 'top -c' и проверьте процессы с наибольшим использованием CPU")
        
        # Проверка на высокий I/O wait
        if cpu_info['iowait'] > HIGH_IO_WAIT_THRESHOLD:
            add_issue(f"Высокий показатель I/O Wait: {cpu_info['iowait']:.2f}% (порог: {HIGH_IO_WAIT_THRESHOLD}%)")
            add_suggestion("Запустите 'iostat -xz 1' для выявления проблемных дисковых устройств")
    
    else:
        # Запасной метод для получения количества ядер CPU
        try:
            with open('/proc/cpuinfo', 'r') as f:
                cpu_info['count'] = sum(1 for line in f if line.startswith('processor'))
        except:
            cpu_info['count'] = 1
        
        # Запасной вариант для средней нагрузки
        try:
            with open('/proc/loadavg', 'r') as f:
                load = f.read().split()
                cpu_info['loadavg'] = (float(load[0]), float(load[1]), float(load[2]))
        except:
            cpu_info['loadavg'] = (0, 0, 0)
        
        # Получение использования CPU с помощью top (запасной вариант)
        top_output = run_command("top -bn1 | grep '^%Cpu'")
        if top_output:
            try:
                cpu_parts = re.findall(r'(\d+\.\d+)\s+\w+', top_output)
                if len(cpu_parts) >= 4:
                    cpu_info['user'] = float(cpu_parts[0])
                    cpu_info['system'] = float(cpu_parts[1])
                    cpu_info['idle'] = float(cpu_parts[3])
                    cpu_info['iowait'] = float(cpu_parts[4]) if len(cpu_parts) > 4 else 0
                    
                    cpu_info['usage_percent'] = 100.0 - cpu_info['idle']
                    
                    # Проверка на высокое использование CPU
                    if cpu_info['usage_percent'] > CPU_WARNING_THRESHOLD:
                        add_issue(f"Высокое использование CPU: {cpu_info['usage_percent']:.2f}% (порог: {CPU_WARNING_THRESHOLD}%)")
                        add_suggestion("Запустите 'top -c' и проверьте процессы с наибольшим использованием CPU")
                    
                    # Проверка на высокий I/O wait
                    if cpu_info['iowait'] > HIGH_IO_WAIT_THRESHOLD:
                        add_issue(f"Высокий показатель I/O Wait: {cpu_info['iowait']:.2f}% (порог: {HIGH_IO_WAIT_THRESHOLD}%)")
                        add_suggestion("Запустите 'iostat -xz 1' для выявления проблемных дисковых устройств")
            except:
                cpu_info['user'] = 0
                cpu_info['system'] = 0
                cpu_info['idle'] = 100
                cpu_info['iowait'] = 0
                cpu_info['usage_percent'] = 0
        else:
            cpu_info['user'] = 0
            cpu_info['system'] = 0
            cpu_info['idle'] = 100
            cpu_info['iowait'] = 0
            cpu_info['usage_percent'] = 0
        
        # Получение информации о CPU по ядрам
        cpu_info['per_cpu_percent'] = []
        
        # Проверка на высокую нагрузку
        load_threshold = cpu_info['count'] * LOAD_FACTOR
        if cpu_info['loadavg'][2] > load_threshold:
            add_issue(f"Высокая нагрузка системы: {cpu_info['loadavg'][2]:.2f} (порог: {load_threshold:.2f})")
            add_suggestion("Проверьте top/htop для выявления ресурсоемких процессов")
    
    # Получение информации о модели CPU
    if os.path.exists('/proc/cpuinfo'):
        with open('/proc/cpuinfo', 'r') as f:
            for line in f:
                if line.startswith('model name'):
                    cpu_info['model'] = line.split(':')[1].strip()
                    break
            else:
                cpu_info['model'] = "Неизвестно"
    else:
        cpu_info['model'] = "Неизвестно"
    
    # Получение информации о контекстных переключениях и прерываниях
    if os.path.exists('/proc/stat'):
        try:
            with open('/proc/stat', 'r') as f:
                for line in f:
                    if line.startswith('ctxt '):
                        cpu_info['context_switches'] = int(line.split()[1])
                    elif line.startswith('intr '):
                        cpu_info['interrupts'] = int(line.split()[1])
        except:
            cpu_info['context_switches'] = 0
            cpu_info['interrupts'] = 0
    
    logger.info(f"Собрана информация о CPU: {cpu_info['count']} ядер, загрузка {cpu_info['usage_percent']:.2f}%")

def get_memory_info():
    """Собрать информацию об использовании памяти."""
    global memory_info
    
    # Попытка получить информацию о памяти с помощью psutil
    if PSUTIL_AVAILABLE:
        mem = psutil.virtual_memory()
        swap = psutil.swap_memory()
        
        memory_info['total'] = mem.total
        memory_info['used'] = mem.used
        memory_info['free'] = mem.free
        memory_info['percent'] = mem.percent
        
        memory_info['swap_total'] = swap.total
        memory_info['swap_used'] = swap.used
        memory_info['swap_free'] = swap.free
        memory_info['swap_percent'] = swap.percent
        
        # Кэшированная память (специфично для Linux)
        memory_info['cached'] = getattr(mem, 'cached', 0)
        memory_info['buffers'] = getattr(mem, 'buffers', 0)
        
        # Проверка на высокое использование памяти
        if memory_info['percent'] > MEMORY_WARNING_THRESHOLD:
            add_issue(f"Высокое использование памяти: {memory_info['percent']:.2f}% (порог: {MEMORY_WARNING_THRESHOLD}%)")
            add_suggestion("Запустите 'ps aux --sort=-%mem | head' для определения процессов, потребляющих наибольшее количество памяти")
        
        # Проверка на высокое использование swap
        if memory_info['swap_total'] > 0 and memory_info['swap_percent'] > 50:
            add_issue(f"Высокое использование SWAP: {memory_info['swap_used'] / (1024*1024):.2f}МБ из {memory_info['swap_total'] / (1024*1024):.2f}МБ ({memory_info['swap_percent']:.2f}%)")
            add_suggestion("Высокое использование SWAP может указывать на нехватку RAM. Проверьте процессы, потребляющие много памяти.")
    
    else:
        # Запасной вариант - использование /proc/meminfo
        memory_info = {
            'total': 0,
            'used': 0,
            'free': 0,
            'percent': 0,
            'swap_total': 0,
            'swap_used': 0,
            'swap_free': 0,
            'swap_percent': 0,
            'cached': 0,
            'buffers': 0
        }
        
        if os.path.exists('/proc/meminfo'):
            try:
                with open('/proc/meminfo', 'r') as f:
                    meminfo = {}
                    for line in f:
                        name, var = line.split(':')
                        var = var.strip()
                        if var.endswith('kB'):
                            value = int(var.rstrip(' kB')) * 1024
                        else:
                            try:
                                value = int(var)
                            except:
                                value = 0
                        meminfo[name] = value
                
                # Расчет значений памяти
                memory_info['total'] = meminfo.get('MemTotal', 0)
                memory_info['free'] = meminfo.get('MemFree', 0)
                memory_info['cached'] = meminfo.get('Cached', 0)
                memory_info['buffers'] = meminfo.get('Buffers', 0)
                
                # Доступная память (Linux 3.14+)
                if 'MemAvailable' in meminfo:
                    memory_info['available'] = meminfo['MemAvailable']
                    memory_info['used'] = memory_info['total'] - memory_info['available']
                else:
                    # Оценка доступной памяти
                    memory_info['used'] = memory_info['total'] - memory_info['free'] - memory_info['cached'] - memory_info['buffers']
                    memory_info['available'] = memory_info['free'] + memory_info['cached'] + memory_info['buffers']
                
                # Расчет процента использования
                memory_info['percent'] = (memory_info['used'] / memory_info['total']) * 100 if memory_info['total'] > 0 else 0
                
                # Информация о swap
                memory_info['swap_total'] = meminfo.get('SwapTotal', 0)
                memory_info['swap_free'] = meminfo.get('SwapFree', 0)
                memory_info['swap_used'] = memory_info['swap_total'] - memory_info['swap_free']
                memory_info['swap_percent'] = (memory_info['swap_used'] / memory_info['swap_total']) * 100 if memory_info['swap_total'] > 0 else 0
                
                # Проверка на высокое использование памяти
                if memory_info['percent'] > MEMORY_WARNING_THRESHOLD:
                    add_issue(f"Высокое использование памяти: {memory_info['percent']:.2f}% (порог: {MEMORY_WARNING_THRESHOLD}%)")
                    add_suggestion("Запустите 'ps aux --sort=-%mem | head' для определения процессов, потребляющих наибольшее количество памяти")
                
                # Проверка на высокое использование swap
                if memory_info['swap_total'] > 0 and memory_info['swap_percent'] > 50:
                    add_issue(f"Высокое использование SWAP: {memory_info['swap_used'] / (1024*1024):.2f}МБ из {memory_info['swap_total'] / (1024*1024):.2f}МБ ({memory_info['swap_percent']:.2f}%)")
                    add_suggestion("Высокое использование SWAP может указывать на нехватку RAM. Проверьте процессы, потребляющие много памяти.")
            
            except Exception as e:
                logger.error(f"Ошибка при обработке информации о памяти: {e}")
                add_warning("Не удалось обработать информацию о памяти из /proc/meminfo")
        
        else:
            # Последний вариант - используем команду free
            free_output = run_command("free -b")
            if free_output:
                lines = free_output.strip().split('\n')
                if len(lines) >= 2:
                    mem_line = lines[1].split()
                    if len(mem_line) >= 7:
                        memory_info['total'] = int(mem_line[1])
                        memory_info['used'] = int(mem_line[2])
                        memory_info['free'] = int(mem_line[3])
                        memory_info['cached'] = int(mem_line[5]) + int(mem_line[6])
                        memory_info['percent'] = (memory_info['used'] / memory_info['total']) * 100 if memory_info['total'] > 0 else 0
                
                if len(lines) >= 3:
                    swap_line = lines[2].split()
                    if len(swap_line) >= 4:
                        memory_info['swap_total'] = int(swap_line[1])
                        memory_info['swap_used'] = int(swap_line[2])
                        memory_info['swap_free'] = int(swap_line[3])
                        memory_info['swap_percent'] = (memory_info['swap_used'] / memory_info['swap_total']) * 100 if memory_info['swap_total'] > 0 else 0
            else:
                add_warning("Не удалось определить использование памяти. Ни psutil, ни /proc/meminfo, ни команда free не доступны.")
    
    logger.info(f"Собрана информация о памяти: использование {memory_info['percent']:.2f}%, SWAP: {memory_info['swap_percent']:.2f}%")

def get_disk_info():
    """Собрать информацию о дисковом пространстве."""
    global disk_info
    
    disk_info = {
        'partitions': [],
        'io_stats': {},
        'inodes': {}
    }
    
    # Попытка получить информацию о дисках с помощью psutil
    if PSUTIL_AVAILABLE:
        for part in psutil.disk_partitions(all=False):
            # Пропускаем сетевые файловые системы
            if part.fstype in ('nfs', 'cifs', 'smbfs', 'autofs', 'rpc_pipefs', 'tmpfs'):
                continue
            
            try:
                usage = psutil.disk_usage(part.mountpoint)
                
                partition_info = {
                    'device': part.device,
                    'mountpoint': part.mountpoint,
                    'fstype': part.fstype,
                    'total': usage.total,
                    'used': usage.used,
                    'free': usage.free,
                    'percent': usage.percent
                }
                
                disk_info['partitions'].append(partition_info)
                
                # Проверка на высокое использование диска
                if usage.percent > DISK_WARNING_THRESHOLD:
                    add_issue(f"Высокое использование диска на {part.mountpoint}: {usage.percent:.2f}% (порог: {DISK_WARNING_THRESHOLD}%)")
                    add_suggestion(f"Запустите 'du -h --max-depth=1 {part.mountpoint} | sort -hr' для выявления крупных директорий")
            
            except (PermissionError, FileNotFoundError):
                # Пропускаем разделы, к которым нет доступа
                continue
        
        # Сбор статистики ввода-вывода диска, если доступно
        if hasattr(psutil, 'disk_io_counters'):
            io_counters = psutil.disk_io_counters(perdisk=True)
            disk_info['io_stats'] = {disk: {
                'read_count': counters.read_count,
                'write_count': counters.write_count,
                'read_bytes': counters.read_bytes,
                'write_bytes': counters.write_bytes,
                'read_time': counters.read_time,
                'write_time': counters.write_time
            } for disk, counters in io_counters.items()}
    
    else:
        # Запасной вариант - используем команду df
        df_output = run_command("df -P -k")
        if df_output:
            lines = df_output.strip().split('\n')
            if len(lines) > 1:
                for line in lines[1:]:
                    parts = line.split()
                    if len(parts) >= 6:
                        device, total, used, free = parts[0], int(parts[1]), int(parts[2]), int(parts[3])
                        percent = int(parts[4].rstrip('%'))
                        mountpoint = parts[5]
                        
                        # Пропускаем псевдо-файловые системы
                        if device in ('none', 'udev', 'tmpfs', 'devtmpfs') or device.startswith('overlay'):
                            continue
                        
                        partition_info = {
                            'device': device,
                            'mountpoint': mountpoint,
                            'fstype': 'неизвестно',
                            'total': total * 1024,  # Конвертируем КБ в байты
                            'used': used * 1024,
                            'free': free * 1024,
                            'percent': percent
                        }
                        
                        disk_info['partitions'].append(partition_info)
                        
                        # Проверка на высокое использование диска
                        if percent > DISK_WARNING_THRESHOLD:
                            add_issue(f"Высокое использование диска на {mountpoint}: {percent}% (порог: {DISK_WARNING_THRESHOLD}%)")
                            add_suggestion(f"Запустите 'du -h --max-depth=1 {mountpoint} | sort -hr' для выявления крупных директорий")
        
        else:
            add_warning("Не удалось собрать информацию о дисках. Ни psutil, ни команда df не доступны.")
    
    # Проверка использования inodes (специфично для Linux)
    df_inodes_output = run_command("df -i")
    if df_inodes_output:
        lines = df_inodes_output.strip().split('\n')
        if len(lines) > 1:
            for line in lines[1:]:
                parts = line.split()
                if len(parts) >= 6:
                    device, inodes_total, inodes_used, inodes_free = parts[0], int(parts[1]), int(parts[2]), int(parts[3])
                    inodes_percent = int(parts[4].rstrip('%'))
                    mountpoint = parts[5]
                    
                    # Пропускаем псевдо-файловые системы
                    if device in ('none', 'udev', 'tmpfs', 'devtmpfs') or device.startswith('overlay'):
                        continue
                    
                    disk_info['inodes'][mountpoint] = {
                        'total': inodes_total,
                        'used': inodes_used,
                        'free': inodes_free,
                        'percent': inodes_percent
                    }
                    
                    # Проверка на высокое использование inodes
                    if inodes_percent > INODE_WARNING_THRESHOLD:
                        add_issue(f"Критическое количество файлов (inodes) на {mountpoint}: {inodes_percent}% (порог: {INODE_WARNING_THRESHOLD}%)")
                        add_suggestion(f"Запустите 'find {mountpoint} -xdev -type f | cut -d\"/\" -f2 | sort | uniq -c | sort -n' для поиска директорий с большим количеством файлов")
    
    # Получаем статистику ввода-вывода диска из /proc/diskstats, если psutil недоступен
    if not PSUTIL_AVAILABLE and os.path.exists('/proc/diskstats'):
        try:
            with open('/proc/diskstats', 'r') as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 14:
                        disk_name = parts[2]
                        
                        # Пропускаем разделы, рассматриваем только целые диски
                        if any(c.isdigit() for c in disk_name):
                            continue
                        
                        # Пропускаем ram, loop и dm устройства
                        if disk_name.startswith(('ram', 'loop', 'dm-')):
                            continue
                        
                        disk_info['io_stats'][disk_name] = {
                            'read_count': int(parts[3]),
                            'read_merged': int(parts[4]),
                            'read_sectors': int(parts[5]),
                            'read_time': int(parts[6]),
                            'write_count': int(parts[7]),
                            'write_merged': int(parts[8]),
                            'write_sectors': int(parts[9]),
                            'write_time': int(parts[10]),
                            'io_in_progress': int(parts[11]),
                            'io_time': int(parts[12]),
                            'weighted_io_time': int(parts[13])
                        }
        except Exception as e:
            logger.error(f"Ошибка при обработке статистики ввода-вывода дисков: {e}")
    
    # Подсчитываем разделы с высоким использованием
    high_usage_partitions = [p for p in disk_info['partitions'] if p['percent'] > DISK_WARNING_THRESHOLD]
    logger.info(f"Собрана информация о дисках: {len(disk_info['partitions'])} разделов, {len(high_usage_partitions)} с высоким использованием")

def get_network_info():
    """Собрать информацию о сети."""
    global network_info
    
    network_info = {
        'interfaces': {},
        'connections': {
            'ESTABLISHED': 0,
            'TIME_WAIT': 0,
            'CLOSE_WAIT': 0,
            'LISTEN': 0,
            'OTHER': 0
        },
        'open_ports': []
    }
    
    # Пытаемся получить информацию о сети с помощью psutil
    if PSUTIL_AVAILABLE:
        # Получаем статистику сетевых интерфейсов
        net_io = psutil.net_io_counters(pernic=True)
        net_addrs = psutil.net_if_addrs()
        
        for iface, counters in net_io.items():
            # Пропускаем loopback интерфейс
            if iface == 'lo':
                continue
            
            network_info['interfaces'][iface] = {
                'bytes_sent': counters.bytes_sent,
                'bytes_recv': counters.bytes_recv,
                'packets_sent': counters.packets_sent,
                'packets_recv': counters.packets_recv,
                'errin': counters.errin,
                'errout': counters.errout,
                'dropin': counters.dropin,
                'dropout': counters.dropout
            }
            
            # Добавляем адреса интерфейсов
            if iface in net_addrs:
                network_info['interfaces'][iface]['addresses'] = []
                for addr in net_addrs[iface]:
                    addr_info = {'family': str(addr.family), 'address': addr.address}
                    if hasattr(addr, 'netmask') and addr.netmask:
                        addr_info['netmask'] = addr.netmask
                    if hasattr(addr, 'broadcast') and addr.broadcast:
                        addr_info['broadcast'] = addr.broadcast
                    network_info['interfaces'][iface]['addresses'].append(addr_info)
        
        # Получаем сетевые соединения
        if hasattr(psutil, 'net_connections'):
            try:
                connections = psutil.net_connections()
                for conn in connections:
                    status = conn.status
                    if status in network_info['connections']:
                        network_info['connections'][status] += 1
                    else:
                        network_info['connections']['OTHER'] += 1
                    
                    # Собираем информацию о прослушиваемых портах
                    if status == 'LISTEN' and conn.laddr:
                        port = conn.laddr.port
                        network_info['open_ports'].append({
                            'port': port,
                            'program': psutil.Process(conn.pid).name() if conn.pid else 'Неизвестно'
                        })
            except:
                # Может не сработать без прав root
                pass
        
        # Проверка на проблемы
        if network_info['connections']['TIME_WAIT'] > 1000:
            add_issue(f"Большое количество соединений в TIME_WAIT: {network_info['connections']['TIME_WAIT']}")
            add_suggestion("Проверьте настройки TCP/IP и возможные проблемы с сетевыми приложениями")
        
        if network_info['connections']['CLOSE_WAIT'] > 100:
            add_issue(f"Большое количество соединений в CLOSE_WAIT: {network_info['connections']['CLOSE_WAIT']}")
            add_suggestion("Проверьте настройки TCP/IP и возможные проблемы с сетевыми приложениями")
    
    else:
        # Запасной вариант - используем ifconfig для сетевых интерфейсов
        ifconfig_output = run_command("ifconfig")
        if ifconfig_output:
            current_iface = None
            for line in ifconfig_output.split('\n'):
                # Новый интерфейс начинается
                if not line.startswith(' ') and len(line) > 0 and not line.startswith('\t'):
                    current_iface = line.split(':')[0].split()[0]
                    if current_iface != 'lo':
                        network_info['interfaces'][current_iface] = {
                            'bytes_sent': 0,
                            'bytes_recv': 0,
                            'packets_sent': 0,
                            'packets_recv': 0,
                            'errin': 0,
                            'errout': 0,
                            'dropin': 0,
                            'dropout': 0,
                            'addresses': []
                        }
                
                # Разбор IP-адресов
                elif current_iface and current_iface != 'lo':
                    if 'inet ' in line:
                        addr = line.split('inet ')[1].split()[0]
                        network_info['interfaces'][current_iface]['addresses'].append({
                            'family': 'AF_INET',
                            'address': addr
                        })
                    
                    elif 'inet6 ' in line:
                        addr = line.split('inet6 ')[1].split()[0]
                        network_info['interfaces'][current_iface]['addresses'].append({
                            'family': 'AF_INET6',
                            'address': addr
                        })
        else:
            # Попробуем с помощью ip addr
            ip_addr_output = run_command("ip addr")
            if ip_addr_output:
                current_iface = None
                for line in ip_addr_output.split('\n'):
                    if line.startswith(' ') and 'inet ' in line and current_iface and current_iface != 'lo':
                        addr = line.split('inet ')[1].split('/')[0]
                        network_info['interfaces'][current_iface]['addresses'].append({
                            'family': 'AF_INET',
                            'address': addr
                        })
                    elif line.startswith(' ') and 'inet6 ' in line and current_iface and current_iface != 'lo':
                        addr = line.split('inet6 ')[1].split('/')[0]
                        network_info['interfaces'][current_iface]['addresses'].append({
                            'family': 'AF_INET6',
                            'address': addr
                        })
                    elif not line.startswith(' '):
                        parts = line.split()
                        if len(parts) >= 2:
                            iface_name = parts[1].rstrip(':')
                            if iface_name != 'lo':
                                current_iface = iface_name
                                network_info['interfaces'][current_iface] = {
                                    'bytes_sent': 0,
                                    'bytes_recv': 0,
                                    'packets_sent': 0,
                                    'packets_recv': 0,
                                    'errin': 0,
                                    'errout': 0,
                                    'dropin': 0,
                                    'dropout': 0,
                                    'addresses': []
                                }
            else:
                add_warning("Не удалось получить информацию о сетевых интерфейсах")
        
        # Получаем сетевые соединения с помощью netstat или ss
        if which('ss'):
            ss_output = run_command("ss -tan")
            if ss_output:
                for line in ss_output.split('\n'):
                    if 'ESTAB' in line:
                        network_info['connections']['ESTABLISHED'] += 1
                    elif 'TIME-WAIT' in line:
                        network_info['connections']['TIME_WAIT'] += 1
                    elif 'CLOSE-WAIT' in line:
                        network_info['connections']['CLOSE_WAIT'] += 1
                    elif 'LISTEN' in line:
                        network_info['connections']['LISTEN'] += 1
        elif which('netstat'):
            netstat_output = run_command("netstat -tan")
            if netstat_output:
                for line in netstat_output.split('\n'):
                    if 'ESTABLISHED' in line:
                        network_info['connections']['ESTABLISHED'] += 1
                    elif 'TIME_WAIT' in line:
                        network_info['connections']['TIME_WAIT'] += 1
                    elif 'CLOSE_WAIT' in line:
                        network_info['connections']['CLOSE_WAIT'] += 1
                    elif 'LISTEN' in line:
                        network_info['connections']['LISTEN'] += 1
        
        # Проверка на проблемы
        if network_info['connections']['TIME_WAIT'] > 1000:
            add_issue(f"Большое количество соединений в TIME_WAIT: {network_info['connections']['TIME_WAIT']}")
            add_suggestion("Проверьте настройки TCP/IP и возможные проблемы с сетевыми приложениями")
        
        if network_info['connections']['CLOSE_WAIT'] > 100:
            add_issue(f"Большое количество соединений в CLOSE_WAIT: {network_info['connections']['CLOSE_WAIT']}")
            add_suggestion("Проверьте настройки TCP/IP и возможные проблемы с сетевыми приложениями")
        
        # Получаем открытые порты
        if which('ss'):
            open_ports_output = run_command("ss -tuln")
            if open_ports_output:
                for line in open_ports_output.split('\n'):
                    if 'LISTEN' in line:
                        parts = line.split()
                        for part in parts:
                            if ':' in part:
                                try:
                                    port = int(part.split(':')[-1])
                                    network_info['open_ports'].append({
                                        'port': port,
                                        'program': 'Неизвестно'
                                    })
                                except:
                                    pass
        elif which('netstat'):
            open_ports_output = run_command("netstat -tuln")
            if open_ports_output:
                for line in open_ports_output.split('\n'):
                    if 'LISTEN' in line:
                        parts = line.split()
                        for part in parts:
                            if ':' in part:
                                try:
                                    port = int(part.split(':')[-1])
                                    network_info['open_ports'].append({
                                        'port': port,
                                        'program': 'Неизвестно'
                                    })
                                except:
                                    pass
    
    logger.info(f"Собрана информация о сети: {len(network_info['interfaces'])} интерфейсов, {network_info['connections']['ESTABLISHED']} соединений")

def get_process_info():
    """Собрать информацию о процессах."""
    global process_info
    
    process_info = {
        'total': 0,
        'running': 0,
        'sleeping': 0,
        'stopped': 0,
        'zombie': 0,
        'top_cpu': [],
        'top_memory': []
    }
    
    # Пробуем получить информацию о процессах с помощью psutil
    if PSUTIL_AVAILABLE:
        # Получаем все процессы
        for proc in psutil.process_iter(['pid', 'name', 'username', 'status', 'cpu_percent', 'memory_percent']):
            try:
                pinfo = proc.info
                process_info['total'] += 1
                
                # Инкрементируем счетчик по статусу
                status = pinfo['status'].lower() if 'status' in pinfo else 'unknown'
                if status == 'running':
                    process_info['running'] += 1
                elif status == 'sleeping':
                    process_info['sleeping'] += 1
                elif status == 'stopped':
                    process_info['stopped'] += 1
                elif status == 'zombie':
                    process_info['zombie'] += 1
                
                # Проверка использования CPU и памяти
                if 'cpu_percent' in pinfo and 'memory_percent' in pinfo:
                    # Добавляем в топ по CPU
                    if pinfo['cpu_percent'] > 1.0:
                        process_info['top_cpu'].append({
                            'pid': pinfo['pid'],
                            'name': pinfo['name'],
                            'username': pinfo.get('username', 'неизвестно'),
                            'cpu_percent': pinfo['cpu_percent'],
                            'memory_percent': pinfo['memory_percent']
                        })
                    
                    # Добавляем в топ по памяти
                    if pinfo['memory_percent'] > 1.0:
                        process_info['top_memory'].append({
                            'pid': pinfo['pid'],
                            'name': pinfo['name'],
                            'username': pinfo.get('username', 'неизвестно'),
                            'cpu_percent': pinfo['cpu_percent'],
                            'memory_percent': pinfo['memory_percent']
                        })
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                pass
        
        # Сортируем топы по использованию ресурсов
        process_info['top_cpu'] = sorted(process_info['top_cpu'], key=lambda p: p['cpu_percent'], reverse=True)[:10]
        process_info['top_memory'] = sorted(process_info['top_memory'], key=lambda p: p['memory_percent'], reverse=True)[:10]
        
        # Проверка на зомби-процессы
        if process_info['zombie'] > ZOMBIE_PROCESS_THRESHOLD:
            add_issue(f"Обнаружено большое количество зомби-процессов: {process_info['zombie']}")
            add_suggestion("Перезапустите родительские процессы или перезагрузите сервер")
        
        # Проверка ресурсоемких процессов
        for proc in process_info['top_cpu']:
            if proc['cpu_percent'] > 90:
                add_issue(f"Процесс с PID {proc['pid']} ({proc['name']}) потребляет {proc['cpu_percent']:.2f}% CPU")
        
        for proc in process_info['top_memory']:
            if proc['memory_percent'] > 90:
                add_issue(f"Процесс с PID {proc['pid']} ({proc['name']}) потребляет {proc['memory_percent']:.2f}% RAM")
    
    else:
        # Запасной вариант - используем ps
        ps_output = run_command("ps aux")
        if ps_output:
            lines = ps_output.strip().split('\n')
            process_info['total'] = len(lines) - 1  # Вычитаем заголовок
            
            # Подсчитываем зомби-процессы
            for line in lines[1:]:  # Пропускаем заголовок
                parts = line.split()
                if len(parts) >= 8:
                    status = parts[7]
                    if status == 'Z':
                        process_info['zombie'] += 1
            
            # Проверка на зомби-процессы
            if process_info['zombie'] > ZOMBIE_PROCESS_THRESHOLD:
                add_issue(f"Обнаружено большое количество зомби-процессов: {process_info['zombie']}")
                add_suggestion("Перезапустите родительские процессы или перезагрузите сервер")
            
            # Парсим топ по CPU и памяти
            try:
                for line in lines[1:]:  # Пропускаем заголовок
                    parts = line.split()
                    if len(parts) >= 11:
                        username = parts[0]
                        pid = int(parts[1])
                        cpu_percent = float(parts[2])
                        mem_percent = float(parts[3])
                        command = ' '.join(parts[10:])[:50]  # Ограничиваем длину команды
                        
                        if cpu_percent > 1.0:
                            process_info['top_cpu'].append({
                                'pid': pid,
                                'name': command,
                                'username': username,
                                'cpu_percent': cpu_percent,
                                'memory_percent': mem_percent
                            })
                        
                        if mem_percent > 1.0:
                            process_info['top_memory'].append({
                                'pid': pid,
                                'name': command,
                                'username': username,
                                'cpu_percent': cpu_percent,
                                'memory_percent': mem_percent
                            })
                
                # Сортируем и ограничиваем количество
                process_info['top_cpu'] = sorted(process_info['top_cpu'], key=lambda p: p['cpu_percent'], reverse=True)[:10]
                process_info['top_memory'] = sorted(process_info['top_memory'], key=lambda p: p['memory_percent'], reverse=True)[:10]
                
                # Проверка ресурсоемких процессов
                for proc in process_info['top_cpu']:
                    if proc['cpu_percent'] > 90:
                        add_issue(f"Процесс с PID {proc['pid']} ({proc['name']}) потребляет {proc['cpu_percent']:.2f}% CPU")
                
                for proc in process_info['top_memory']:
                    if proc['memory_percent'] > 90:
                        add_issue(f"Процесс с PID {proc['pid']} ({proc['name']}) потребляет {proc['memory_percent']:.2f}% RAM")
            
            except Exception as e:
                logger.error(f"Ошибка при обработке информации о процессах: {e}")
        
        else:
            add_warning("Не удалось получить информацию о процессах. Ни psutil, ни команда ps не доступны.")
    
    logger.info(f"Собрана информация о процессах: всего {process_info['total']}, зомби {process_info['zombie']}")

def check_services():
    """Проверить состояние системных сервисов."""
    global service_status, service_descriptions
    
    # Очищаем словари перед началом
    service_status = {}
    service_descriptions = {}
    
    # Проверяем, используется ли systemd
    if os.path.exists('/run/systemd/system'):
        # Получаем список сервисов
        systemctl_output = run_command("systemctl list-units --type=service --all")
        if systemctl_output:
            for line in systemctl_output.split('\n'):
                if '.service' in line:
                    parts = line.split()
                    if len(parts) >= 4:
                        service_name = parts[0].replace('.service', '')
                        status = parts[3]
                        
                        if status == 'running':
                            service_status[service_name] = 'running'
                        elif status == 'failed':
                            service_status[service_name] = 'failed'
                            add_issue(f"Сервис {service_name} находится в состоянии FAILED")
                            add_suggestion(f"Проверьте 'systemctl status {service_name}' для подробной информации")
                        else:
                            service_status[service_name] = 'stopped'
        
        # Получаем описания сервисов
        for service in service_status:
            desc_output = run_command(f"systemctl show -p Description --value {service}.service")
            if desc_output:
                service_descriptions[service] = desc_output.strip()
            else:
                service_descriptions[service] = "Нет описания"
        
        # Проверяем журнал на наличие ошибок
        journalctl_output = run_command("journalctl -p err --since '1 hour ago'")
        if journalctl_output:
            lines = journalctl_output.strip().split('\n')
            error_count = len(lines)
            
            if error_count > 10:
                add_issue(f"Обнаружено {error_count} ошибок в журнале системы за последний час")
                add_suggestion("Проверьте 'journalctl -p err --since '1 hour ago'' для деталей")
    
    # Проверяем, используется ли SysVinit
    elif which('service') and which('chkconfig'):
        chkconfig_output = run_command("chkconfig --list")
        if chkconfig_output:
            for line in chkconfig_output.split('\n'):
                if ':' in line:
                    service_name = line.split(':')[0].strip()
                    
                    # Проверяем статус сервиса
                    status_output = run_command(f"service {service_name} status")
                    if status_output:
                        if 'running' in status_output.lower() or 'активн' in status_output.lower() or 'active' in status_output.lower():
                            service_status[service_name] = 'running'
                        else:
                            service_status[service_name] = 'stopped'
                    
                    # У SysVinit нет простого способа получить описание
                    service_descriptions[service_name] = "Нет описания"
    
    else:
        add_warning("Система не использует systemd или SysVinit. Невозможно проверить состояние сервисов.")
    
    logger.info(f"Проверка сервисов завершена: проверено {len(service_status)} сервисов")

def get_server_ip():
    """Получение IP-адреса сервера с учетом всех вариантов."""
    # Попытка 1: внешний IP через сетевой интерфейс
    try:
        cmd = "ip -4 route get 1.1.1.1 | awk '{print $7}' | tr -d '\\n'"
        ip = run_command(cmd, shell=True)
        if ip and ip != "127.0.0.1" and not ip.startswith("169.254"):
            return ip
    except:
        pass
    
    # Попытка 2: через ip addr
    try:
        cmd = "ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d '/' -f 1 | head -n 1"
        ip = run_command(cmd, shell=True)
        if ip and ip != "127.0.0.1" and not ip.startswith("169.254"):
            return ip
    except:
        pass
    
    # Попытка 3: через ifconfig
    try:
        cmd = "ifconfig | grep -Eo 'inet (addr:)?([0-9]*\\.){3}[0-9]*' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1"
        ip = run_command(cmd, shell=True)
        if ip and ip != "127.0.0.1" and not ip.startswith("169.254"):
            if ip.startswith("addr:"):
                ip = ip[5:]
            return ip
    except:
        pass
    
    # Запасной вариант
    try:
        return socket.gethostbyname(socket.gethostname())
    except:
        return "Н/Д"


def check_log_errors():
    """Проверить логи на наличие ошибок."""
    global log_samples
    
    # Список лог-файлов для проверки
    log_files = [
        "/var/log/syslog",
        "/var/log/messages",
        "/var/log/dmesg",
        "/var/log/kern.log",
        "/var/log/apache2/error.log",
        "/var/log/nginx/error.log",
        "/var/log/mysql/error.log"
    ]
    
    # Очищаем словарь перед заполнением
    log_samples = {}
    
    # Функция для проверки одного файла
    def check_log_file(log_file):
        if os.path.exists(log_file) and os.access(log_file, os.R_OK):
            # Получаем последние строки файла
            tail_output = run_command(f"tail -n 100 {log_file}")
            if tail_output:
                # Ищем ошибки и предупреждения
                error_lines = []
                for line in tail_output.split('\n'):
                    if any(pattern in line.lower() for pattern in ['error', 'warning', 'critical', 'emergency']):
                        error_lines.append(line)
                
                error_count = len(error_lines)
                if error_count > 0:
                    log_samples[log_file] = {
                        'count': error_count,
                        'samples': error_lines[:3]  # Сохраняем до 3 примеров ошибок
                    }
                    
                    if error_count > 10:
                        add_issue(f"Обнаружено {error_count} ошибок/предупреждений в {log_file}")
                    elif error_count > 5:
                        add_warning(f"Обнаружено {error_count} ошибок/предупреждений в {log_file}")
    
    # Проверяем каждый файл лога
    for log_file in log_files:
        check_log_file(log_file)
    
    # Проверяем, есть ли журнал systemd
    if os.path.exists('/run/systemd/system'):
        journalctl_output = run_command("journalctl -p err,crit,alert,emerg --since '1 day ago'")
        if journalctl_output:
            error_lines = journalctl_output.split('\n')
            error_count = len(error_lines)
            
            if error_count > 0:
                log_samples['systemd-journal'] = {
                    'count': error_count,
                    'samples': error_lines[:3]
                }
                
                if error_count > 20:
                    add_issue(f"Обнаружено {error_count} ошибок в journalctl за последний день")
                elif error_count > 10:
                    add_warning(f"Обнаружено {error_count} ошибок в journalctl за последний день")
    
    if len(log_samples) > 0:
        add_suggestion("Проанализируйте файлы логов для выявления причин ошибок")
    
    logger.info(f"Проверка логов завершена, проанализировано {len(log_samples)} файлов с ошибками")

def check_open_files():
    """Проверить количество открытых файлов."""
    # Получаем лимит открытых файлов
    try:
        file_limit = int(run_command("ulimit -n", shell=True).strip())
    except:
        file_limit = 1024  # Значение по умолчанию, если не удалось определить
    
    # Получаем текущее количество открытых файлов
    if which('lsof'):
        lsof_output = run_command("lsof | wc -l", shell=True)
        if lsof_output:
            try:
                current_open_files = int(lsof_output.strip())
                
                # Рассчитываем процент использования
                usage_percent = (current_open_files / file_limit) * 100 if file_limit > 0 else 0
                
                if usage_percent > 70:
                    add_issue(f"Высокое количество открытых файлов: {current_open_files} из {file_limit} ({usage_percent:.2f}%)")
                    add_suggestion("Проверьте 'lsof | awk '{print $1}' | sort | uniq -c | sort -nr | head' для выявления процессов с большим количеством открытых файлов")
                
                logger.info(f"Проверка открытых файлов: {current_open_files} из {file_limit}")
                return current_open_files, file_limit, usage_percent
            except:
                pass
    
    # Если lsof недоступен или произошла ошибка
    add_warning("Не удалось определить количество открытых файлов")
    return "Н/Д", file_limit, 0

def suggest_improvements():
    """Сгенерировать рекомендации на основе обнаруженных проблем."""
    if len(issues) == 0:
        add_suggestion("Система работает нормально. Рекомендуется регулярное профилактическое обслуживание.")
    
    # Рекомендации на основе обнаруженных проблем
    if len(issues) > 5:
        add_suggestion("Обнаружено множество проблем, рекомендуется провести полный аудит системы.")
    
    # Рекомендации по категориям проблем
    cpu_issues = [i for i in issues if 'CPU' in i or 'нагрузка' in i]
    if cpu_issues:
        add_suggestion("Проведите мониторинг CPU в течение длительного времени для выявления паттернов высокой нагрузки.")
    
    memory_issues = [i for i in issues if 'памяти' in i or 'SWAP' in i]
    if memory_issues:
        add_suggestion("Рассмотрите возможность оптимизации использования памяти или увеличения объема RAM.")
    
    disk_issues = [i for i in issues if 'диска' in i or 'inodes' in i]
    if disk_issues:
        add_suggestion("Регулярно очищайте временные файлы и логи. Рассмотрите возможность расширения дискового пространства.")
    
    network_issues = [i for i in issues if 'соединений' in i or 'сети' in i]
    if network_issues:
        add_suggestion("Проверьте настройки сетевого стека и таймауты TCP.")
    
    logger.info(f"Сгенерировано рекомендаций: {len(suggestions)}")

def apply_quick_fixes():
    """Применить быстрые исправления для выявленных проблем."""
    global fixes_applied
    
    if not fix_enabled:
        return
    
    fixes_applied = []
    
    # Очистка журналов при проблемах с диском
    if any('диска' in issue for issue in issues):
        if os.path.exists('/run/systemd/system') and which('journalctl'):
            result = run_command("journalctl --vacuum-time=3d")
            fixes_applied.append(f"Сжатие journalctl логов: {result[:50] if result else 'Выполнено'}")
        
        # Очистка старых логов
        if os.path.exists('/var/log'):
            try:
                cmd = "find /var/log -type f -name \"*.gz\" -o -name \"*.1\" -o -name \"*.old\" -mtime +7 -delete"
                run_command(cmd, shell=True)
                fixes_applied.append("Удаление старых лог-файлов: Выполнено")
            except:
                pass
    
    # Перезапуск проблемных сервисов
    for issue in issues:
        if 'Сервис' in issue and 'FAILED' in issue:
            match = re.search(r'Сервис (\S+) находится', issue)
            if match:
                service_name = match.group(1)
                result = run_command(f"systemctl restart {service_name}.service")
                fixes_applied.append(f"Перезапуск сервиса {service_name}: {result[:50] if result else 'Выполнено'}")
    
    # Очистка кэша памяти при проблемах с памятью
    if any('памяти' in issue for issue in issues):
        if is_root():
            run_command("sync")
            try:
                with open('/proc/sys/vm/drop_caches', 'w') as f:
                    f.write("3")
                fixes_applied.append("Очистка кэша памяти: Выполнено")
            except:
                pass
    
    # Оптимизация параметров ядра для соединений в TIME_WAIT
    if any('TIME_WAIT' in issue for issue in issues):
        if is_root():
            try:
                # Включаем повторное использование сокетов в состоянии TIME_WAIT
                run_command("sysctl -w net.ipv4.tcp_tw_reuse=1", shell=True)
                fixes_applied.append("Оптимизация TCP-соединений (net.ipv4.tcp_tw_reuse=1): Выполнено")
            except:
                pass
    
    if len(fixes_applied) > 0:
        logger.info(f"Применены автоматические исправления: {len(fixes_applied)}")
    else:
        logger.info("Нет автоматических исправлений для применения")

# --------- Функции вывода результатов ---------
def print_system_info():
    """Вывести информацию о системе."""
    print_header("ИНФОРМАЦИЯ О СИСТЕМЕ")
    
    print(f"Хост: {system_info.get('hostname', 'Н/Д')}")
    print(f"IP-адрес: {system_info.get('ip_address', 'Н/Д')}")
    print(f"Дистрибутив: {system_info.get('distro', 'Н/Д')}")
    print(f"Ядро: {system_info.get('kernel', 'Н/Д')}")
    print(f"Аптайм: {system_info.get('uptime', 'Н/Д')}")
    print(f"Последняя перезагрузка: {system_info.get('last_reboot', 'Н/Д')}")

def print_issues():
    """Вывести обнаруженные проблемы и предупреждения."""
    print_header("ОБНАРУЖЕННЫЕ ПРОБЛЕМЫ")
    
    if len(issues) == 0:
        print(print_colored("✓ Критических проблем не обнаружено!", Colors.GREEN))
    else:
        for issue in issues:
            print(f"{print_colored('✗', Colors.RED)} {issue}")
    
    if len(warnings) > 0:
        print(f"\n{print_colored('ПРЕДУПРЕЖДЕНИЯ:', Colors.BOLD)}")
        for warning in warnings:
            print(f"{print_colored('!', Colors.YELLOW)} {warning}")

def print_resource_usage():
    """Вывести информацию об использовании ресурсов."""
    print_header("ИСПОЛЬЗОВАНИЕ РЕСУРСОВ")
    
    # CPU
    cpu_color = Colors.GREEN
    if cpu_info.get('usage_percent', 0) > CPU_WARNING_THRESHOLD:
        cpu_color = Colors.RED
    
    # Исправлено - используем двойные кавычки внутри строк с одинарными
    cpu_usage = f"{cpu_info.get('usage_percent', 0):.2f}%"
    user_cpu = f"{cpu_info.get('user', 0):.2f}%"
    system_cpu = f"{cpu_info.get('system', 0):.2f}%"
    iowait_cpu = f"{cpu_info.get('iowait', 0):.2f}%"
    
    print(f"\nCPU: {print_colored(cpu_usage, cpu_color)} "
          f"(User: {user_cpu}, System: {system_cpu}, "
          f"I/O Wait: {iowait_cpu})")
        
    # Средняя нагрузка
    load_color = Colors.GREEN
    if cpu_info.get('loadavg', (0, 0, 0))[2] > cpu_info.get('count', 1) * LOAD_FACTOR:
        load_color = Colors.RED
    
    loadavg = cpu_info.get('loadavg', (0, 0, 0))
    print(f"Средняя нагрузка: {print_colored(f'{loadavg[0]:.2f}', Colors.BLUE)} (1 мин), "
          f"{print_colored(f'{loadavg[1]:.2f}', Colors.BLUE)} (5 мин), "
          f"{print_colored(f'{loadavg[2]:.2f}', load_color)} (15 мин)")
    print(f"Количество ядер CPU: {cpu_info.get('count', 1)}")
    
    # Память
    mem_color = Colors.GREEN
    if memory_info.get('percent', 0) > MEMORY_WARNING_THRESHOLD:
        mem_color = Colors.RED
    
    mem_percent = f"{memory_info.get('percent', 0):.2f}%"
    mem_used = bytes_to_human(memory_info.get('used', 0))
    mem_total = bytes_to_human(memory_info.get('total', 0))
    
    print(f"\nПамять: {print_colored(mem_percent, mem_color)} "
          f"({mem_used} из {mem_total})")
    
    # SWAP
    if memory_info.get('swap_total', 0) > 0:
        swap_color = Colors.GREEN
        swap_percent = memory_info.get('swap_percent', 0)
        
        if swap_percent > 80:
            swap_color = Colors.RED
        elif swap_percent > 50:
            swap_color = Colors.YELLOW
        
        print(f"SWAP: {print_colored(f'{swap_percent:.2f}%', swap_color)} "
              f"({bytes_to_human(memory_info.get('swap_used', 0))} из {bytes_to_human(memory_info.get('swap_total', 0))})")
    
    # Открытые файлы (если данные доступны)
    open_files, file_limit, usage_percent = check_open_files()
    if open_files != "Н/Д":
        of_color = Colors.GREEN
        if usage_percent > 85:
            of_color = Colors.RED
        elif usage_percent > 70:
            of_color = Colors.YELLOW
        
        print(f"\nОткрытые файлы: {print_colored(f'{usage_percent:.2f}%', of_color)} ({open_files} из {file_limit})")

def print_disk_usage():
    """Вывести информацию об использовании дисков."""
    print_header("ИСПОЛЬЗОВАНИЕ ДИСКОВ")
    
    if not disk_info.get('partitions'):
        print("Нет данных о дисках")
        return

    # Подготавливаем данные для таблицы
    headers = ["Точка монтирования", "Размер", "Использовано", "Доступно", "Использование"]
    rows = []
    colors = {}
    
    for i, partition in enumerate(disk_info['partitions']):
        mount = partition['mountpoint']
        size = bytes_to_human(partition['total'])
        used = bytes_to_human(partition['used'])
        avail = bytes_to_human(partition['free'])
        percent = f"{partition['percent']:.2f}%"
        
        rows.append([mount, size, used, avail, percent])
        
        # Определяем цвет для процента использования
        if partition['percent'] > DISK_WARNING_THRESHOLD:
            if i not in colors:
                colors[i] = {}
            colors[i][4] = Colors.RED  # Колонка с процентами
    
    # Выводим таблицу дисков
    print_table(headers, rows, colors)
    
    # Вывод информации об inodes
    if disk_info.get('inodes'):
        print("\n" + print_colored("Использование inodes (файловых дескрипторов):", Colors.BOLD))
        
        headers = ["Точка монтирования", "Всего", "Использовано", "Свободно", "Использование"]
        rows = []
        colors = {}
        
        i = 0
        for mount, inode_info in disk_info['inodes'].items():
            percent = f"{inode_info['percent']}%"
            rows.append([mount, inode_info['total'], inode_info['used'], inode_info['free'], percent])
            
            if inode_info['percent'] > INODE_WARNING_THRESHOLD:
                if i not in colors:
                    colors[i] = {}
                colors[i][4] = Colors.RED
            i += 1
        
        print_table(headers, rows, colors)

def print_resource_summary():
    """Вывести краткую сводку по ресурсам."""
    width = shutil.get_terminal_size().columns
    
    # Определяем цвета для индикаторов
    cpu_color = Colors.GREEN
    if cpu_info.get('usage_percent', 0) > CPU_WARNING_THRESHOLD:
        cpu_color = Colors.RED
    elif cpu_info.get('usage_percent', 0) > CPU_WARNING_THRESHOLD * 0.7:
        cpu_color = Colors.YELLOW
    
    mem_color = Colors.GREEN
    if memory_info.get('percent', 0) > MEMORY_WARNING_THRESHOLD:
        mem_color = Colors.RED
    elif memory_info.get('percent', 0) > MEMORY_WARNING_THRESHOLD * 0.7:
        mem_color = Colors.YELLOW
    
    disk_color = Colors.GREEN
    max_disk_usage = 0
    for part in disk_info.get('partitions', []):
        if part['percent'] > max_disk_usage:
            max_disk_usage = part['percent']
    
    if max_disk_usage > DISK_WARNING_THRESHOLD:
        disk_color = Colors.RED
    elif max_disk_usage > DISK_WARNING_THRESHOLD * 0.7:
        disk_color = Colors.YELLOW
    
    # Создаем форматированные строки сначала
    cpu_str = f"{cpu_info.get('usage_percent', 0):.1f}%"
    mem_str = f"{memory_info.get('percent', 0):.1f}%"
    disk_str = f"{max_disk_usage:.1f}%"
    
    # Создаем строку сводки, используя предварительно отформатированные строки
    summary = f"CPU: {print_colored(cpu_str, cpu_color)}"
    summary += f" | Память: {print_colored(mem_str, mem_color)}"
    summary += f" | Диск: {print_colored(disk_str, disk_color)}"
    summary += f" | Процессов: {process_info.get('total', 'Н/Д')}"
    summary += f" | Проблем: {len(issues)}"
    
    # Центрируем строку
    padding = (width - len(summary) + len(Colors.GREEN) + len(Colors.YELLOW) + len(Colors.RED) + 3*len(Colors.ENDC)) // 2
    if padding < 0:
        padding = 0
    
    print("\n" + " " * padding + summary)


def print_failed_services():
    """Выводит информацию о проблемных сервисах."""
    # Создаем массив для проблемных сервисов
    failed_services = []
    
    # Заполняем массив
    for service, status in service_status.items():
        if status == "failed":
            failed_services.append(service)
    
    # Выводим проблемные сервисы
    if failed_services:
        print(f"\n{print_colored('Проблемные сервисы:', Colors.RED)}")
        for service in failed_services:
            description = service_descriptions.get(service, 'Нет описания')
            print(f"{print_colored('✗', Colors.RED)} Сервис {print_colored(service, Colors.BOLD)} находится в состоянии FAILED - {description}")
    else:
        print(f"\n{print_colored('Все сервисы работают нормально', Colors.GREEN)}")


def print_process_info():
    """Вывести информацию о процессах."""
    print_header("ПРОЦЕССЫ")
    
    # Зомби-процессы
    zombie_color = Colors.GREEN
    if process_info.get('zombie', 0) > ZOMBIE_PROCESS_THRESHOLD:
        zombie_color = Colors.RED
    
    print(f"Всего процессов: {process_info.get('total', 'Н/Д')}")
    print(f"Зомби-процессы: {print_colored(str(process_info.get('zombie', 0)), zombie_color)}")
    
    # Выводим топ процессов для CPU
    if process_info.get('top_cpu'):
        print(f"\n{print_colored('Процессы с высокой нагрузкой на CPU:', Colors.BLUE)}")
        
        headers = ["PID", "Пользователь", "CPU %", "RAM %", "Команда"]
        rows = []
        colors = {}
        
        for i, proc in enumerate(process_info['top_cpu'][:5]):  # Выводим только 5 процессов
            pid = proc['pid']
            username = proc['username']
            cpu_percent = f"{proc['cpu_percent']:.2f}%"
            mem_percent = f"{proc['memory_percent']:.2f}%"
            command = proc['name']
            
            rows.append([pid, username, cpu_percent, mem_percent, command])
            
            # Определяем цвет для CPU
            if proc['cpu_percent'] > 80:
                if i not in colors:
                    colors[i] = {}
                colors[i][2] = Colors.RED  # Колонка CPU %
            elif proc['cpu_percent'] > 50:
                if i not in colors:
                    colors[i] = {}
                colors[i][2] = Colors.YELLOW  # Колонка CPU %
        
        print_table(headers, rows, colors)
    
    # Выводим топ процессов для памяти
    if process_info.get('top_memory'):
        print(f"\n{print_colored('Процессы с высоким потреблением памяти:', Colors.BLUE)}")
        
        headers = ["PID", "Пользователь", "CPU %", "RAM %", "Команда"]
        rows = []
        colors = {}
        
        for i, proc in enumerate(process_info['top_memory'][:5]):  # Выводим только 5 процессов
            pid = proc['pid']
            username = proc['username']
            cpu_percent = f"{proc['cpu_percent']:.2f}%"
            mem_percent = f"{proc['memory_percent']:.2f}%"
            command = proc['name']
            
            rows.append([pid, username, cpu_percent, mem_percent, command])
            
            # Определяем цвет для памяти
            if proc['memory_percent'] > 80:
                if i not in colors:
                    colors[i] = {}
                colors[i][3] = Colors.RED  # Колонка RAM %
            elif proc['memory_percent'] > 50:
                if i not in colors:
                    colors[i] = {}
                colors[i][3] = Colors.YELLOW  # Колонка RAM %
        
        print_table(headers, rows, colors)
        
def print_network_info():
    """Вывести информацию о сетевых соединениях."""
    print_header("СЕТЕВЫЕ СОЕДИНЕНИЯ")
    
    print(f"ESTABLISHED: {network_info.get('connections', {}).get('ESTABLISHED', 0)}")
    
    time_wait_color = Colors.GREEN
    time_wait = network_info.get('connections', {}).get('TIME_WAIT', 0)
    if time_wait > 1000:
        time_wait_color = Colors.RED
    print(f"TIME_WAIT: {print_colored(str(time_wait), time_wait_color)}")
    
    close_wait_color = Colors.GREEN
    close_wait = network_info.get('connections', {}).get('CLOSE_WAIT', 0)
    if close_wait > 100:
        close_wait_color = Colors.RED
    print(f"CLOSE_WAIT: {print_colored(str(close_wait), close_wait_color)}")
    
    # Показываем сетевые интерфейсы
    if network_info.get('interfaces'):
        print(f"\n{print_colored('Сетевые интерфейсы:', Colors.BLUE)}")
        for iface, info in network_info['interfaces'].items():
            addresses = []
            for addr in info.get('addresses', []):
                if addr['family'] == 'AF_INET' or addr['family'] == '2':  # IPv4
                    addresses.append(addr['address'])
            
            print(f"  {iface}: {', '.join(addresses)}")
            if 'bytes_sent' in info and 'bytes_recv' in info:
                print(f"    TX: {bytes_to_human(info['bytes_sent'])}, RX: {bytes_to_human(info['bytes_recv'])}")
    
    # Показываем открытые порты (TOP 10)
    if network_info.get('open_ports'):
        print(f"\n{print_colored('Открытые порты (TOP 10):', Colors.BLUE)}")
        
        headers = ["Порт", "Программа/Сервис"]
        rows = []
        
        for port_info in network_info['open_ports'][:10]:
            port = port_info['port']
            service_name = get_service_by_port(port)
            program = service_name if port_info['program'] == "Неизвестно" and service_name != "Неизвестно" else port_info['program']
            
            rows.append([port, program])
        
        print_table(headers, rows)
    else:
        print("\nНет данных об открытых портах")

def get_external_ip():
    """Получить внешний IP-адрес."""
    try:
        # Пробуем получить IP через сетевые интерфейсы
        if_output = run_command("ip -4 addr show scope global")
        if if_output:
            for line in if_output.split('\n'):
                if 'inet ' in line:
                    ip = line.split()[1].split('/')[0]
                    if ip != '127.0.0.1' and not ip.startswith('169.254'):
                        return ip
        
        # Второй способ - через ifconfig
        if_output = run_command("ifconfig")
        if if_output:
            for line in if_output.split('\n'):
                if 'inet ' in line and not '127.0.0.1' in line:
                    ip = line.split('inet ')[1].split()[0]
                    return ip
        
        # Запасной вариант
        return socket.gethostbyname(socket.gethostname())
    except:
        return "Н/Д"

def print_table(headers, rows, colors=None):
    """Печать таблицы с выравниванием колонок.
    
    Args:
        headers: Список заголовков колонок
        rows: Список списков данных для каждой строки
        colors: Опциональный словарь с цветами для ячеек {row_idx: {col_idx: color}}
    """
    if not rows:
        print("Нет данных")
        return
    
    # Определяем ширину каждой колонки
    col_widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if i < len(col_widths):
                col_widths[i] = max(col_widths[i], len(str(cell)))
    
    # Форматируем заголовок
    header_line = ""
    for i, header in enumerate(headers):
        header_line += f"{print_colored(header.ljust(col_widths[i]), Colors.BOLD)} | "
    print(header_line.rstrip(" | "))
    
    # Печатаем разделитель
    separator = ""
    for width in col_widths:
        separator += "-" * width + "-+-"
    print(separator.rstrip("-+-"))
    
    # Печатаем строки
    for row_idx, row in enumerate(rows):
        line = ""
        for col_idx, cell in enumerate(row):
            cell_str = str(cell).ljust(col_widths[col_idx])
            
            # Применяем цвет, если он указан
            if colors and row_idx in colors and col_idx in colors[row_idx]:
                line += f"{print_colored(cell_str, colors[row_idx][col_idx])} | "
            else:
                line += f"{cell_str} | "
        
        print(line.rstrip(" | "))


def print_services_info():
    """Вывести информацию о сервисах."""
    print_header("СТАТУС СЕРВИСОВ")
    
    # Проверяем, есть ли данные о сервисах
    if not service_status:
        print("Нет данных о сервисах")
        return
    
    # Создаем массивы для каждого типа сервисов
    failed_services = []
    running_services = []
    stopped_services = []
    
    # Заполняем массивы
    for service, status in service_status.items():
        if status == "failed":
            failed_services.append(service)
        elif status == "running":
            running_services.append(service)
        else:
            stopped_services.append(service)
    
    # Выводим проблемные сервисы первыми
    if failed_services:
        print(f"\n{print_colored('Проблемные сервисы:', Colors.RED)}")
        for service in failed_services:
            description = service_descriptions.get(service, 'Нет описания')
            print(f"{print_colored('✗', Colors.RED)} {service} - {description}")
    
    # Выводим остановленные сервисы
    if stopped_services:
        print(f"\n{print_colored('Остановленные сервисы (топ 5):', Colors.YELLOW)}")
        for i, service in enumerate(stopped_services[:5]):
            description = service_descriptions.get(service, 'Нет описания')
            print(f"{print_colored('!', Colors.YELLOW)} {service} - {description}")
        
        if len(stopped_services) > 5:
            print(f"{print_colored(f'...и еще {len(stopped_services) - 5} остановленных сервисов', Colors.YELLOW)}")
    
    # Выводим запущенные сервисы
    if running_services:
        print(f"\n{print_colored('Запущенные сервисы (топ 5):', Colors.GREEN)}")
        for i, service in enumerate(running_services[:5]):
            description = service_descriptions.get(service, 'Нет описания')
            print(f"{print_colored('✓', Colors.GREEN)} {service} - {description}")
        
        if len(running_services) > 5:
            print(f"{print_colored(f'...и еще {len(running_services) - 5} запущенных сервисов', Colors.GREEN)}")
    
    print("\nДля детального управления сервисами выберите пункт 'Управление сервисами' в главном меню")

def print_log_findings():
    """Вывести результаты анализа логов."""
    if not log_samples:
        return
    
    print_header("АНАЛИЗ ЛОГОВ")
    
    for log_file, info in log_samples.items():
        error_count = info['count']
        
        error_color = Colors.GREEN
        if error_count >= 10:
            error_color = Colors.RED
        elif error_count >= 5:
            error_color = Colors.YELLOW
        
        print(f"{log_file}: {print_colored(f'{error_count} ошибок/предупреждений', error_color)}")
        
        # Выводим примеры ошибок (если есть)
        if 'samples' in info and info['samples']:
            print("  Примеры:")
            for sample in info['samples']:
                if len(sample) > 100:
                    sample = sample[:97] + "..."
                print(f"  - {sample}")
    
    print("\nДля подробного анализа логов используйте команды:")
    print("- grep -i 'error\\|warning\\|critical' /var/log/syslog | tail -50")
    if os.path.exists('/run/systemd/system'):
        print("- journalctl -p err --since '1 hour ago'")
    print("Или выберите пункт 'Мониторинг логов' в главном меню")

def print_suggestions():
    """Вывести рекомендации."""
    print_header("РЕКОМЕНДАЦИИ")
    
    if not suggestions:
        print("Нет рекомендаций для этой системы")
        return
    
    for i, suggestion in enumerate(suggestions):
        print(f"{i+1}. {suggestion}")

def print_fixes():
    """Вывести примененные исправления."""
    print_header("БЫСТРЫЕ ИСПРАВЛЕНИЯ")
    
    if not fix_enabled:
        print("Автоматические исправления не запрошены")
        print("Запустите скрипт с флагом --fix для применения автоматических исправлений")
        print("Или выберите пункт 'Применить автоматические исправления' в главном меню")
        return
    
    if not fixes_applied:
        print("Нет примененных исправлений")
        return
    
    for fix in fixes_applied:
        print(f"✓ {fix}")

# --------- Интерактивное меню и UI функции ---------
def watch_logs(log_file):
    """Мониторинг лог-файла в реальном времени."""
    if not os.path.exists(log_file):
        print(print_colored(f"Ошибка: Файл {log_file} не существует.", Colors.RED))
        return False
    
    if not os.access(log_file, os.R_OK):
        print(print_colored(f"Ошибка: Нет прав на чтение файла {log_file}.", Colors.RED))
        return False
    
    clear_screen()
    print_header(f"Мониторинг лог-файла {log_file}")
    print(print_colored("Нажмите Ctrl+C для выхода", Colors.YELLOW))
    print()
    
    try:
        # Запускаем tail -f с подсветкой ошибок
        # Используем менее элегантный способ для большей совместимости
        tail_process = subprocess.Popen(['tail', '-f', log_file], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        
        try:
            while True:
                line = tail_process.stdout.readline()
                if not line:
                    break
                
                # Подсвечиваем ошибки и предупреждения
                if 'error' in line.lower():
                    print(print_colored(line.rstrip(), Colors.RED))
                elif 'warning' in line.lower():
                    print(print_colored(line.rstrip(), Colors.YELLOW))
                elif 'critical' in line.lower() or 'emergency' in line.lower():
                    print(print_colored(line.rstrip(), Colors.RED + Colors.BOLD))
                else:
                    print(line.rstrip())
        
        except KeyboardInterrupt:
            pass
        finally:
            tail_process.terminate()
            tail_process.wait()
        
        return True
    except Exception as e:
        print(print_colored(f"Ошибка при мониторинге файла: {e}", Colors.RED))
        return False

def get_service_by_port(port):
    """Возвращает название сервиса по номеру порта."""
    return KNOWN_PORTS.get(port, "Неизвестно")

def select_log_file():
    """Меню выбора лог-файла для мониторинга."""
    clear_screen()
    print_header("Выбор лог-файла для мониторинга")
    
    # Список популярных лог-файлов
    log_files = [
        "/var/log/syslog",
        "/var/log/messages",
        "/var/log/dmesg",
        "/var/log/auth.log",
        "/var/log/kern.log",
        "/var/log/apache2/error.log",
        "/var/log/nginx/error.log",
        "/var/log/mysql/error.log",
        "Другой (ввести вручную)",
        "Назад в главное меню"
    ]
    
    print("Выберите лог-файл для мониторинга:\n")
    
    for i, log_file in enumerate(log_files):
        if log_file in ["Другой (ввести вручную)", "Назад в главное меню"]:
            print(f"{print_colored(str(i+1), Colors.YELLOW)}) {log_file}")
        elif os.path.exists(log_file):
            print(f"{print_colored(str(i+1), Colors.GREEN)}) {log_file}")
        else:
            print(f"{print_colored(str(i+1), Colors.RED)}) {log_file} (файл не существует)")
    
    print("\nВведите номер лог-файла: ", end="")
    choice = input()
    
    try:
        choice = int(choice)
        if 1 <= choice <= len(log_files):
            choice -= 1  # Корректируем индекс
            
            if log_files[choice] == "Назад в главное меню":
                return
            elif log_files[choice] == "Другой (ввести вручную)":
                print("\nВведите путь к лог-файлу: ", end="")
                custom_log = input().strip()
                
                if os.path.exists(custom_log):
                    watch_logs(custom_log)
                else:
                    print(print_colored(f"Ошибка: Файл {custom_log} не существует.", Colors.RED))
                    input("\nНажмите Enter для продолжения...")
            elif os.path.exists(log_files[choice]):
                watch_logs(log_files[choice])
            else:
                print(print_colored(f"Ошибка: Файл {log_files[choice]} не существует.", Colors.RED))
                input("\nНажмите Enter для продолжения...")
        else:
            print(print_colored("Неверный выбор. Возврат в главное меню.", Colors.RED))
            input("\nНажмите Enter для продолжения...")
    except ValueError:
        print(print_colored("Неверный ввод. Возврат в главное меню.", Colors.RED))
        input("\nНажмите Enter для продолжения...")

def view_service_details():
    """Меню для детального просмотра и управления сервисами."""
    clear_screen()
    print_header("Детальный просмотр сервисов")
    
    # Проверяем есть ли данные о сервисах
    if not service_status:
        print("Нет данных о сервисах. Запустите сначала полную диагностику системы.")
        input("\nНажмите Enter для продолжения...")
        return
    
    # Группируем сервисы по статусу для удобства
    failed_services = []
    running_services = []
    stopped_services = []
    
    # Заполняем массивы
    for service, status in service_status.items():
        if status == "failed":
            failed_services.append(service)
        elif status == "running":
            running_services.append(service)
        else:
            stopped_services.append(service)
    
    # Выводим в порядке важности: сначала failed, потом stopped, потом running
    
    # 1. Failed services
    if failed_services:
        print(f"\n{print_colored('Сервисы с ошибками:', Colors.RED)}")
        for i, service in enumerate(failed_services):
            description = service_descriptions.get(service, "Нет описания")
            print(f"{print_colored(str(i+1), Colors.RED)}) {service} - {description}")
        
        print("\nВведите номер сервиса для просмотра детальной информации (или 0 для продолжения): ", end="")
        choice = input()
        
        try:
            choice = int(choice)
            if 1 <= choice <= len(failed_services):
                service = failed_services[choice-1]
                
                clear_screen()
                print_header(f"Детальная информация о сервисе {service}")
                
                # Получаем статус сервиса
                if which('systemctl'):
                    status_output = run_command(f"systemctl status {service}.service")
                    if status_output:
                        print(status_output)
                else:
                    status_output = run_command(f"service {service} status")
                    if status_output:
                        print(status_output)
                
                print(f"\n{print_colored('Действия:', Colors.YELLOW)}")
                print("1. Перезапустить сервис")
                print("2. Остановить сервис")
                print("3. Просмотреть журнал сервиса")
                print("4. Вернуться в список сервисов")
                
                print("\nВыберите действие: ", end="")
                action = input()
                
                if action == "1":
                    if which('systemctl'):
                        print(f"Перезапуск сервиса {service}...")
                        result = run_command(f"systemctl restart {service}.service")
                        if result:
                            print(result)
                    else:
                        print(f"Перезапуск сервиса {service}...")
                        result = run_command(f"service {service} restart")
                        if result:
                            print(result)
                elif action == "2":
                    if which('systemctl'):
                        print(f"Остановка сервиса {service}...")
                        result = run_command(f"systemctl stop {service}.service")
                        if result:
                            print(result)
                    else:
                        print(f"Остановка сервиса {service}...")
                        result = run_command(f"service {service} stop")
                        if result:
                            print(result)
                elif action == "3":
                    if which('journalctl'):
                        clear_screen()
                        print_header(f"Журнал сервиса {service}")
                        journal_output = run_command(f"journalctl -u {service}.service -n 50")
                        if journal_output:
                            print(journal_output)
                    else:
                        print(print_colored("Команда journalctl недоступна.", Colors.RED))
                
                input("\nНажмите Enter для продолжения...")
        except ValueError:
            pass
    
    # 2. Stopped services
    if stopped_services:
        clear_screen()
        print_header("Остановленные сервисы")
        
        # Выводим по 15 сервисов на страницу для удобства
        total_pages = (len(stopped_services) + 14) // 15
        current_page = 1
        
        while True:
            clear_screen()
            print_header(f"Остановленные сервисы (страница {current_page}/{total_pages})")
            
            start_idx = (current_page - 1) * 15
            end_idx = min(start_idx + 15, len(stopped_services))
            
            for i in range(start_idx, end_idx):
                service = stopped_services[i]
                description = service_descriptions.get(service, "Нет описания")
                print(f"{print_colored(str(i+1-start_idx), Colors.YELLOW)}) {service} - {description}")
            
            print("\nВведите номер сервиса для запуска или:")
            print("n - следующая страница")
            print("p - предыдущая страница")
            print("0 - вернуться к списку категорий")
            print("\nВаш выбор: ", end="")
            choice = input().lower()
            
            if choice == "n":
                if current_page < total_pages:
                    current_page += 1
            elif choice == "p":
                if current_page > 1:
                    current_page -= 1
            elif choice == "0":
                break
            else:
                try:
                    choice_idx = int(choice)
                    if 1 <= choice_idx <= end_idx - start_idx:
                        service = stopped_services[start_idx + choice_idx - 1]
                        
                        print(f"Запуск сервиса {service}...")
                        if which('systemctl'):
                            run_command(f"systemctl start {service}.service")
                        else:
                            run_command(f"service {service} start")
                        
                        # Проверяем статус после запуска
                        if which('systemctl'):
                            status = run_command(f"systemctl is-active {service}.service")
                            if status and status.strip() == "active":
                                service_status[service] = "running"
                                # Обновляем списки
                                running_services.append(service)
                                stopped_services.remove(service)
                                total_pages = (len(stopped_services) + 14) // 15
                                if current_page > total_pages and total_pages > 0:
                                    current_page = total_pages
                        
                        input("\nНажмите Enter для продолжения...")
                except ValueError:
                    print(print_colored("Неверный выбор.", Colors.RED))
                    input("\nНажмите Enter для продолжения...")
            
            # Если пустая страница, возвращаемся на предыдущую
            if len(stopped_services) == 0 or (total_pages > 0 and current_page > total_pages):
                break
    
    # 3. Running services
    if running_services:
        clear_screen()
        print_header("Запущенные сервисы")
        
        # Выводим по 15 сервисов на страницу для удобства
        total_pages = (len(running_services) + 14) // 15
        current_page = 1
        
        while True:
            clear_screen()
            print_header(f"Запущенные сервисы (страница {current_page}/{total_pages})")
            
            start_idx = (current_page - 1) * 15
            end_idx = min(start_idx + 15, len(running_services))
            
            for i in range(start_idx, end_idx):
                service = running_services[i]
                description = service_descriptions.get(service, "Нет описания")
                print(f"{print_colored(str(i+1-start_idx), Colors.GREEN)}) {service} - {description}")
            
            print("\nВведите номер сервиса для управления или:")
            print("n - следующая страница")
            print("p - предыдущая страница")
            print("0 - вернуться к главному меню")
            print("\nВаш выбор: ", end="")
            choice = input().lower()
            
            if choice == "n":
                if current_page < total_pages:
                    current_page += 1
            elif choice == "p":
                if current_page > 1:
                    current_page -= 1
            elif choice == "0":
                break
            else:
                try:
                    choice_idx = int(choice)
                    if 1 <= choice_idx <= end_idx - start_idx:
                        service = running_services[start_idx + choice_idx - 1]
                        
                        clear_screen()
                        print_header(f"Управление сервисом {service}")
                        
                        # Показываем статус сервиса
                        if which('systemctl'):
                            status_output = run_command(f"systemctl status {service}.service")
                            if status_output:
                                print(status_output)
                        else:
                            status_output = run_command(f"service {service} status")
                            if status_output:
                                print(status_output)
                        
                        print(f"\n{print_colored('Действия:', Colors.YELLOW)}")
                        print("1. Перезапустить сервис")
                        print("2. Остановить сервис")
                        print("3. Просмотреть журнал сервиса")
                        print("4. Вернуться к списку сервисов")
                        
                        print("\nВыберите действие: ", end="")
                        action = input()
                        
                        if action == "1":
                            if which('systemctl'):
                                print(f"Перезапуск сервиса {service}...")
                                result = run_command(f"systemctl restart {service}.service")
                                if result:
                                    print(result)
                            else:
                                print(f"Перезапуск сервиса {service}...")
                                result = run_command(f"service {service} restart")
                                if result:
                                    print(result)
                        elif action == "2":
                            if which('systemctl'):
                                print(f"Остановка сервиса {service}...")
                                result = run_command(f"systemctl stop {service}.service")
                                
                                # Проверяем статус после остановки
                                status = run_command(f"systemctl is-active {service}.service")
                                if status and status.strip() != "active":
                                    service_status[service] = "stopped"
                                    # Обновляем списки
                                    stopped_services.append(service)
                                    running_services.remove(service)
                                    total_pages = (len(running_services) + 14) // 15
                                    if current_page > total_pages and total_pages > 0:
                                        current_page = total_pages
                            else:
                                print(f"Остановка сервиса {service}...")
                                result = run_command(f"service {service} stop")
                                if result:
                                    print(result)
                        elif action == "3":
                            if which('journalctl'):
                                clear_screen()
                                print_header(f"Журнал сервиса {service}")
                                journal_output = run_command(f"journalctl -u {service}.service -n 50")
                                if journal_output:
                                    print(journal_output)
                            else:
                                print(print_colored("Команда journalctl недоступна.", Colors.RED))
                        
                        input("\nНажмите Enter для продолжения...")
                except ValueError:
                    print(print_colored("Неверный выбор.", Colors.RED))
                    input("\nНажмите Enter для продолжения...")

def show_system_details():
    """Функция для отображения расширенной информации о системе."""
    clear_screen()
    print_header("Расширенная информация о системе")
    
    # Основная информация
    print(print_colored("Основная информация:", Colors.BOLD))
    for key, value in system_info.items():
        print(f"{key.capitalize()}: {value}")
    
    # Информация о CPU
    print(f"\n{print_colored('Информация о процессоре:', Colors.BOLD)}")
    if which('lscpu'):
        lscpu_output = run_command("lscpu")
        if lscpu_output:
            # Фильтруем только нужные строки
            for line in lscpu_output.split('\n'):
                if any(x in line for x in ['Model name', 'Architecture', 'CPU(s)', 'Thread', 'Core', 'Socket', 'MHz']):
                    print(line)
    else:
        print(f"Модель: {cpu_info.get('model', 'Неизвестно')}")
        print(f"Ядра: {cpu_info.get('count', 'Н/Д')}")
    
    # Информация о памяти
    print(f"\n{print_colored('Информация о памяти:', Colors.BOLD)}")
    if which('free'):
        free_output = run_command("free -h")
        if free_output:
            print(free_output)
    else:
        total = bytes_to_human(memory_info.get('total', 0))
        used = bytes_to_human(memory_info.get('used', 0))
        free = bytes_to_human(memory_info.get('free', 0))
        print(f"Всего: {total}")
        print(f"Использовано: {used}")
        print(f"Свободно: {free}")
    
    # Информация о дисках
    print(f"\n{print_colored('Информация о дисках:', Colors.BOLD)}")
    if which('df'):
        df_output = run_command("df -h")
        if df_output:
            print(df_output)
    else:
        for part in disk_info.get('partitions', []):
            print(f"{part['mountpoint']}: {bytes_to_human(part['total'])} общий, {bytes_to_human(part['used'])} использован, {part['percent']}% занято")
    
    # Информация о сети
    print(f"\n{print_colored('Информация о сети:', Colors.BOLD)}")
    if which('ip'):
        ip_output = run_command("ip addr show")
        if ip_output:
            for line in ip_output.split('\n'):
                if 'inet ' in line or 'link/ether' in line:
                    if not '127.0.0.1' in line:
                        print(line.strip())
    elif which('ifconfig'):
        ifconfig_output = run_command("ifconfig")
        if ifconfig_output:
            for line in ifconfig_output.split('\n'):
                if 'inet ' in line or 'ether ' in line:
                    if not '127.0.0.1' in line:
                        print(line.strip())
    else:
        for iface, info in network_info.get('interfaces', {}).items():
            print(f"Интерфейс {iface}:")
            for addr in info.get('addresses', []):
                print(f"  Адрес: {addr.get('address', 'Н/Д')}")
    
    # Дополнительная информация о железе
    print(f"\n{print_colored('Информация о железе:', Colors.BOLD)}")
    if which('lshw'):
        lshw_output = run_command("lshw -short")
        if lshw_output:
            print(lshw_output)
    elif os.path.exists('/proc/cpuinfo'):
        with open('/proc/cpuinfo', 'r') as f:
            for line in f:
                if 'model name' in line:
                    print(f"Процессор: {line.split(':')[1].strip()}")
                    break
    else:
        print("Нет данных о железе")
    
    input("\nНажмите Enter для продолжения...")

def run_diagnostics():
    """Функция выполнения полной диагностики."""
    global issues, warnings, suggestions, fixes_applied
    
    clear_screen()
    print_header("Запуск полной диагностики системы")
    print("Пожалуйста, подождите... Сканирование системы может занять некоторое время.")
    
    # Очищаем старые данные
    issues = []
    warnings = []
    suggestions = []
    fixes_applied = []
    
    # Сбор данных
    print("Сбор базовой информации о системе...")
    get_basic_info()
    
    print("Проверка загрузки CPU...")
    get_cpu_info()
    
    print("Проверка использования памяти...")
    get_memory_info()
    
    print("Проверка дискового пространства...")
    get_disk_info()
    
    print("Проверка процессов...")
    get_process_info()
    
    print("Проверка сетевых соединений...")
    get_network_info()
    
    print("Проверка сервисов...")
    check_services()
    
    print("Анализ логов...")
    check_log_errors()
    
    print("Проверка открытых файлов...")
    check_open_files()
    
    # Генерируем рекомендации
    print("Генерация рекомендаций...")
    suggest_improvements()
    
    # Применяем быстрые исправления, если запрошено
    if fix_enabled:
        print("Применение автоматических исправлений...")
        apply_quick_fixes()
    
    # Сохраняем результаты в JSON
    timestamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    result_dir = "serverrescue_logs"
    os.makedirs(result_dir, exist_ok=True)
    json_file = f"{result_dir}/serverrescue_{system_info.get('hostname', 'unknown')}_{timestamp}.json"
    
    with open(json_file, 'w', encoding='utf-8') as f:
        json.dump({
            "timestamp": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "hostname": system_info.get('hostname', 'unknown'),
            "issues_count": len(issues),
            "warnings_count": len(warnings),
            "suggestions_count": len(suggestions)
        }, f, ensure_ascii=False, indent=4)
    
    # Выводим результаты на экран
    clear_screen()
    print_system_info()
    print_issues()
    print_resource_usage()
    print_disk_usage()
    print_process_info()
    print_network_info()
    print_services_info()
    print_log_findings()
    print_suggestions()
    print_fixes()
    
    print(f"\n{print_colored('=' * 80, Colors.BOLD)}")
    print(f"Диагностика завершена. Результаты сохранены в: {json_file}")
    print(f"{print_colored('=' * 80, Colors.BOLD)}")
    
    logger.info("Диагностика успешно завершена")
    
    input("\nНажмите Enter для продолжения...")

def show_logo():
    """Функция для вывода анимированного логотипа."""
    clear_screen()
    print(f"{Colors.BOLD}{Colors.CYAN}")
    print('   _____                          _____                           ')
    print('  / ____|                        |  __ \                          ')
    print(' | (___   ___ _ ____   _____ _ __| |__) |___  ___  ___ _   _  ___ ')
    print('  \___ \ / _ \ |_  /\ / / _ \ |__|  _  // _ \/ __|/ __| | | |/ _ \\')
    print('  ____) |  __/ |/ /  \ /  __/ |  | | \ \  __/\__ \ (__| |_| |  __/')
    print(' |_____/ \___|_/___/\__\___|_|  |_|  \_\___||___/\___|\__,_|\___|')
    print(f"{Colors.ENDC}")
    print(f"{Colors.BOLD}{Colors.YELLOW}         Интеллектуальный диагностический инструмент v{VERSION}{Colors.ENDC}")
    print(f"{Colors.BOLD}{Colors.GREEN}                 Автор: Владислав Павлович - pavlovich.live - TG @femid00{Colors.ENDC}")
    print("\n")
    
    # Анимация загрузки
    print(f"{Colors.BOLD}{Colors.WHITE}Инициализация", end="")
    for i in range(5):
        time.sleep(0.2)
        print(".", end="", flush=True)
    print(f"{Colors.ENDC}\n")
    time.sleep(0.2)

def show_main_menu():
    """Главное меню программы."""
    while True:
        clear_screen()
        
        # Красивый заголовок
        print(f"{Colors.BOLD}{Colors.CYAN}")
        print('   _____                          _____                           ')
        print('  / ____|                        |  __ \                          ')
        print(' | (___   ___ _ ____   _____ _ __| |__) |___  ___  ___ _   _  ___ ')
        print('  \___ \ / _ \ |_  /\ / / _ \ |__|  _  // _ \/ __|/ __| | | |/ _ \\')
        print('  ____) |  __/ |/ /  \ /  __/ |  | | \ \  __/\__ \ (__| |_| |  __/')
        print(' |_____/ \___|_/___/\__\___|_|  |_|  \_\___||___/\___|\__,_|\___|')
        print(f"{Colors.ENDC}")
        print(f"{Colors.BOLD}{Colors.YELLOW}         Интеллектуальный диагностический инструмент v{VERSION}{Colors.ENDC}")
        print(f"{Colors.GREEN}                 Автор: На основе скрипта Владислава Павловича{Colors.ENDC}")
        
        hostname = system_info.get('hostname', socket.gethostname())
        current_date = datetime.datetime.now().strftime("%d.%m.%Y %H:%M:%S")
        print(f"\n{Colors.BOLD}Хост: {hostname} | Дата: {current_date}{Colors.ENDC}")
        
        # Меню
        print(f"\n{Colors.BOLD}{Colors.YELLOW}Главное меню:{Colors.ENDC}")
        print(f"{Colors.BOLD}{Colors.BLUE}1.{Colors.ENDC} Запустить полную диагностику системы")
        print(f"{Colors.BOLD}{Colors.BLUE}2.{Colors.ENDC} Мониторинг ресурсов системы (CPU, Память, Диски)")
        print(f"{Colors.BOLD}{Colors.BLUE}3.{Colors.ENDC} Просмотр активных процессов")
        print(f"{Colors.BOLD}{Colors.BLUE}4.{Colors.ENDC} Мониторинг логов")
        print(f"{Colors.BOLD}{Colors.BLUE}5.{Colors.ENDC} Управление сервисами")
        print(f"{Colors.BOLD}{Colors.BLUE}6.{Colors.ENDC} Подробная информация о системе")
        print(f"{Colors.BOLD}{Colors.BLUE}7.{Colors.ENDC} Применить автоматические исправления")
        print(f"{Colors.BOLD}{Colors.BLUE}8.{Colors.ENDC} Проверить обновления системы")
        print(f"{Colors.BOLD}{Colors.BLUE}9.{Colors.ENDC} О программе")
        print(f"{Colors.BOLD}{Colors.BLUE}0.{Colors.ENDC} Выход")
        
        print("\nВыберите действие (0-9): ", end="")
        choice = input()
        
        if choice == "1":
            run_diagnostics()
        elif choice == "2":
            # Запуск мониторинга ресурсов через top или htop
            if which('htop'):
                os.system('htop')
            elif which('top'):
                os.system('top')
            else:
                print("Команды htop и top недоступны")
                input("\nНажмите Enter для продолжения...")
        elif choice == "3":
            # Просмотр процессов
            clear_screen()
            print_header("Активные процессы")
            print_process_info()
            input("\nНажмите Enter для продолжения...")
        elif choice == "4":
            # Мониторинг логов
            select_log_file()
        elif choice == "5":
            # Управление сервисами
            view_service_details()
        elif choice == "6":
            # Подробная информация о системе
            show_system_details()
        elif choice == "7":
            # Применение автоматических исправлений
            clear_screen()
            print_header("Применение автоматических исправлений")
            print("Предупреждение: Автоматические исправления могут изменить настройки системы.")
            print("Хотите продолжить? (y/n): ", end="")
            confirm = input().lower()
            
            if confirm == "y":
                global fix_enabled
                fix_enabled = True
                
                # Очищаем старые данные
                issues = []
                warnings = []
                suggestions = []
                fixes_applied = []
                
                # Запускаем проверки для выявления проблем
                get_basic_info()
                get_cpu_info()
                get_memory_info()
                get_disk_info()
                get_process_info()
                get_network_info()
                check_services()
                check_log_errors()
                check_open_files()
                
                # Применяем исправления
                apply_quick_fixes()
                
                # Выводим результат
                clear_screen()
                print_header("Результаты исправлений")
                print_fixes()
                input("\nНажмите Enter для продолжения...")
        elif choice == "8":
            # Проверка обновлений
            clear_screen()
            print_header("Проверка обновлений системы")
            
            if which('apt'):
                print("Обновление списка пакетов...")
                apt_update = run_command("apt update")
                if apt_update:
                    print(apt_update)
                
                print("\nДоступные обновления:")
                apt_list = run_command("apt list --upgradable")
                if apt_list:
                    print(apt_list)
            elif which('yum'):
                print("Проверка обновлений...")
                yum_check = run_command("yum check-update")
                if yum_check:
                    print(yum_check)
            elif which('dnf'):
                print("Проверка обновлений...")
                dnf_check = run_command("dnf check-update")
                if dnf_check:
                    print(dnf_check)
            else:
                print("Не удалось определить пакетный менеджер.")
            
            input("\nНажмите Enter для продолжения...")
        elif choice == "9":
            # О программе
            clear_screen()
            print_header("О программе")
            print(f"{Colors.BOLD}ServerRescue Pro v{VERSION}{Colors.ENDC}")
            print("Интеллектуальный диагностический инструмент для Linux-серверов")
            print("\nОригинальный автор: Владислав Павлович - pavlovich.live")
            print("\nПо вопросам функционирования и поддержки, пожалуйста, обращайтесь к автору: TG @femid00")
            print("Написано на Python для лучшей совместимости и расширения функциональности")
            print("\nСерверный мониторинг и диагностика в режиме реального времени")
            print("© 2025. Все права защищены.")
            input("\nНажмите Enter для продолжения...")
        elif choice == "0":
            clear_screen()
            print(f"{Colors.BOLD}{Colors.GREEN}Спасибо за использование ServerRescue!{Colors.ENDC}")
            print("Хорошего дня!")
            break
        else:
            print(f"{Colors.BOLD}{Colors.RED}Неверный выбор. Пожалуйста, попробуйте снова.{Colors.ENDC}")
            input("\nНажмите Enter для продолжения...")

def signal_handler(sig, frame):
    """Обработчик сигналов для корректного завершения."""
    print("\nПрерывание. Завершение работы...")
    sys.exit(0)

def main():
    """Главная функция программы."""
    global logger, fix_enabled, verbose_mode, skip_menu
    
    # Настройка обработчика сигналов
    signal.signal(signal.SIGINT, signal_handler)
    
    # Парсинг аргументов командной строки
    parser = argparse.ArgumentParser(description="ServerRescue Pro - Интеллектуальный диагностический инструмент для Linux серверов")
    parser.add_argument("--fix", action="store_true", help="Автоматически применять исправления для найденных проблем")
    parser.add_argument("--verbose", action="store_true", help="Показывать подробную информацию о процессе диагностики")
    parser.add_argument("--skip-menu", action="store_true", help="Запустить полную диагностику без отображения меню")
    args = parser.parse_args()
    
    fix_enabled = args.fix
    verbose_mode = args.verbose
    skip_menu = args.skip_menu
    
    # Инициализация логгера
    os.makedirs("serverrescue_logs", exist_ok=True)
    logger = Logger(log_file="serverrescue_logs/serverrescue.log", verbose=verbose_mode)
    
    # Проверка прав суперпользователя
    if not is_root():
        print(f"{Colors.YELLOW}Предупреждение: Скрипт запущен без прав суперпользователя. Некоторые функции могут быть недоступны.{Colors.ENDC}")
        print(f"Рекомендуется запускать с sudo: {Colors.BOLD}sudo {sys.argv[0]}{Colors.ENDC}\n")
        
        print("Хотите продолжить без прав суперпользователя? (y/n): ", end="")
        confirm = input().lower()
        
        if confirm != "y":
            print("Завершение работы...")
            sys.exit(1)
    
    # Вывод логотипа при запуске
    show_logo()
    
    # Получаем базовую информацию о системе
    get_basic_info()
    
    # Запуск диагностики или меню в зависимости от параметров
    if skip_menu:
        run_diagnostics()
    else:
        # Переходим в главное меню
        show_main_menu()

if __name__ == "__main__":
    main()