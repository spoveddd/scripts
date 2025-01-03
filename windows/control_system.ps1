# Скрипт для управления системой Windows

function Show-SystemInfo {
    Write-Host "Состояние системы:" -ForegroundColor Green
    $cpuUsage = (Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Minimum).Minimum
    Write-Host "CPU Usage: $cpuUsage%"
    Write-Host "Memory Usage:"
    Get-WmiObject Win32_OperatingSystem | ForEach-Object {
        $usedMemory = $_.TotalVisibleMemorySize - $_.FreePhysicalMemory
        $usedMemoryGB = [math]::round($usedMemory / 1MB, 2)  # Переводим в ГБ
        $totalMemoryGB = [math]::round($_.TotalVisibleMemorySize / 1MB, 2)  # Переводим в ГБ
        Write-Host "Used Memory: $usedMemoryGB GB / Total: $totalMemoryGB GB"
    }
    Write-Host "Disk Usage:"
    Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{Name = 'Used(GB)'; Expression = { [math]::round($_.Used / 1GB, 2) } }, @{Name = 'Free(GB)'; Expression = { [math]::round($_.Free / 1GB, 2) } }, @{Name = 'Total(GB)'; Expression = { [math]::round($_.Used / 1GB + $_.Free / 1GB, 2) } } | Format-Table -AutoSize
}


function Manage-Services {
    Write-Host "Хотите вывести список доступных служб? (да/нет)"
    $showList = Read-Host

    if ($showList -eq 'да') {
        Write-Host "Доступные службы:"
        # Выводим все службы
        Get-Service | Select-Object Name, DisplayName | Format-Table -AutoSize
    }

    Write-Host "`nВведите название службы для управления:"
    $serviceName = Read-Host

    # Проверяем, существует ли указанная служба
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -eq $null) {
        Write-Host "Служба с именем '$serviceName' не найдена. Попробуйте снова." -ForegroundColor Red
        return
    }

    Write-Host "1. Start Service"
    Write-Host "2. Stop Service"
    Write-Host "3. Restart Service"
    $choice = Read-Host "Выберите действие"
    
    switch ($choice) {
        1 {
            Start-Service -Name $serviceName
            Write-Host "Служба запущена." -ForegroundColor Green
        }
        2 {
            Stop-Service -Name $serviceName
            Write-Host "Служба остановлена." -ForegroundColor Green
        }
        3 {
            Restart-Service -Name $serviceName
            Write-Host "Служба перезапущена." -ForegroundColor Green
        }
        default {
            Write-Host "Неверный выбор." -ForegroundColor Red
        }
    }
}

function Cleanup-TempFiles {
    Write-Host "Очистка временных файлов..." -ForegroundColor Yellow

    # Получаем все файлы в каталоге TEMP
    $files = Get-ChildItem -Path $env:TEMP -Recurse -ErrorAction SilentlyContinue

    foreach ($file in $files) {
        try {
            Remove-Item -Path $file.FullName -Force -Recurse -ErrorAction Stop
            Write-Host "Файл удален: $($file.FullName)" -ForegroundColor Green
        }
        catch {
            Write-Host "Не удалось удалить файл: $($file.FullName). Причина: $_" -ForegroundColor Red
        }
    }

    Write-Host "Очистка завершена." -ForegroundColor Green
}

function Ping-Hosts {
    Write-Host "Введите список хостов через запятую (например, google.com, yandex.ru):"
    $hosts = Read-Host
    $hosts.Split(',') | ForEach-Object {
        Write-Host "Проверяем доступность: $_"
        Test-Connection -ComputerName $_ -Count 2 | Select-Object Address, Status
    }
}

# Основное меню
while ($true) {
    Write-Host "`nВыберите действие:" -ForegroundColor Cyan
    Write-Host "1. Проверить состояние системы"
    Write-Host "2. Управление службами"
    Write-Host "3. Очистка временных файлов"
    Write-Host "4. Проверка доступности хостов"
    Write-Host "5. Выйти"
    $choice = Read-Host "Ваш выбор"
    
    switch ($choice) {
        1 { Show-SystemInfo }
        2 { Manage-Services }
        3 { Cleanup-TempFiles }
        4 { Ping-Hosts }
        5 { Write-Host "Выход..."; break }
        default { Write-Host "Неверный выбор. Попробуйте снова." }
    }
}
