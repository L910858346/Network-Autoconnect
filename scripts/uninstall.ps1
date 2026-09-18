#Requires -Version 5.1
<#
    uninstall.ps1 —— 卸载开机自启动
    用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 [-Purge]
#>
[CmdletBinding()]
param([switch]$Purge)

$root = Split-Path -Parent $PSScriptRoot
$taskName = 'Unicom-AutoConnect'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Unicom-AutoConnect.lnk'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "[卸载] 已删除计划任务 $taskName" -ForegroundColor Green
} else {
    Write-Host '[卸载] 未发现计划任务，跳过。'
}

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host '[卸载] 已删除启动项。' -ForegroundColor Green
} else {
    Write-Host '[卸载] 未发现启动项，跳过。'
}

if ($Purge) {
    $logs = Join-Path $root 'logs'
    if (Test-Path -LiteralPath $logs) { Remove-Item -LiteralPath $logs -Recurse -Force; Write-Host '[卸载] 已删除日志与状态文件。' }
}
Write-Host '[卸载] 完成。' -ForegroundColor Green
