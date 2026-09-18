#Requires -Version 5.1
<#
    publish-to-github.ps1 —— 把本地仓库发布到 GitHub

    为什么单独做一个脚本：GitHub 在国内校园网下经常连不通，
    所以这里把「授权 + 建仓库 + 推送」打包成一条可反复执行的命令，
    网络一好就能直接跑，失败也能安全重跑（幂等）。

    用法：
      ...                        公开仓库，名字默认 unicom-autoconnect
      ... -Private               私有仓库
      ... -Name my-repo          自定义仓库名
      ... -Retry                 网络不稳时反复重试，直到成功或达到次数上限
      ... -MaxAttempts 30 -IntervalSeconds 60   重试参数
#>
[CmdletBinding()]
param(
    [string]$Name = 'unicom-autoconnect',
    [switch]$Private,
    [switch]$Retry,
    [int]$MaxAttempts = 30,
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

function Find-Gh {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $candidates = @(
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )
    if ($pf86) { $candidates += (Join-Path $pf86 'GitHub CLI\gh.exe') }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return ''
}

$gh = Find-Gh
if (-not $gh) {
    Write-Host '[发布] 没找到 gh CLI。安装：winget install --id GitHub.cli -e' -ForegroundColor Red
    exit 2
}
Write-Host ("[发布] gh: {0}" -f $gh) -ForegroundColor Gray

function Test-GitHubReachable {
    try {
        $null = Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0 -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ge 300) { return $true }
        return $false
    }
}

# 1. 工作区必须干净，避免推上去少东西
$dirty = (& git status --porcelain) 2>$null
if ($dirty) {
    Write-Host '[发布] 工作区有未提交的改动，先提交再发布：' -ForegroundColor Yellow
    & git status --short
    exit 3
}

# 2. 授权
& $gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host '[发布] 还没登录 GitHub，开始授权（会打开浏览器，把终端里的一次性代码粘进去）...' -ForegroundColor Cyan
    & $gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[发布] 授权失败（多半是 github.com 连不上）。' -ForegroundColor Red
        Write-Host '       校园网经常掐 GitHub：可以换手机热点、开代理，或过一会儿重试。' -ForegroundColor Yellow
        exit 4
    }
}
Write-Host '[发布] GitHub 授权正常。' -ForegroundColor Green

$visibility = '--public'
if ($Private) { $visibility = '--private' }

# 3. 建仓库 + 推送（幂等：仓库已存在就只推送）
$attempt = 0
while ($true) {
    $attempt++
    Write-Host ("[发布] 第 {0} 次尝试..." -f $attempt) -ForegroundColor Cyan

    if (-not (Test-GitHubReachable)) {
        Write-Host '       github.com 连不通，先不折腾。' -ForegroundColor Yellow
    } else {
        $hasRemote = (& git remote) -contains 'origin'
        if (-not $hasRemote) {
            & $gh repo create $Name $visibility --source . --remote origin --push
        } else {
            & git push -u origin main
        }
        if ($LASTEXITCODE -eq 0) {
            $url = (& $gh repo view --json url -q .url) 2>$null
            Write-Host ''
            Write-Host ('[发布] 成功！仓库地址：{0}' -f $url) -ForegroundColor Green
            exit 0
        }
        Write-Host '       推送失败（网络或权限问题）。' -ForegroundColor Yellow
    }

    if (-not $Retry -or $attempt -ge $MaxAttempts) { break }
    Write-Host ("       {0} 秒后重试（最多 {1} 次）..." -f $IntervalSeconds, $MaxAttempts) -ForegroundColor DarkGray
    Start-Sleep -Seconds $IntervalSeconds
}

Write-Host ''
Write-Host '[发布] 没成功。本地提交都在，随时可以重跑本脚本。' -ForegroundColor Red
Write-Host '       如果一直连不上 github.com，建议：' -ForegroundColor Yellow
Write-Host '         1) 用手机热点（校园网常掐 GitHub，蜂窝网络一般没问题）'
Write-Host '         2) 开启你自己的代理软件后重跑'
Write-Host '         3) 先推到 Gitee，之后在 GitHub 网页用 Import repository 从 Gitee 导入'
exit 1
