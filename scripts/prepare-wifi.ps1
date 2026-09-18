#Requires -Version 5.1
<#
    prepare-wifi.ps1 —— 无线配置准备 / 检查
    -ImportXml / -SetAutoConnect / -SetPriority 需要管理员权限；只做检查则不需要。

    用法：
      ... -Ssid ChinaUnicom-5G                         只显示该网络的配置状态与建议
      ... -Ssid ChinaUnicom-5G -ImportXml .\Unicom.xml 导入已导出的无线配置
      ... -Ssid ChinaUnicom-5G -SetAutoConnect         设为自动连接（推荐）
      ... -Ssid ChinaUnicom-5G -SetPriority            把该网络在列表里置顶
#>
[CmdletBinding()]
param(
    [string]$Ssid = 'ChinaUnicom-5G',
    [string]$InterfaceName = '',
    [string]$ImportXml = '',
    [switch]$SetAutoConnect,
    [switch]$SetPriority
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\CampusNet.psm1') -Force

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Admin
$profiles = @(Get-CampusWlanProfiles)
$exists = $profiles -contains $Ssid

Write-Host ''
Write-Host '============ 无线配置检查 ============' -ForegroundColor Cyan
Write-Host ("目标网络      : $Ssid")
Write-Host ("配置文件存在  : {0}" -f $(if ($exists) { '是' } else { '否' }))
$wl = Get-WlanStatus
Write-Host ("当前连接      : {0}" -f $(if ($wl.Ssid) { $wl.Ssid } else { '(未连接)' }))
Write-Host ("管理员权限    : {0}" -f $(if ($isAdmin) { '是' } else { '否' }))
Write-Host '=====================================' -ForegroundColor Cyan

if ($ImportXml) {
    if (-not (Test-Path -LiteralPath $ImportXml)) { throw "找不到 XML 文件：$ImportXml" }
    $netshArgs = @('wlan', 'add', 'profile', "filename=$ImportXml", 'user=all')
    if ($InterfaceName) { $netshArgs += "interface=$InterfaceName" }
    & netsh @netshArgs
    Write-Host '[无线] 导入命令已执行。' -ForegroundColor Green
}

if ($SetAutoConnect) {
    $netshArgs = @('wlan', 'set', 'profileparameter', "name=$Ssid", 'connectionmode=auto')
    if ($InterfaceName) { $netshArgs += "interface=$InterfaceName" }
    & netsh @netshArgs
    Write-Host '[无线] 已设置自动连接。' -ForegroundColor Green
}

if ($SetPriority) {
    $netshArgs = @('wlan', 'set', 'profileorder', "name=$Ssid", 'priority=1')
    if ($InterfaceName) { $netshArgs += "interface=$InterfaceName" }
    & netsh @netshArgs
    Write-Host '[无线] 已把该网络置顶。' -ForegroundColor Green
}

if (-not $exists) {
    Write-Host ''
    Write-Host '该无线还没在本机连过，Windows 里没有它的配置文件。两种做法：' -ForegroundColor Yellow
    Write-Host '  1) 手动点一次任务栏 Wi-Fi 图标连上它（输一次密码），之后 Windows 会记住并自动连接；'
    Write-Host '  2) 在别的电脑上执行 netsh wlan export profile name="' -NoNewline
    Write-Host $Ssid -NoNewline
    Write-Host '" folder=. 导出 XML，拷过来后执行：'
    Write-Host ('     powershell -ExecutionPolicy Bypass -File .\scripts\prepare-wifi.ps1 -Ssid "' + $Ssid + '" -ImportXml .\' + $Ssid + '.xml')
}
Write-Host ''
