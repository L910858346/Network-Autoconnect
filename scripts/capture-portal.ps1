#Requires -Version 5.1
<#
    capture-portal.ps1 —— 门户“抓包助手”

    作用：在校园网未认证时自动找到认证门户、下载登录页，解析出表单提交地址与所有字段名，
          直接生成可写进 config.json 的 autoLogin 配置段。

    用法：
      ...                              自动探测门户（当前处于“未认证”状态时才有效）
      ... -Url http://10.0.0.1/portal   手动指定门户地址
      ... -Write                       解析结果直接写进 config\config.json（保留已填的账号密码）
      ... -NoWait                      不等待，只试一次

    说明：如果当前已经能上网，运营商不会跳门户，脚本会提示；此时可以先断开 Wi-Fi 再重连触发，
          或者把浏览器里看到的门户地址用 -Url 传进来。
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$Url = '',
    [switch]$Write,
    [switch]$NoWait
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\CampusNet.psm1') -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $root 'config\config.json'
    if (-not (Test-Path -LiteralPath $ConfigPath)) { $ConfigPath = Join-Path $root 'config\config.example.json' }
}
$config = Get-CampusConfig -Path $ConfigPath
$logFile = Get-CampusLogFile -Config $config

# 输出同时留档到 logs\capture-last.txt：这样双击运行时不需要复制粘贴，
# 也不用截图，任何人事后（或让 AI）直接读文件就能看到结果。
$report = New-Object System.Collections.Generic.List[string]
$reportPath = Join-Path $root 'logs\capture-last.txt'
function Add-Report {
    param([string]$Text = '', [string]$Color = 'Gray')
    $script:report.Add($Text)
    if ($Color -eq 'Gray') { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}

Write-Host ''
Write-Host '================ 校园网门户抓包助手 ================' -ForegroundColor Cyan

$snapshot = $null
$deadline = (Get-Date).AddSeconds($(if ($NoWait) { 0 } else { 30 }))
while ($true) {
    $snapshot = Get-CampusPortalSnapshot -Config $config -Url $Url -SaveHtmlDir (Join-Path $root 'logs') -LogFile $logFile
    # 必须找到“密码框”才算抓到真正的登录表单：门户首屏常常只是框架页或者几句提示，
    # 光看“有没有 input”会误判。
    if ($snapshot.Form.PasswordField) { break }
    if ((Get-Date) -ge $deadline) { break }
    Write-Host '  还没抓到登录表单（没找到密码框），10 秒后重试（可先在浏览器里打开一次门户页面）...' -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

Add-Report ''
Add-Report ("门户地址      : {0}" -f $snapshot.PortalUrl)
Add-Report ("最终地址      : {0}" -f $snapshot.FinalUrl)
Add-Report ("HTTP 状态     : {0}" -f $snapshot.Status)
Add-Report ("框架层级      : {0}" -f $snapshot.Depth)
if ($snapshot.HtmlPath) { Add-Report ("页面已保存    : {0}" -f $snapshot.HtmlPath) }
Add-Report ''
Add-Report ('表单提交地址  : {0}' -f $(if ($snapshot.Form.Action) { $snapshot.Form.Action } else { '(HTML 里没有 form action，需要看 F12)' }))
Add-Report ('提交方法      : {0}' -f $snapshot.Form.Method)
Add-Report ('账号字段      : {0}' -f $(if ($snapshot.Form.UsernameField) { $snapshot.Form.UsernameField } else { '(未识别)' }))
Add-Report ('密码字段      : {0}' -f $(if ($snapshot.Form.PasswordField) { $snapshot.Form.PasswordField } else { '(未识别)' }))
Add-Report ''
if ($snapshot.Form.Fields.Count -gt 0) {
    Add-Report '页面上的表单字段：' 'Cyan'
    foreach ($f in $snapshot.Form.Fields) {
        Add-Report ('  - {0,-26} type={1,-10} value={2}' -f $f.name, $f.type, $f.value)
    }
}

$exitCode = 0
if (-not $snapshot.Form.PasswordField) {
    Add-Report '这次没抓到密码框，说明拿到的不是真正的登录表单。' 'Yellow'
    Add-Report '最常见原因：当前已经联网 —— 门户在已认证状态下只返回一个提示页，登录表单根本不存在。' 'Yellow'
    Add-Report '做法：在门户页面上点“下线”，然后重跑本脚本；或用 -Url 指定地址栏里的门户网址。' 'Yellow'
    $exitCode = 1
}

if ($exitCode -eq 0) {
    # 表单 action 常常是空的，真实提交地址写在 JS 里，扫一遍
    $discovered = Get-CampusFormActionFromScripts -Html $snapshot.Body -Base $snapshot.FinalUrl
    if ($discovered) { Add-Report ("从 JS 里发现的真实提交地址：{0}" -f $discovered) 'Green' }

    $relativeSubmit = ''
    if ($discovered) {
        try { $relativeSubmit = ([System.Uri]$discovered).PathAndQuery } catch { $relativeSubmit = $discovered }
    }

    # 推荐用 portal-form 模式：每次登录前现抓门户页拿新的一次性令牌，
    # 这样带 paramStr 之类的门户才不会因为令牌过期而失败。
    $suggest = [ordered]@{
        enabled        = $false
        mode           = 'portal-form'
        portalUrl      = ''
        submitUrl      = $relativeSubmit
        username       = ''
        password       = ''
        usernameField  = [string]$snapshot.Form.UsernameField
        passwordField  = [string]$snapshot.Form.PasswordField
        extraFields    = @{}
        useReferer     = $true
        loginUrl       = ''
        method         = [string]$snapshot.Form.Method
        contentType    = 'application/x-www-form-urlencoded'
        preRequestUrl  = ''
        form           = @{}
        extraHeaders   = @{}
        timeoutSeconds = 20
    }

    # 锐捷 ePortal 门户（/eportal/index.jsp，联通校园网常见）：可见表单并不直接提交，
    # 登录由页面 JS POST 到 InterFace.do?method=login，portal-form 抓字段的方式对它无效，
    # 需要用专用的 eportal 模式（脚本会自动复现 doauthen 的双重编码提交）。
    $isEportal = ($snapshot.FinalUrl -match '(?i)/eportal/') -or `
                 ($snapshot.PortalUrl -match '(?i)/eportal/') -or `
                 ($snapshot.Body -match '(?i)InterFace\.do\?method=login') -or `
                 ($snapshot.Body -match '(?i)AuthInterFace')
    $modeHint = 'portal-form = 每次登录前先抓门户页拿新令牌再提交（带 paramStr 的门户必须用这个）。'
    if ($isEportal) {
        $suggest.mode = 'eportal'
        $suggest.method = 'POST'
        $suggest.submitUrl = ''
        $suggest.usernameField = ''
        $suggest.passwordField = ''
        Add-Report '检测到锐捷 ePortal 门户（InterFace.do?method=login），已自动选择 eportal 模式（无需字段名/提交地址）。' 'Green'
        $modeHint = 'eportal = 锐捷 ePortal 专用：自动复现页面 doauthen 的双重编码提交（userId/password/queryString）。'
    }

    Add-Report ''
    Add-Report '--------- 建议写入 config.json 的 autoLogin 段 ---------' 'Cyan'
    Add-Report ($suggest | ConvertTo-Json -Depth 6)
    Add-Report '--------------------------------------------------------' 'Cyan'
    Add-Report '把 username / password 填上，把 enabled 改成 true，就能零点击自动登录。' 'Yellow'
    Add-Report "模式说明：$modeHint" 'Yellow'
    Add-Report ''

    if ($Write) {
        $obj = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $oldUser = ''
        $oldPass = ''
        if ($obj.autoLogin) {
            if ($obj.autoLogin.username) { $oldUser = [string]$obj.autoLogin.username }
            if ($obj.autoLogin.password) { $oldPass = [string]$obj.autoLogin.password }
            if ((-not $oldUser) -and $obj.autoLogin.form -and $snapshot.Form.UsernameField) {
                foreach ($prop in $obj.autoLogin.form.PSObject.Properties) {
                    if ($prop.Name -ieq $snapshot.Form.UsernameField) { $oldUser = [string]$prop.Value }
                }
            }
            if ((-not $oldPass) -and $obj.autoLogin.form -and $snapshot.Form.PasswordField) {
                foreach ($prop in $obj.autoLogin.form.PSObject.Properties) {
                    if ($prop.Name -ieq $snapshot.Form.PasswordField) { $oldPass = [string]$prop.Value }
                }
            }
        }
        if ($oldUser) { $suggest.username = $oldUser }
        if ($oldPass) { $suggest.password = $oldPass }
        $suggest.enabled = [bool]($oldUser -and $oldPass)

        $obj.autoLogin = ($suggest | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        [IO.File]::WriteAllText($ConfigPath, ($obj | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
        Add-Report ('已写入 {0}' -f $ConfigPath) 'Green'
        if (-not ($oldUser -and $oldPass)) {
            Add-Report '注意：账号或密码仍是空的，autoLogin.enabled 保持 false；填好后请手动改成 true。' 'Yellow'
        }
    }
}

# 无论成功失败都留档，方便事后排查或直接交给 AI 读
try {
    [IO.File]::WriteAllLines($reportPath, $report, (New-Object Text.UTF8Encoding $false))
    Write-Host ''
    Write-Host ('报告已保存：{0}' -f $reportPath) -ForegroundColor Green
} catch { }
exit $exitCode
