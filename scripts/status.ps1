#Requires -Version 5.1
<#
    status.ps1 —— 一键诊断
    用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\status.ps1
#>
[CmdletBinding()]
param([string]$ConfigPath = '')

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\CampusNet.psm1') -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $root 'config\config.json'
    if (-not (Test-Path -LiteralPath $ConfigPath)) { $ConfigPath = Join-Path $root 'config\config.example.json' }
}
$config = Get-CampusConfig -Path $ConfigPath
$logFile = Get-CampusLogFile -Config $config

Show-CampusDiagnostics -Config $config -LogFile $logFile

Write-Host '------------ 开机自启动 ------------' -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName 'Unicom-AutoConnect' -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'Unicom-AutoConnect' -ErrorAction SilentlyContinue
    Write-Host ("计划任务      : 已注册（状态 {0}）" -f $task.State)
    if ($info) {
        Write-Host ("上次运行      : {0}   结果 0x{1:X}" -f $info.LastRunTime, $info.LastTaskResult)
        Write-Host ("下次运行      : {0}" -f $info.NextRunTime)
    }
} else {
    Write-Host '计划任务      : 未注册（可运行 scripts\install.ps1）'
}
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Unicom-AutoConnect.lnk'
Write-Host ("启动文件夹    : {0}" -f $(if (Test-Path -LiteralPath $shortcutPath) { '已安装快捷方式' } else { '未安装' }))
Write-Host ''

Write-Host '------------ 最近日志（15 行）------------' -ForegroundColor Cyan
$logDir = [string]$config.logging.directory
$latest = Get-ChildItem -LiteralPath $logDir -Filter 'connect-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) {
    Get-Content -LiteralPath $latest.FullName -Tail 15 -Encoding UTF8
    Write-Host ("（文件：{0}）" -f $latest.FullName) -ForegroundColor DarkGray
} else {
    Write-Host '（还没有日志，先跑一次 run-now.cmd）'
}
Write-Host ''
