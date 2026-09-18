#Requires -Version 5.1
<#
    install.ps1 —— 安装开机自启动

    两种模式：
      Task           计划任务，登录后延迟若干秒运行（默认，可自动重试）
      StartupFolder  在“启动”文件夹放快捷方式（完全不需要管理员权限）

    用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
      ... -Mode StartupFolder
      ... -DelaySeconds 30
      ... -RepeatMinutes 30        每 30 分钟再检查一次（掉线自动重连）
      ... -DryRun                  只打印将要执行的操作
      ... -Uninstall               卸载
#>
[CmdletBinding()]
param(
    [ValidateSet('Task', 'StartupFolder')][string]$Mode = 'Task',
    [string]$ConfigPath = '',
    [int]$DelaySeconds = 20,
    [int]$RepeatMinutes = 0,
    [switch]$DryRun,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $root 'src\Connect-CampusNet.ps1'
$taskName = 'Unicom-AutoConnect'
$shortcutName = 'Unicom-AutoConnect.lnk'

if (-not (Test-Path -LiteralPath $mainScript)) { throw "找不到主脚本：$mainScript" }

if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $example = Join-Path $root 'config\config.example.json'
    if (Test-Path -LiteralPath $example) {
        Copy-Item -LiteralPath $example -Destination $ConfigPath -Force
        Write-Host '[安装] 已由 config.example.json 生成 config\config.json' -ForegroundColor Yellow
    }
}

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argumentLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ConfigPath "{1}"' -f $mainScript, $ConfigPath
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir $shortcutName

function Remove-Existing {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        if ($DryRun) { Write-Host "[DryRun] 删除计划任务 $taskName" }
        else { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host "[安装] 已删除旧计划任务 $taskName" }
    }
    if (Test-Path -LiteralPath $shortcutPath) {
        if ($DryRun) { Write-Host "[DryRun] 删除启动项 $shortcutPath" }
        else { Remove-Item -LiteralPath $shortcutPath -Force; Write-Host '[安装] 已删除旧启动项' }
    }
}

if ($Uninstall) {
    Remove-Existing
    Write-Host '[安装] 卸载完成。' -ForegroundColor Green
    exit 0
}

Remove-Existing

if ($Mode -eq 'Task') {
    Write-Host '[安装] 正在注册计划任务...' -ForegroundColor Cyan
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $argumentLine -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    try { $trigger.Delay = ('PT{0}S' -f [math]::Max(0, $DelaySeconds)) } catch { Write-Warning "无法设置延迟：$($_.Exception.Message)" }

    if ($RepeatMinutes -gt 0) {
        try {
            $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes)).Repetition
            $trigger.Repetition = $rep
        } catch { Write-Warning "无法设置重复间隔：$($_.Exception.Message)" }
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    try {
        # 注意：这里必须是 ISO8601 字符串。赋 TimeSpan 会被序列化成 00:01:00，
        # 会让 Register-ScheduledTask 报 task XML incorrectly formatted 的错误。
        $settings.RestartInterval = 'PT1M'
        $settings.RestartCount = 3
    } catch { }

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    if ($DryRun) {
        Write-Host '[DryRun] 将要注册计划任务：' -ForegroundColor Yellow
        Write-Host "         名称   : $taskName"
        Write-Host "         执行   : $psExe"
        Write-Host "         参数   : $argumentLine"
        Write-Host "         触发   : 登录时，延迟 $DelaySeconds 秒"
        Write-Host "         重复   : $(if ($RepeatMinutes -gt 0) { "每 $RepeatMinutes 分钟" } else { '无' })"
        exit 0
    }

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description '开机自动连接中国联通校园网并用默认浏览器打开认证门户' -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "计划任务注册失败：$($_.Exception.Message)"
    }

    # Register-ScheduledTask 有时只写非终止错误，必须回查确认是否真的注册上了
    $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($registered) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host "[安装] 计划任务 $taskName 注册成功（登录后 $DelaySeconds 秒自动运行）。" -ForegroundColor Green
        if ($info) { Write-Host ("         下次运行时间：{0}" -f $info.NextRunTime) }
    } else {
        Write-Host '[安装] 计划任务未能注册，改用“启动”文件夹方式...' -ForegroundColor Yellow
        $Mode = 'StartupFolder'
    }
}

if ($Mode -eq 'StartupFolder') {
    if ($DryRun) {
        Write-Host "[DryRun] 将创建快捷方式 $shortcutPath -> $psExe $argumentLine" -ForegroundColor Yellow
        exit 0
    }
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = $psExe
    $sc.Arguments = $argumentLine
    $sc.WorkingDirectory = $root
    $sc.WindowStyle = 7
    $sc.Description = '校园网自动连接（联通）'
    $sc.Save()
    Write-Host "[安装] 已创建启动项：$shortcutPath" -ForegroundColor Green
}

Write-Host ''
Write-Host '提示：现在可以手动跑一次验证：' -ForegroundColor Cyan
Write-Host ('      powershell -NoProfile -ExecutionPolicy Bypass -File "' + $mainScript + '" -ProbeOnly')
Write-Host ''
