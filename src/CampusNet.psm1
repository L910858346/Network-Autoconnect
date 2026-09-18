#Requires -Version 5.1
<#
    CampusNet.psm1
    中国联通校园网（ChinaUnicom）自动连接核心模块。
    职责：配置加载 / 日志 / 无线状态与连接 / 联网与强制门户探测 /
          默认浏览器打开门户 / 门户表单自动登录 / 运行状态记录。
#>

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Get-CampusProjectRoot {
    if ($PSScriptRoot) { return (Split-Path -Parent $PSScriptRoot) }
    return (Get-Location).Path
}

# ---------------------------------------------------------------- 配置

function ConvertTo-CampusHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($InputObject.Keys)) { $h[$k] = ConvertTo-CampusHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-CampusHashtable $p.Value }
        return $h
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) { $list += , (ConvertTo-CampusHashtable $item) }
        return , $list
    }
    return $InputObject
}

function Merge-CampusConfig {
    param($Defaults, $Override)
    $result = @{}
    foreach ($k in @($Defaults.Keys)) { $result[$k] = $Defaults[$k] }
    if ($Override) {
        foreach ($k in @($Override.Keys)) {
            if ($result.ContainsKey($k) -and ($result[$k] -is [hashtable]) -and ($Override[$k] -is [hashtable])) {
                $result[$k] = Merge-CampusConfig -Defaults $result[$k] -Override $Override[$k]
            } else {
                $result[$k] = $Override[$k]
            }
        }
    }
    return $result
}

function Get-CampusDefaultConfig {
    return @{
        ssid                  = @('ChinaUnicom-5G', 'ChinaUnicom')
        profileName           = ''
        interfaceName         = ''
        connectTimeoutSeconds = 45
        overallTimeoutMinutes = 15
        retryIntervalSeconds  = 10
        browser               = @{
            enabled               = $true
            url                   = ''
            fallbackUrl           = 'http://www.msftconnecttest.com/connecttest.txt'
            reopenCooldownMinutes = 10
            openDelaySeconds      = 2
            waitAfterOpenSeconds  = 40
        }
        probes                = @(
            @{ url = 'http://www.msftconnecttest.com/connecttest.txt'; expect = 'Microsoft Connect Test'; expectStatus = 0 },
            @{ url = 'http://connectivitycheck.gstatic.com/generate_204'; expect = ''; expectStatus = 204 }
        )
        autoLogin             = @{
            enabled        = $false
            mode           = 'static'
            portalUrl      = ''
            submitUrl      = ''
            username       = ''
            password       = ''
            usernameField  = ''
            passwordField  = ''
            extraFields    = @{}
            useReferer     = $true
            loginUrl       = ''
            maxAttempts    = 3
            method         = 'POST'
            contentType    = 'application/x-www-form-urlencoded'
            preRequestUrl  = ''
            form           = @{}
            extraHeaders   = @{}
            timeoutSeconds = 20
        }
        logging               = @{
            directory = ''
            keepDays  = 14
        }
    }
}

function Get-CampusConfig {
    param([string]$Path = '')

    $config = Get-CampusDefaultConfig
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $override = ConvertTo-CampusHashtable ($raw | ConvertFrom-Json)
                $config = Merge-CampusConfig -Defaults $config -Override $override
            }
        } catch {
            Write-Warning "配置文件解析失败（$Path）：$($_.Exception.Message)，改用默认配置。"
        }
    }

    if ($config.ssid -is [string]) { $config.ssid = @($config.ssid) }
    $config.ssid = @($config.ssid | Where-Object { $_ -and ([string]$_).Trim() })
    if (-not $config.ssid -or $config.ssid.Count -eq 0) { $config.ssid = @('ChinaUnicom-5G') }
    if (-not $config.profileName) { $config.profileName = [string]$config.ssid[0] }
    if (-not $config.logging.directory) { $config.logging.directory = Join-Path (Get-CampusProjectRoot) 'logs' }
    return $config
}

# ---------------------------------------------------------------- 日志 / 状态

function Write-CampusLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [string]$LogFile = ''
    )
    $line = "[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    try { Write-Host $line -ForegroundColor $color } catch { }
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

function Get-CampusLogFile {
    param([Parameter(Mandatory = $true)]$Config)
    $dir = [string]$Config.logging.directory
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $keep = 0
    try { $keep = [int]$Config.logging.keepDays } catch { $keep = 0 }
    if ($keep -gt 0) {
        Get-ChildItem -LiteralPath $dir -Filter 'connect-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$keep) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return (Join-Path $dir ('connect-{0}.log' -f (Get-Date -Format 'yyyyMMdd')))
}

function Get-CampusStateFile {
    $dir = Join-Path (Get-CampusProjectRoot) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'state.json')
}

function Get-CampusState {
    $file = Get-CampusStateFile
    if (-not (Test-Path -LiteralPath $file)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return @{} }
        return (ConvertTo-CampusHashtable ($raw | ConvertFrom-Json))
    } catch { return @{} }
}

function Save-CampusState {
    param([Parameter(Mandatory = $true)]$State)
    try {
        ($State | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Get-CampusStateFile) -Encoding UTF8
    } catch { }
}

function Get-CampusBootId {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return ([datetime]$os.LastBootUpTime).ToString('o')
    } catch { return '' }
}

# ---------------------------------------------------------------- 无线

function Test-CampusWlanAvailable {
    $raw = ''
    try { $raw = (& netsh wlan show interfaces 2>$null | Out-String) } catch { return $false }
    if (-not $raw -or -not $raw.Trim()) { return $false }
    if ($raw -match '没有无线接口' -or $raw -match 'There is no wireless interface') { return $false }
    return $true
}

function Wait-CampusWlanReady {
    param([int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds([math]::Max(5, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (Test-CampusWlanAvailable) { return $true }
        Start-Sleep -Seconds 3
    }
    return (Test-CampusWlanAvailable)
}

function Get-WlanStatus {
    $result = [ordered]@{
        Available = $false
        Ssid      = ''
        Connected = $false
        Raw       = ''
    }
    $raw = ''
    try { $raw = (& netsh wlan show interfaces 2>$null | Out-String) } catch { return [pscustomobject]$result }
    if (-not $raw) { return [pscustomobject]$result }
    $result.Raw = $raw
    $result.Available = -not ($raw -match '没有无线接口' -or $raw -match 'There is no wireless interface')
    foreach ($line in ($raw -split "\r?\n")) {
        if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') {
            $ssid = $Matches[1].Trim()
            if ($ssid) { $result.Ssid = $ssid }
        }
    }
    $result.Connected = [bool]$result.Ssid
    return [pscustomobject]$result
}

function Get-CampusWlanProfiles {
    $names = @()
    try {
        $raw = (& netsh wlan show profiles 2>$null | Out-String)
        foreach ($line in ($raw -split "\r?\n")) {
            if ($line -match ':\s*(.+?)\s*$') {
                $name = $Matches[1].Trim()
                if ($name -and $name -ne '<无>') { $names += $name }
            }
        }
    } catch { }
    return $names
}

function Connect-CampusWifi {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$LogFile = ''
    )

    $targets = @($Config.ssid)
    $current = Get-WlanStatus
    foreach ($t in $targets) {
        if ($current.Connected -and ($current.Ssid -ieq $t)) {
            Write-CampusLog -Message "无线已连接目标网络 $($current.Ssid)" -Level OK -LogFile $LogFile
            return $true
        }
    }

    $profiles = @(Get-CampusWlanProfiles)
    foreach ($ssid in $targets) {
        $profile = [string]$Config.profileName
        if (-not $profile) { $profile = [string]$ssid }
        if ($targets.Count -gt 1) { $profile = [string]$ssid }

        if (-not ($profiles -contains $profile) -and -not ($profiles -contains $ssid)) {
            Write-CampusLog -Message "未找到无线配置文件 [$profile]，跳过该网络（可用 scripts\prepare-wifi.ps1 导入）" -Level WARN -LogFile $LogFile
            continue
        }

        $netshArgs = @('wlan', 'connect', "name=$profile", "ssid=$ssid")
        if ($Config.interfaceName) { $netshArgs += "interface=$($Config.interfaceName)" }

        Write-CampusLog -Message "正在连接无线网络 $ssid ..." -LogFile $LogFile
        try { & netsh @netshArgs 2>&1 | Out-Null } catch { }

        $deadline = (Get-Date).AddSeconds([math]::Max(10, [int]$Config.connectTimeoutSeconds))
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $st = Get-WlanStatus
            if ($st.Connected -and (($st.Ssid -ieq $ssid) -or ($st.Ssid -ieq $profile))) {
                Write-CampusLog -Message "已连接到 $($st.Ssid)" -Level OK -LogFile $LogFile
                return $true
            }
        }
        Write-CampusLog -Message "连接 $ssid 超时（可能不在信号范围内）" -Level WARN -LogFile $LogFile
    }
    return $false
}

# ---------------------------------------------------------------- HTTP 探测

function Resolve-CampusUrl {
    param([string]$Base, [string]$Relative)
    if (-not $Relative) { return $Base }
    $r = $Relative.Trim()
    if ($r -match '^(?i)https?://') { return $r }
    try { return ([System.Uri]::new([System.Uri]$Base, $r)).AbsoluteUri } catch { return $r }
}

function Invoke-CampusHttp {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 8000,
        [switch]$AllowRedirect,
        $WebSession = $null
    )
    $out = [ordered]@{
        Url = $Url; Status = 0; Location = ''; Body = ''; FinalUrl = $Url; Error = ''
    }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = [bool]$AllowRedirect
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Unicom-AutoConnect/1.0'
        $req.Method = 'GET'
        if ($WebSession -and $WebSession.Cookies) { $req.CookieContainer = $WebSession.Cookies }
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
        $out.Status = [int]$resp.StatusCode
        try { $out.FinalUrl = $resp.ResponseUri.AbsoluteUri } catch { }
        try { $out.Location = [string]$resp.Headers['Location'] } catch { }
        if ($out.Status -eq 200) {
            $enc = $null
            try { if ($resp.CharacterSet) { $enc = [System.Text.Encoding]::GetEncoding($resp.CharacterSet) } } catch { }
            if (-not $enc) { $enc = [System.Text.Encoding]::Default }
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), $enc)
            $out.Body = $sr.ReadToEnd()
            $sr.Dispose()
        }
    } catch [System.Net.WebException] {
        $out.Error = $_.Exception.Message
    } catch {
        $out.Error = $_.Exception.Message
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }
    return [pscustomobject]$out
}

function Find-CampusPortalUrl {
    param([string]$Html, [string]$Base)
    if (-not $Html) { return '' }
    $patterns = @(
        '(?is)<meta[^>]+http-equiv\s*=\s*["'']?refresh["'']?[^>]*content\s*=\s*["''][^"'']*url\s*=\s*([^"'';\s>]+)',
        '(?is)<form[^>]+action\s*=\s*["'']([^"'']+)["'']',
        '(?is)location\.(?:href|replace)\s*[=(]\s*["'']([^"'']+)["'']'
    )
    foreach ($p in $patterns) {
        $m = [regex]::Match($Html, $p)
        if ($m.Success) {
            $candidate = $m.Groups[1].Value.Trim()
            if ($candidate -and $candidate -notmatch '^(?i)(javascript|about|#)') {
                return (Resolve-CampusUrl -Base $Base -Relative $candidate)
            }
        }
    }
    return ''
}

function Invoke-CampusConnectivityCheck {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$LogFile = ''
    )
    $result = [ordered]@{
        Online     = $false
        PortalUrl  = ''
        Detail     = ''
        CheckedUrl = ''
    }

    foreach ($p in @($Config.probes)) {
        $url = [string]$p.url
        if (-not $url) { continue }
        $resp = Invoke-CampusHttp -Url $url -TimeoutMs 8000
        $result.CheckedUrl = $url

        $expectStatus = 0
        try { $expectStatus = [int]$p.expectStatus } catch { $expectStatus = 0 }
        $expect = [string]$p.expect

        if (($resp.Status -ge 300) -and ($resp.Status -lt 400) -and $resp.Location) {
            $result.PortalUrl = Resolve-CampusUrl -Base $url -Relative $resp.Location
            $result.Detail = "HTTP $($resp.Status) 重定向 -> $($result.PortalUrl)"
            return [pscustomobject]$result
        }

        if ($resp.Status -eq 200) {
            if ($expect -and $resp.Body -and $resp.Body.Contains($expect)) {
                $result.Online = $true
                $result.Detail = "$url 返回预期内容 ($expect)"
                return [pscustomobject]$result
            }
            if ((-not $expect) -and ($expectStatus -eq 200 -or $expectStatus -eq 0)) {
                $result.Online = $true
                $result.Detail = "$url 返回 HTTP 200"
                return [pscustomobject]$result
            }
            $portal = Find-CampusPortalUrl -Html $resp.Body -Base $resp.FinalUrl
            if (-not $portal) { $portal = $resp.FinalUrl }
            $result.PortalUrl = $portal
            $result.Detail = "$url 返回非预期内容（疑似门户劫持）"
            return [pscustomobject]$result
        }

        if ($expectStatus -gt 0 -and $resp.Status -eq $expectStatus) {
            $result.Online = $true
            $result.Detail = "$url 返回 HTTP $($resp.Status)（预期值）"
            return [pscustomobject]$result
        }

        if ($resp.Status -eq 0) {
            if ($resp.Error) { $result.Detail = "$url 请求失败：$($resp.Error)" }
        } else {
            $result.Detail = "$url 返回 HTTP $($resp.Status)"
        }
    }

    if (-not $result.Detail) { $result.Detail = '所有探测地址均不可达（可能尚未连上无线）' }
    return [pscustomobject]$result
}

# ---------------------------------------------------------------- 默认浏览器

function Open-CampusPortal {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$Config,
        [switch]$Force,
        [string]$LogFile = ''
    )
    if (-not $Url) { return $false }

    $state = Get-CampusState
    $bootId = Get-CampusBootId
    $now = Get-Date

    if (-not $Force) {
        $lastTime = $null
        if ($state.lastPortalOpenTime) {
            try { $lastTime = [datetime]::Parse([string]$state.lastPortalOpenTime) } catch { $lastTime = $null }
        }
        $cooldown = [int]$Config.browser.reopenCooldownMinutes
        if ($lastTime -and ([string]$state.lastPortalOpenUrl -eq $Url) -and ([string]$state.lastPortalOpenBoot -eq $bootId)) {
            $elapsed = ($now - $lastTime).TotalMinutes
            if ($elapsed -lt $cooldown) {
                Write-CampusLog -Message ("同一门户 {0:N1} 分钟前已打开过，冷却 {1} 分钟内不重复打开" -f $elapsed, $cooldown) -LogFile $LogFile
                return $false
            }
        }
    }

    $delay = 0
    try { $delay = [int]$Config.browser.openDelaySeconds } catch { $delay = 0 }
    if ($delay -gt 0) { Start-Sleep -Seconds $delay }

    $opened = $false
    try {
        Start-Process -FilePath $Url -ErrorAction Stop
        $opened = $true
    } catch {
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList $Url -ErrorAction Stop
            $opened = $true
        } catch {
            Write-CampusLog -Message "打开默认浏览器失败：$($_.Exception.Message)" -Level ERROR -LogFile $LogFile
        }
    }

    if ($opened) {
        Write-CampusLog -Message "已用系统默认浏览器打开门户页面：$Url" -Level OK -LogFile $LogFile
        $state.lastPortalOpenTime = $now.ToString('o')
        $state.lastPortalOpenUrl = $Url
        $state.lastPortalOpenBoot = $bootId
        Save-CampusState -State $state
    }
    return $opened
}

# ---------------------------------------------------------------- 门户自动登录


# ---------------------------------------------------------------- 门户表单自动登录（每次现抓现填）

function Invoke-CampusPortalFormLogin {
    <#
        适用：门户登录表单带一次性令牌（例如联通校园网门户常见的 paramStr）。
        流程：GET 门户页（跟随 frameset）-> 解析出全部字段和提交地址
              -> 隐藏字段原样带回、账号密码填进去 -> POST -> 由调用方复检是否真的联网。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$LogFile = ''
    )

    $al = $Config.autoLogin
    $timeout = 20
    try { $timeout = [int]$al.timeoutSeconds } catch { $timeout = 20 }

    $username = [string]$al.username
    $password = [string]$al.password
    if (-not $username -or -not $password) {
        Write-CampusLog -Message 'autoLogin.mode=portal-form，但 username / password 是空的，跳过自动登录' -Level WARN -LogFile $LogFile
        return $false
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $snap = Get-CampusPortalSnapshot -Config $Config -Url ([string]$al.portalUrl) -LogFile $LogFile -WebSession $session

    $userField = [string]$al.usernameField
    if (-not $userField) { $userField = [string]$snap.Form.UsernameField }
    $passField = [string]$al.passwordField
    if (-not $passField) { $passField = [string]$snap.Form.PasswordField }

    if (-not $passField -or -not $userField) {
        Write-CampusLog -Message '没能从门户页解析出账号/密码字段，放弃自动登录（可手工在配置里指定 usernameField / passwordField）' -Level WARN -LogFile $LogFile
        return $false
    }

    # 隐藏字段（含一次性令牌）原样带回，顺序不影响服务端解析
    $fields = [ordered]@{}
    foreach ($f in $snap.Form.Fields) {
        if ($f.name -ieq $userField -or $f.name -ieq $passField) { continue }
        $fields[[string]$f.name] = [string]$f.value
    }
    if ($al.extraFields) { foreach ($k in @($al.extraFields.Keys)) { $fields[[string]$k] = [string]$al.extraFields[$k] } }
    $fields[$userField] = $username
    $fields[$passField] = $password

    # submitUrl 允许写相对路径（例如 /authServlet），会按门户地址补全，
    # 这样门户域名变了也不用改配置；留空则用表单自己的 action。
    $submitUrl = [string]$al.submitUrl
    if ($submitUrl) {
        $submitUrl = Resolve-CampusUrl -Base $snap.FinalUrl -Relative $submitUrl
    } else {
        $submitUrl = [string]$snap.Form.Action
    }
    if (-not $submitUrl) { $submitUrl = [string]$snap.FinalUrl }

    $pairs = @()
    foreach ($k in @($fields.Keys)) {
        $pairs += ('{0}={1}' -f [System.Uri]::EscapeDataString([string]$k), [System.Uri]::EscapeDataString([string]$fields[$k]))
    }
    $body = $pairs -join '&'

    $headers = @{}
    if ($al.useReferer -and $snap.FinalUrl) { $headers['Referer'] = [string]$snap.FinalUrl }
    if ($al.extraHeaders) { foreach ($k in @($al.extraHeaders.Keys)) { $headers[[string]$k] = [string]$al.extraHeaders[$k] } }

    $postParams = @{
        Uri             = $submitUrl
        Method          = [string]$al.method
        Body            = $body
        ContentType     = [string]$al.contentType
        WebSession      = $session
        UseBasicParsing = $true
        TimeoutSec      = $timeout
    }
    if ($headers.Count -gt 0) { $postParams['Headers'] = $headers }

    Write-CampusLog -Message ("门户表单模式：拿到 {0} 个字段（含一次性令牌），提交到 {1}" -f $fields.Count, $submitUrl) -LogFile $LogFile
    try {
        $resp = Invoke-WebRequest @postParams
        Write-CampusLog -Message "登录请求已发送，HTTP $([int]$resp.StatusCode)，返回 $($resp.Content.Length) 字节" -LogFile $LogFile
        return $true
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match '超时|timed out|timeout') {
            # 实测：部分校园网门户（如联通认证系统）的提交接口经常收下请求却不回响应，客户端超时，
            # 但账号其实已经认证成功了。所以这里不能当失败处理，交给调用方复检联网状态。
            Write-CampusLog -Message '门户登录提交超时（门户常见：已受理但不回响应），账号可能已认证成功，改为复检联网状态判断。' -Level WARN -LogFile $LogFile
            return $true
        }
        Write-CampusLog -Message "门户登录提交失败：$errMsg" -Level WARN -LogFile $LogFile
        return $false
    }
}

function ConvertTo-CampusDoubleEncoded {
    # 锐捷 ePortal 页面 JS（doauthen）对所有参数做两次 encodeURIComponent，这里保持完全一致
    param([string]$Value)
    return [System.Uri]::EscapeDataString([System.Uri]::EscapeDataString([string]$Value))
}

function Invoke-CampusEportalLogin {
    <#
        适用：锐捷 ePortal 门户（页面形如 /eportal/index.jsp?wlanuserip=...&wlanacname=...），
              例如联通校园网 http://10.1.100.2/eportal。这类门户可见表单并不直接提交，
              登录由页面 JS（AuthInterFace.js 的 doauthen）POST 到 InterFace.do?method=login：
              userId / password / service / queryString 全部做双重 URL 编码，
              queryString 就是门户地址栏 ? 之后的整段（wlanuserip、wlanacname、mac、nasip 等）。
        流程：GET 门户页（拿会话 Cookie 与地址栏 queryString）
              -> 按页面 JS 同样方式编码并 POST InterFace.do?method=login
              -> 解析返回 JSON（result=success），最终由调用方复检是否真的联网。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$LogFile = ''
    )

    $al = $Config.autoLogin
    $timeout = 20
    try { $timeout = [int]$al.timeoutSeconds } catch { $timeout = 20 }

    $username = [string]$al.username
    $password = [string]$al.password
    if (-not $username -or -not $password) {
        Write-CampusLog -Message 'autoLogin.mode=eportal，但 username / password 是空的，跳过自动登录' -Level WARN -LogFile $LogFile
        return $false
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $snap = Get-CampusPortalSnapshot -Config $Config -Url ([string]$al.portalUrl) -LogFile $LogFile -WebSession $session

    # 对应页面 JS 的 getQueryString()：document.location.search 去掉开头的 '?'
    $query = ''
    try { $query = ([System.Uri]$snap.FinalUrl).Query.TrimStart('?') } catch { }
    if (-not $query) {
        try { $query = ([System.Uri]$snap.PortalUrl).Query.TrimStart('?') } catch { }
    }
    if (-not $query) {
        Write-CampusLog -Message '门户地址里没有 queryString（wlanuserip / wlanacname / mac 等），ePortal 登录无法提交，放弃（请确认当前处于未认证状态后重试）。' -Level WARN -LogFile $LogFile
        return $false
    }

    $serviceEnc = ''
    if ($al.eportalService) { $serviceEnc = ConvertTo-CampusDoubleEncoded ([string]$al.eportalService) }

    $body = 'userId={0}&password={1}&service={2}&queryString={3}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false' -f `
        (ConvertTo-CampusDoubleEncoded $username),
        (ConvertTo-CampusDoubleEncoded $password),
        $serviceEnc,
        (ConvertTo-CampusDoubleEncoded $query)

    # AuthInterFace.init("./") -> ./InterFace.do?method=login，相对门户页 .../eportal/index.jsp 补全
    $loginUrl = Resolve-CampusUrl -Base $snap.FinalUrl -Relative './InterFace.do?method=login'

    $headers = @{}
    if ($al.useReferer -and $snap.FinalUrl) { $headers['Referer'] = [string]$snap.FinalUrl }
    if ($al.extraHeaders) { foreach ($k in @($al.extraHeaders.Keys)) { $headers[[string]$k] = [string]$al.extraHeaders[$k] } }

    $postParams = @{
        Uri             = $loginUrl
        Method          = 'POST'
        Body            = $body
        ContentType     = 'application/x-www-form-urlencoded; charset=UTF-8'
        WebSession      = $session
        UseBasicParsing = $true
        TimeoutSec      = $timeout
    }
    if ($headers.Count -gt 0) { $postParams['Headers'] = $headers }

    Write-CampusLog -Message ("ePortal 模式：提交到 {0}（queryString 共 {1} 字符）" -f $loginUrl, $query.Length) -LogFile $LogFile
    try {
        $resp = Invoke-WebRequest @postParams
        $text = [string]$resp.Content
        $preview = $text
        if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) }
        Write-CampusLog -Message "ePortal 登录接口返回：$preview" -LogFile $LogFile
        if ($text -match '"result"\s*:\s*"success"') {
            Write-CampusLog -Message 'ePortal 登录接口返回 success。' -Level OK -LogFile $LogFile
            return $true
        }
        if ($text -match '"result"\s*:\s*"wait"') {
            Write-CampusLog -Message 'ePortal 登录接口返回 wait，等待认证生效，交由联网复检判断。' -Level WARN -LogFile $LogFile
            return $true
        }
        Write-CampusLog -Message "ePortal 登录被拒：$preview" -Level WARN -LogFile $LogFile
        return $false
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match '超时|timed out|timeout') {
            # 门户设备经常收下请求却不回响应、但账号其实已认证成功，交给调用方复检联网状态
            Write-CampusLog -Message 'ePortal 登录提交超时（门户常见：已受理但不回响应），账号可能已认证成功，改为复检联网状态判断。' -Level WARN -LogFile $LogFile
            return $true
        }
        Write-CampusLog -Message "ePortal 登录请求失败：$errMsg" -Level WARN -LogFile $LogFile
        return $false
    }
}

function Invoke-CampusAutoLogin {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$LogFile = ''
    )
    $al = $Config.autoLogin
    if (-not $al.enabled) { return $false }

    # eportal：锐捷 ePortal（/eportal/index.jsp，联通校园网常见），登录走 InterFace.do?method=login
    if ([string]$al.mode -ieq 'eportal') {
        return (Invoke-CampusEportalLogin -Config $Config -LogFile $LogFile)
    }

    # portal-form：每次现抓门户页（拿新的一次性令牌）再提交，适合带 paramStr 的门户
    if ([string]$al.mode -ieq 'portal-form') {
        return (Invoke-CampusPortalFormLogin -Config $Config -LogFile $LogFile)
    }

    if (-not $al.loginUrl) {
        Write-CampusLog -Message 'autoLogin 已启用但未配置 loginUrl，跳过' -Level WARN -LogFile $LogFile
        return $false
    }

    $timeout = 20
    try { $timeout = [int]$al.timeoutSeconds } catch { $timeout = 20 }

    try {
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        if ($al.preRequestUrl) {
            Write-CampusLog -Message "预请求门户首页：$($al.preRequestUrl)" -LogFile $LogFile
            Invoke-WebRequest -Uri ([string]$al.preRequestUrl) -WebSession $session -UseBasicParsing -TimeoutSec $timeout | Out-Null
        }

        $pairs = @()
        if ($al.form) {
            foreach ($k in @($al.form.Keys)) {
                $pairs += ('{0}={1}' -f [System.Uri]::EscapeDataString([string]$k), [System.Uri]::EscapeDataString([string]$al.form[$k]))
            }
        }
        $body = $pairs -join '&'

        $headers = @{}
        foreach ($k in @($al.extraHeaders.Keys)) { $headers[[string]$k] = [string]$al.extraHeaders[$k] }

        $postParams = @{
            Uri             = [string]$al.loginUrl
            Method          = [string]$al.method
            Body            = $body
            ContentType     = [string]$al.contentType
            WebSession      = $session
            UseBasicParsing = $true
            TimeoutSec      = $timeout
        }
        if ($headers.Count -gt 0) { $postParams['Headers'] = $headers }

        Write-CampusLog -Message "正在提交门户登录表单：$($al.loginUrl)" -LogFile $LogFile
        $resp = Invoke-WebRequest @postParams
        Write-CampusLog -Message "登录请求已发送，HTTP $([int]$resp.StatusCode)，返回 $($resp.Content.Length) 字节" -LogFile $LogFile
        return $true
    } catch {
        Write-CampusLog -Message "门户登录请求失败：$($_.Exception.Message)" -Level WARN -LogFile $LogFile
        return $false
    }
}

# ---------------------------------------------------------------- 诊断输出

function Show-CampusDiagnostics {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$LogFile = ''
    )
    Write-Host ''
    Write-Host '================ 校园网状态诊断 ================' -ForegroundColor Cyan
    $wl = Get-WlanStatus
    Write-Host ("无线网卡      : {0}" -f $(if ($wl.Available) { '可用' } else { '不可用 / 未安装' }))
    Write-Host ("当前 SSID     : {0}" -f $(if ($wl.Ssid) { $wl.Ssid } else { '(未连接)' }))
    Write-Host ("目标 SSID     : {0}" -f (@($Config.ssid) -join ' , '))
    Write-Host ("目标配置文件  : {0}" -f $Config.profileName)
    $profiles = @(Get-CampusWlanProfiles)
    $hasProfile = ($profiles -contains [string]$Config.profileName)
    Write-Host ("配置文件存在  : {0}" -f $(if ($hasProfile) { '是' } else { '否（需先导入，或修改 profileName）' }))
    $check = Invoke-CampusConnectivityCheck -Config $Config -LogFile $LogFile
    Write-Host ("联网状态      : {0}" -f $(if ($check.Online) { '已联网（无需认证）' } else { '未联网（可能需要门户认证）' }))
    Write-Host ("探测详情      : {0}" -f $check.Detail)
    Write-Host ("门户地址      : {0}" -f $(if ($check.PortalUrl) { $check.PortalUrl } else { '(未探测到，可在 config.browser.url 手工指定)' }))
    $state = Get-CampusState
    if ($state.lastPortalOpenTime) {
        Write-Host ("上次打开门户  : {0}  {1}" -f $state.lastPortalOpenTime, $state.lastPortalOpenUrl)
    }
    Write-Host ("日志文件      : {0}" -f (Get-CampusLogFile -Config $Config))
    Write-Host '================================================' -ForegroundColor Cyan
    Write-Host ''
}

# ---------------------------------------------------------------- 门户表单解析（供抓包助手使用）

function Get-CampusPortalForm {
    param([string]$Html, [string]$Base)

    $fields = @()
    $action = ''
    $method = 'POST'

    if ($Html) {
        $mf = [regex]::Match($Html, '(?is)<form\b([^>]*)>')
        if ($mf.Success) {
            $attrs = $mf.Groups[1].Value
            $a = [regex]::Match($attrs, '(?i)action\s*=\s*["'']([^"'']*)["'']')
            if ($a.Success -and $a.Groups[1].Value.Trim()) {
                $action = Resolve-CampusUrl -Base $Base -Relative $a.Groups[1].Value.Trim()
            }
            # 注意：要求 method 前是空白（属性边界），避免把 action="xxx?method=manage" 查询串里的 method 误当成表单方法
            $m = [regex]::Match($attrs, '(?i)(?:^|\s)method\s*=\s*["'']?([a-zA-Z]+)')
            if ($m.Success) { $method = $m.Groups[1].Value.ToUpper() }
        }

        foreach ($i in [regex]::Matches($Html, '(?is)<input\b([^>]*)>')) {
            $attrs = $i.Groups[1].Value
            $name = [regex]::Match($attrs, '(?i)\bname\s*=\s*["'']([^"'']*)["'']')
            if (-not $name.Success -or -not $name.Groups[1].Value) { continue }
            $type = [regex]::Match($attrs, '(?i)\btype\s*=\s*["'']?([a-zA-Z]+)')
            $val = [regex]::Match($attrs, '(?i)\bvalue\s*=\s*["'']([^"'']*)["'']')
            $fields += [pscustomobject]@{
                name  = $name.Groups[1].Value
                type  = $(if ($type.Success) { $type.Groups[1].Value.ToLower() } else { 'text' })
                value = $(if ($val.Success) { $val.Groups[1].Value } else { '' })
            }
        }

        foreach ($s in [regex]::Matches($Html, '(?is)<select\b([^>]*)>(.*?)</select>')) {
            $name = [regex]::Match($s.Groups[1].Value, '(?i)\bname\s*=\s*["'']([^"'']*)["'']')
            if (-not $name.Success -or -not $name.Groups[1].Value) { continue }
            $opts = @()
            foreach ($o in [regex]::Matches($s.Groups[2].Value, '(?is)<option\b([^>]*)>')) {
                $v = [regex]::Match($o.Groups[1].Value, '(?i)\bvalue\s*=\s*["'']([^"'']*)["'']')
                if ($v.Success) { $opts += $v.Groups[1].Value }
            }
            $fields += [pscustomobject]@{
                name  = $name.Groups[1].Value
                type  = 'select'
                value = $(if ($opts.Count -gt 0) { $opts[0] } else { '' })
            }
        }
    }

    $passwordField = ''
    $usernameField = ''
    foreach ($f in $fields) {
        if ((-not $passwordField) -and $f.type -eq 'password') { $passwordField = $f.name }
    }

    # 排除门户里的“基础设施”字段（运营商门户常见 wlanuserip / nasip / wlanacname 之类，很容易把 user 抢走）
    $blockedPattern = '(?i)^(wlanuserip|wlanusermac|wlanacip|wlanacname|nasip|nasid|basip|ssid|mac|ip|ipv4|url|uri|redirect|redirecturl|ticket|token|session|sessionid|device|terminal|switch|lang|time)'
    $strongPattern = '(?i)^(username|user_name|userid|user_id|useraccount|account|accountname|acct|loginname|login_name|loginuser|studentid|stu_id|stuid|phone|mobile|mobilephone|telephone|user|name)$'
    $weakPattern = '(?i)(user|account|acct|login|uid|phone|mobile|stu|name)'

    $candidates = @()
    foreach ($f in $fields) {
        if ($f.type -ne 'text' -and $f.type -ne 'select') { continue }
        if ($passwordField -and $f.name -ieq $passwordField) { continue }
        if ($f.name -match $blockedPattern) { continue }
        $candidates += $f
    }
    foreach ($f in $candidates) {
        if ($f.name -match $strongPattern) { $usernameField = $f.name; break }
    }
    if (-not $usernameField) {
        foreach ($f in $candidates) {
            if ($f.name -match $weakPattern) { $usernameField = $f.name; break }
        }
    }
    if (-not $usernameField -and $candidates.Count -gt 0) { $usernameField = $candidates[0].name }

    return [pscustomobject]@{
        Action        = $action
        Method        = $method
        Fields        = $fields
        UsernameField = $usernameField
        PasswordField = $passwordField
    }
}

function Get-CampusFormScore {
    param($Form)
    if (-not $Form) { return 0 }
    $score = [int]$Form.Fields.Count
    if ($Form.UsernameField) { $score += 50 }
    if ($Form.PasswordField) { $score += 100 }
    return $score
}

function Get-CampusFrameUrls {
    param([string]$Html, [string]$Base)
    $urls = @()
    if (-not $Html) { return $urls }
    foreach ($m in [regex]::Matches($Html, '(?is)<(?:frame|iframe)\b([^>]*)>')) {
        $src = [regex]::Match($m.Groups[1].Value, '(?i)\bsrc\s*=\s*["'']([^"'']+)["'']')
        if (-not $src.Success) { continue }
        $raw = $src.Groups[1].Value.Trim()
        if (-not $raw) { continue }
        if ($raw -match '(?i)^(about:|javascript:|#)') { continue }
        $full = Resolve-CampusUrl -Base $Base -Relative $raw
        if ($full) { $urls += $full }
    }
    return $urls
}

function Get-CampusFormActionFromScripts {
    <#
        门户表单常常 action="" ，真实提交地址写在 JS 里，例如：
            document.forms[0].action = "/authServlet";
        本函数把登录页引用的 JS 抓下来扫一遍，找出这个地址。
    #>
    param(
        [string]$Html,
        [string]$Base,
        $WebSession = $null,
        [int]$MaxScripts = 5
    )
    if (-not $Html) { return '' }

    $srcs = @()
    foreach ($m in [regex]::Matches($Html, '(?is)<script\b([^>]*)>')) {
        $src = [regex]::Match($m.Groups[1].Value, '(?i)\bsrc\s*=\s*["'']([^"'']+)["'']')
        if ($src.Success -and $src.Groups[1].Value) {
            $srcs += (Resolve-CampusUrl -Base $Base -Relative $src.Groups[1].Value)
        }
    }

    $count = 0
    foreach ($s in $srcs) {
        if ($count -ge $MaxScripts) { break }
        $count++
        $r = Invoke-CampusHttp -Url $s -TimeoutMs 8000 -WebSession $WebSession
        if (-not $r.Body) { continue }
        foreach ($pattern in @('(?i)forms\[\d+\]\.action\s*=\s*["'']([^"'']+)["'']', '(?i)\.action\s*=\s*["''](/?[^"''\s]+)["'']')) {
            $m = [regex]::Match($r.Body, $pattern)
            if ($m.Success) {
                $candidate = $m.Groups[1].Value.Trim()
                if ($candidate) {
                    return (Resolve-CampusUrl -Base $Base -Relative $candidate)
                }
            }
        }
    }
    return ''
}

function Get-CampusPortalSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$Url = '',
        [string]$SaveHtmlDir = '',
        [string]$LogFile = '',
        [int]$Depth = 0,
        $WebSession = $null
    )

    $portalUrl = $Url
    if (-not $portalUrl) {
        $check = Invoke-CampusConnectivityCheck -Config $Config -LogFile $LogFile
        $portalUrl = [string]$check.PortalUrl
        if ($check.Online) {
            Write-CampusLog -Message '当前已经联网，运营商不会跳转到认证门户。' -Level WARN -LogFile $LogFile
        }
        if (-not $portalUrl) {
            $portalUrl = [string]$Config.browser.fallbackUrl
            Write-CampusLog -Message "未能探测到门户地址，改用兜底地址试探：$portalUrl" -Level WARN -LogFile $LogFile
        }
    }

    $resp = Invoke-CampusHttp -Url $portalUrl -TimeoutMs 15000 -AllowRedirect -WebSession $WebSession
    $htmlPath = ''
    if ($SaveHtmlDir -and $resp.Body) {
        if (-not (Test-Path -LiteralPath $SaveHtmlDir)) { New-Item -ItemType Directory -Path $SaveHtmlDir -Force | Out-Null }
        $htmlPath = Join-Path $SaveHtmlDir ('portal-{0}-d{1}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $Depth)
        try { [IO.File]::WriteAllText($htmlPath, $resp.Body, (New-Object Text.UTF8Encoding $false)) } catch { $htmlPath = '' }
    }

    $form = Get-CampusPortalForm -Html $resp.Body -Base $resp.FinalUrl
    if (-not $form.Action) { $form.Action = $resp.FinalUrl }

    $best = [pscustomobject]@{
        PortalUrl = $portalUrl
        FinalUrl  = $resp.FinalUrl
        Status    = $resp.Status
        HtmlPath  = $htmlPath
        Form      = $form
        Body      = $resp.Body
        Depth     = $Depth
    }

    # 很多运营商门户（包括部分联通校园网认证系统）首屏是 frameset，
    # 真正的账号密码表单藏在子框架里；这里跟进子框架，并挑“最像登录表单”的那个。
    if ($Depth -lt 2) {
        foreach ($frameUrl in (Get-CampusFrameUrls -Html $resp.Body -Base $resp.FinalUrl)) {
            if ($frameUrl -match '(?i)blank\.html$') { continue }
            if ($frameUrl -ieq $resp.FinalUrl) { continue }
            Write-CampusLog -Message "门户是框架页，跟进子框架：$frameUrl" -Level DEBUG -LogFile $LogFile
            $child = Get-CampusPortalSnapshot -Config $Config -Url $frameUrl -SaveHtmlDir $SaveHtmlDir -LogFile $LogFile -Depth ($Depth + 1) -WebSession $WebSession
            if ((Get-CampusFormScore -Form $child.Form) -gt (Get-CampusFormScore -Form $best.Form)) {
                $best = $child
                $best.PortalUrl = $portalUrl
            }
        }
    }

    return $best
}

Export-ModuleMember -Function *-Campus*, Get-WlanStatus, Connect-CampusWifi
