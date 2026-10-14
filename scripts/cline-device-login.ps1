<#
.SYNOPSIS
    Cline 设备码登录 —— 通过 WorkOS Device Authorization 获取 Cline API 令牌。

.DESCRIPTION
    流程：
      1) 向 WorkOS 申请设备码 (device_code / user_code)
      2) 浏览器打开验证页并输入 user_code 完成授权
      3) 轮询 WorkOS 换取 WorkOS 令牌 (access_token / refresh_token)
      4) 用 WorkOS 令牌到 Cline 兑换真正的 API 令牌

    最终输出的 accessToken 即为请求 https://api.cline.bot/api/v1/* 时
    `Authorization: Bearer <accessToken>` 所用的凭证。

    ⚠️ accessToken / refreshToken 等同密码，请勿提交到仓库或粘贴到聊天工具。
    ⚠️ 本脚本为本地静态分析 + 实测端点契约所得，非官方工具。

.PARAMETER OutFile
    可选。将结果以 JSON 写入该路径（仅在你明确需要时使用）。

.PARAMETER TimeoutSeconds
    设备码授权轮询总超时，默认 300 秒（与 WorkOS expires_in 一致）。

.PARAMETER NoBrowser
    不自动打开浏览器（适合远程/无桌面环境）。

.PARAMETER ShowWorkOsToken
    同时打印 WorkOS 原始令牌（一般不需要）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\cline-device-login.ps1

.EXAMPLE
    .\cline-device-login.ps1 -OutFile "$env:USERPROFILE\.cline-token.json" -NoBrowser
#>
[CmdletBinding()]
param(
    [string] $ApiBaseUrl,
    [string] $WorkOsBaseUrl = 'https://api.workos.com',
    [string] $ClientId      = 'client_01K3A541FN8TA3EPPHTD2325AR',
    [int]    $TimeoutSeconds = 300,
    [string] $OutFile,
    [switch] $NoBrowser,
    [switch] $ShowWorkOsToken
)

$ErrorActionPreference = 'Stop'

# ---- 解析 API base url（环境变量优先，与 SDK 行为一致）--------------------
if (-not $ApiBaseUrl) {
    if ($env:CLINE_API_BASE_URL) { $ApiBaseUrl = $env:CLINE_API_BASE_URL }
    else { $ApiBaseUrl = 'https://api.cline.bot' }
}
$ApiBaseUrl   = $ApiBaseUrl.TrimEnd('/')
$WorkOsBaseUrl = $WorkOsBaseUrl.TrimEnd('/')

# ---- Windows PowerShell 5.1 默认不启用 TLS 1.2，这里强制开启 ----------------
try {
    $cur = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = $cur -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$UserAgent = 'ClineDeviceLogin/1.0'

# ---- 安全取属性：对象可能没有该字段，避免属性访问异常 ----------------------
function Get-Prop {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}


# ---- 原始 POST：无论 HTTP 状态码如何都返回 {StatusCode, Body} --------------
# 关键点：WorkOS 在「尚未授权」时返回 400 + {"error":"authorization_pending"}，
#         所以必须能读到非 2xx 的响应体，不能直接让异常冒泡。
function Invoke-RawPost {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Body,
        [Parameter(Mandatory)][string] $ContentType,
        [hashtable] $Headers
    )

    $invokeParams = @{
        Uri             = $Uri
        Method          = 'POST'
        ContentType     = $ContentType
        Body            = [System.Text.Encoding]::UTF8.GetBytes($Body)
        UseBasicParsing = $true
        TimeoutSec      = 30
        UserAgent       = $UserAgent
    }
    if ($Headers -and $Headers.Count -gt 0) { $invokeParams.Headers = $Headers }

    try {
        $resp = Invoke-WebRequest @invokeParams
        return [pscustomobject]@{
            StatusCode = [int] $resp.StatusCode
            Body       = [string] $resp.Content
        }
    }
    catch {
        $ex       = $_.Exception
        $response = $null
        if ($ex.PSObject.Properties['Response']) { $response = $ex.Response }

        # PowerShell 7 把错误正文放在 ErrorDetails
        $bodyText = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $bodyText = [string] $_.ErrorDetails.Message
        }

        # PowerShell 5.1 需要手动读响应流
        if (-not $bodyText -and $response) {
            try {
                $stream = $response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $bodyText = $reader.ReadToEnd()
                $reader.Dispose()
                $stream.Dispose()
            } catch { }
        }

        $status = 0
        if ($response) {
            $sc = $response.StatusCode
            if ($sc) {
                try { $status = [int] $sc } catch { $status = 0 }
            }
        }

        return [pscustomobject]@{
            StatusCode = $status
            Body       = [string] $bodyText
        }
    }
}

# ---- application/x-www-form-urlencoded -------------------------------------
function Invoke-FormPost {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Fields
    )

    $pairs = foreach ($key in $Fields.Keys) {
        '{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString([string] $Fields[$key])
    }
    Invoke-RawPost -Uri $Uri -Body ($pairs -join '&') -ContentType 'application/x-www-form-urlencoded'
}

# ---- application/json ------------------------------------------------------
function Invoke-JsonPost {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)] $Payload,
        [hashtable] $Headers
    )

    $json = $Payload | ConvertTo-Json -Depth 8 -Compress
    Invoke-RawPost -Uri $Uri -Body $json -ContentType 'application/json' -Headers $Headers
}

function ConvertFrom-JsonSafe {
    param([string] $Text)
    if (-not $Text) { return $null }
    try { return $Text | ConvertFrom-Json } catch { return $null }
}

# ============================ 主流程 ========================================
Write-Host ''
Write-Host '=== Cline 设备码登录 ===' -ForegroundColor Cyan
Write-Host ('API base : {0}' -f $ApiBaseUrl)
Write-Host ('WorkOS   : {0}' -f $WorkOsBaseUrl)
Write-Host ''

# ---- 1/4 申请设备码 -------------------------------------------------------
Write-Host '[1/4] 申请设备码 ...' -ForegroundColor Yellow
$resp = Invoke-FormPost -Uri "$WorkOsBaseUrl/user_management/authorize/device" -Fields @{ client_id = $ClientId }
if ($resp.StatusCode -ne 200) {
    throw ('设备码申请失败：HTTP {0} - {1}' -f $resp.StatusCode, $resp.Body)
}

$device       = ConvertFrom-JsonSafe $resp.Body
$deviceCode   = Get-Prop $device 'device_code'
$userCode     = Get-Prop $device 'user_code'
$verifyUri    = Get-Prop $device 'verification_uri'
$verifyUriCpl = Get-Prop $device 'verification_uri_complete'
$interval     = Get-Prop $device 'interval'

if (-not $deviceCode -or -not $userCode) {
    throw ('设备码响应异常：{0}' -f $resp.Body)
}
if (-not $interval -or [int] $interval -le 0) { $interval = 5 }

# ---- 2/4 提示用户授权 -----------------------------------------------------
Write-Host '[2/4] 请在浏览器中完成授权' -ForegroundColor Yellow
Write-Host ''
Write-Host ('    验证码 (user code) : {0}' -f $userCode) -ForegroundColor Green
Write-Host ('    验证地址           : {0}' -f $verifyUri)
if ($verifyUriCpl) { Write-Host ('    直达链接           : {0}' -f $verifyUriCpl) }
Write-Host ''

if (-not $NoBrowser) {
    $openUri = if ($verifyUriCpl) { $verifyUriCpl } else { $verifyUri }
    try {
        Start-Process $openUri | Out-Null
        Write-Host '    已尝试自动打开浏览器。' -ForegroundColor DarkGray
    } catch {
        Write-Host '    自动打开浏览器失败，请手动复制上面的链接。' -ForegroundColor DarkYellow
    }
} else {
    Write-Host '    (-NoBrowser) 请手动复制上面的链接到浏览器打开。' -ForegroundColor DarkGray
}

# ---- 3/4 轮询授权结果 -----------------------------------------------------
Write-Host ''
Write-Host '[3/4] 等待授权确认 ...' -ForegroundColor Yellow
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$poll     = [int] $interval
$workos   = $null

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $poll

    $r = Invoke-FormPost -Uri "$WorkOsBaseUrl/user_management/authenticate" -Fields @{
        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
        device_code = $deviceCode
        client_id   = $ClientId
    }

    $obj  = ConvertFrom-JsonSafe $r.Body
    $err  = Get-Prop $obj 'error'
    $desc = Get-Prop $obj 'error_description'

    if ($r.StatusCode -eq 200 -and (Get-Prop $obj 'access_token')) {
        $workos = $obj
        break
    }

    if ($err -eq 'authorization_pending') {
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        continue
    }
    if ($err -eq 'slow_down') {
        $poll = $poll + 1
        Write-Host '>' -NoNewline -ForegroundColor DarkGray
        continue
    }
    if ($err -eq 'access_denied' -or $err -eq 'expired_token' -or $err -eq 'invalid_grant') {
        Write-Host ''
        throw ('授权失败：{0} - {1}' -f $err, $desc)
    }

    Write-Host ''
    throw ('WorkOS 轮询异常：HTTP {0} - {1}' -f $r.StatusCode, $r.Body)
}

Write-Host ''
if (-not $workos) {
    throw ('授权超时（{0} 秒）。请重新运行脚本。' -f $TimeoutSeconds)
}

$wosAccess  = Get-Prop $workos 'access_token'
$wosRefresh = Get-Prop $workos 'refresh_token'
Write-Host '    授权成功。' -ForegroundColor Green


# ---- 4/4 用 WorkOS 令牌兑换 Cline API 令牌 -------------------------------
Write-Host '[4/4] 向 Cline 兑换 API 令牌 ...' -ForegroundColor Yellow

$headers = @{
    'Accept'         = 'application/json'
    'HTTP-Referer'   = 'https://cline.bot'
    'X-Title'        = 'Cline'
    'X-IS-MULTIROOT' = 'false'
    'X-CLIENT-TYPE'  = 'cline-sdk'
}

$exchange = Invoke-JsonPost -Uri "$ApiBaseUrl/api/v1/auth/register" `
    -Payload @{ accessToken = $wosAccess; refreshToken = $wosRefresh } `
    -Headers $headers

$exObj = ConvertFrom-JsonSafe $exchange.Body

if ($exchange.StatusCode -ne 200) {
    Write-Host ''
    Write-Host '兑换失败。原始响应：' -ForegroundColor Red
    Write-Host $exchange.Body
    throw ('令牌兑换失败：HTTP {0}' -f $exchange.StatusCode)
}

$data         = Get-Prop $exObj 'data'
$clineAccess  = Get-Prop $data 'accessToken'
$clineRefresh = Get-Prop $data 'refreshToken'
$expiresAt    = Get-Prop $data 'expiresAt'
$userInfo     = Get-Prop $data 'userInfo'

if (-not $clineAccess) {
    Write-Host ''
    Write-Host '未在响应中找到 data.accessToken。原始响应：' -ForegroundColor Red
    Write-Host $exchange.Body
    throw '令牌兑换响应结构不符预期（见上）。'
}

# ---- 输出结果 -------------------------------------------------------------
Write-Host ''
Write-Host '========== 登录成功 ==========' -ForegroundColor Green
Write-Host ''

if ($userInfo) {
    $email = Get-Prop $userInfo 'email'
    $name  = Get-Prop $userInfo 'name'
    $uid   = Get-Prop $userInfo 'clineUserId'
    if ($email) { Write-Host ('账号   : {0}' -f $email) }
    if ($name)  { Write-Host ('名称   : {0}' -f $name) }
    if ($uid)   { Write-Host ('用户ID : {0}' -f $uid) }
}
if ($expiresAt) {
    try {
        $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([long] $expiresAt).ToLocalTime()
        Write-Host ('到期   : {0}' -f $exp.ToString('yyyy-MM-dd HH:mm:ss'))
    } catch { }
}

Write-Host ''
Write-Host 'accessToken:' -ForegroundColor Cyan
Write-Host $clineAccess -ForegroundColor White
Write-Host ''
Write-Host 'refreshToken:' -ForegroundColor Cyan
Write-Host $clineRefresh
Write-Host ''

if ($ShowWorkOsToken) {
    Write-Host 'WorkOS access_token:' -ForegroundColor Cyan
    Write-Host $wosAccess
    Write-Host ''
}

# ---- 用法提示 -------------------------------------------------------------
Write-Host '----------------------------------------'
Write-Host '接下来怎么用：' -ForegroundColor Yellow
Write-Host '  1) 设为环境变量（当前会话）：'
Write-Host ('     $env:CLINE_API_KEY = "{0}..."' -f $clineAccess.Substring(0, [Math]::Min(12, $clineAccess.Length)))
Write-Host '  2) 只读冒烟测试（不消耗推理额度）：'
Write-Host '     Invoke-RestMethod "https://api.cline.bot/api/v1/ai/cline/models" -Headers @{ Authorization = "Bearer $env:CLINE_API_KEY" }'
Write-Host '  3) 永久写入用户环境变量：'
Write-Host ('     [Environment]::SetEnvironmentVariable("CLINE_API_KEY", "<token>", "User")')
Write-Host ''

if ($OutFile) {
    $payload = [ordered]@{
        accessToken  = $clineAccess
        refreshToken = $clineRefresh
        expiresAt    = $expiresAt
        apiBaseUrl   = $ApiBaseUrl
        savedAt      = (Get-Date).ToString('o')
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host ('已写入：{0}' -f $OutFile) -ForegroundColor Green
    Write-Host '注意：该文件等同密码，请勿提交到仓库。' -ForegroundColor Red
    Write-Host ''
}

Write-Host '[!] accessToken / refreshToken 等同密码，请勿外泄或提交到仓库。' -ForegroundColor Red

