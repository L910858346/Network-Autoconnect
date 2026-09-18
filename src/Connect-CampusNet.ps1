#Requires -Version 5.1
<#
    Connect-CampusNet.ps1
    开机 / 登录后自动连接中国联通校园网，并用系统默认浏览器打开认证门户。

    用法：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Connect-CampusNet.ps1
        ... -ProbeOnly            只探测，不做任何改动
        ... -NoBrowser            只连无线，不打开浏览器
        ... -Force                忽略“重复打开门户”冷却
        ... -TimeoutMinutes 20    本轮总超时（默认取配置）
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$ProbeOnly,
    [switch]$NoBrowser,
    [switch]$Force,
    [int]$TimeoutMinutes = 0
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'CampusNet.psm1') -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $root 'config\config.json'
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $ConfigPath = Join-Path $root 'config\config.example.json'
    }
}

$config = Get-CampusConfig -Path $ConfigPath
$logFile = Get-CampusLogFile -Config $config

if ($ProbeOnly) {
    Show-CampusDiagnostics -Config $config -LogFile $logFile
    $probe = Invoke-CampusConnectivityCheck -Config $config
    if ($probe.Online) { exit 0 } else { exit 1 }
}

Write-CampusLog -Message '------------------------------------------------------------' -Level DEBUG -LogFile $logFile
Write-CampusLog -Message "校园网自动连接启动（配置：$ConfigPath）" -LogFile $logFile

# 1. 等待无线网卡就绪（开机阶段驱动加载需要时间）
if (-not (Wait-CampusWlanReady -TimeoutSeconds 90)) {
    Write-CampusLog -Message '未检测到可用的无线网卡，退出。' -Level ERROR -LogFile $logFile
    exit 2
}

$timeoutMinutes = $TimeoutMinutes
if ($timeoutMinutes -le 0) { $timeoutMinutes = [int]$config.overallTimeoutMinutes }
if ($timeoutMinutes -le 0) { $timeoutMinutes = 15 }
$deadline = (Get-Date).AddMinutes($timeoutMinutes)

$retry = [int]$config.retryIntervalSeconds
if ($retry -le 0) { $retry = 10 }

# 安全阀：自动登录最多尝试几次。学校门户通常在连续失败若干次后锁定账号，
# 而主循环默认每 10 秒重试一次、总时长 15 分钟 —— 不设上限就是几十次失败登录。
$loginAttempts = 0
$maxLoginAttempts = 3
try { $maxLoginAttempts = [int]$config.autoLogin.maxAttempts } catch { $maxLoginAttempts = 3 }
if ($maxLoginAttempts -le 0) { $maxLoginAttempts = 3 }

# 2. 先连上目标无线网络
Connect-CampusWifi -Config $config -LogFile $logFile | Out-Null

$attempt = 0
while ((Get-Date) -lt $deadline) {
    $attempt++
    $left = [int](($deadline - (Get-Date)).TotalSeconds)
    Write-CampusLog -Message "第 $attempt 次检查（剩余 $left 秒）" -LogFile $logFile

    # 2.1 无线掉了就重连
    $wl = Get-WlanStatus
    $onTarget = $false
    foreach ($t in @($config.ssid)) { if ($wl.Ssid -ieq $t) { $onTarget = $true } }
    if ((-not $wl.Connected) -or (-not $onTarget)) {
        $shown = $wl.Ssid
        if (-not $shown) { $shown = '未连接' }
        Write-CampusLog -Message "当前无线：$shown，需要重新连接" -Level WARN -LogFile $logFile
        Connect-CampusWifi -Config $config -LogFile $logFile | Out-Null
        Start-Sleep -Seconds 2
    }

    # 2.2 是否已联网
    $check = Invoke-CampusConnectivityCheck -Config $config -LogFile $logFile
    if ($check.Online) {
        Write-CampusLog -Message "网络已可用：$($check.Detail)" -Level OK -LogFile $logFile
        $state = Get-CampusState
        $state.lastOnlineTime = (Get-Date).ToString('o')
        $state.lastSsid = $wl.Ssid
        Save-CampusState -State $state
        Write-CampusLog -Message '校园网连接完成，退出。' -Level OK -LogFile $logFile
        exit 0
    }

    # 2.3 可选：直接向门户提交账号密码（真正的零点击自动登录）
    if ($config.autoLogin.enabled) {
        if ($loginAttempts -lt $maxLoginAttempts) {
            $loginAttempts++
            Write-CampusLog -Message "自动登录尝试 $loginAttempts / $maxLoginAttempts" -LogFile $logFile
            Invoke-CampusAutoLogin -Config $config -LogFile $logFile | Out-Null
        } elseif ($loginAttempts -eq $maxLoginAttempts) {
            $loginAttempts++
            if ((-not $NoBrowser) -and $config.browser.enabled) {
                Write-CampusLog -Message "自动登录已连续失败 $maxLoginAttempts 次，为避免账号被锁定，本轮不再重试，改用浏览器方式。" -Level ERROR -LogFile $logFile
            } else {
                Write-CampusLog -Message "自动登录已连续失败 $maxLoginAttempts 次，为避免账号被锁定，本轮不再提交登录；浏览器方式已关闭，仅持续复检联网状态直到超时。" -Level ERROR -LogFile $logFile
            }
        }
        Start-Sleep -Seconds 3
        $check2 = Invoke-CampusConnectivityCheck -Config $config -LogFile $logFile
        if ($check2.Online) {
            Write-CampusLog -Message "门户自动登录成功：$($check2.Detail)" -Level OK -LogFile $logFile
            $state = Get-CampusState
            $state.lastOnlineTime = (Get-Date).ToString('o')
            $state.lastSsid = $wl.Ssid
            Save-CampusState -State $state
            exit 0
        }
        if ((-not $NoBrowser) -and $config.browser.enabled) {
            Write-CampusLog -Message '自动登录后仍未联网，转用浏览器方式' -Level WARN -LogFile $logFile
        } else {
            Write-CampusLog -Message '自动登录后仍未联网，浏览器方式已关闭，等待下一轮复检' -Level WARN -LogFile $logFile
        }
    }

    # 2.4 用系统默认浏览器打开认证门户
    if ((-not $NoBrowser) -and $config.browser.enabled) {
        $url = [string]$config.browser.url
        if (-not $url) { $url = [string]$check.PortalUrl }
        if (-not $url) { $url = [string]$config.browser.fallbackUrl }
        Write-CampusLog -Message "门户地址：$url （探测结果：$($check.Detail)）" -LogFile $logFile
        Open-CampusPortal -Url $url -Config $config -Force:$Force -LogFile $logFile | Out-Null

        $wait = 0
        try { $wait = [int]$config.browser.waitAfterOpenSeconds } catch { $wait = 0 }
        if ($wait -gt 0) {
            $waitDeadline = (Get-Date).AddSeconds($wait)
            while ((Get-Date) -lt $waitDeadline) {
                Start-Sleep -Seconds 5
                $c = Invoke-CampusConnectivityCheck -Config $config -LogFile $logFile
                if ($c.Online) {
                    Write-CampusLog -Message "浏览器认证完成，网络已可用：$($c.Detail)" -Level OK -LogFile $logFile
                    $state = Get-CampusState
                    $state.lastOnlineTime = (Get-Date).ToString('o')
                    Save-CampusState -State $state
                    exit 0
                }
            }
        }
    }

    if ((Get-Date).AddSeconds($retry) -ge $deadline) { break }
    Start-Sleep -Seconds $retry
}

Write-CampusLog -Message "在 $timeoutMinutes 分钟内未能完成认证，退出（可手动在浏览器里登录）。" -Level ERROR -LogFile $logFile
exit 1
