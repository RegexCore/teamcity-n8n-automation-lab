param(
    [string]$BaseUrl = "",
    [string]$Token = $env:TEAMCITY_TOKEN
)

$ErrorActionPreference = "Stop"

function Get-EnvValueFromDotEnv {
    param(
        [string]$EnvFilePath,
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $EnvFilePath)) {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $EnvFilePath -ErrorAction Stop)) {
        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match "^\s*$Key\s*=\s*(.*)\s*$") {
            $value = $Matches[1].Trim().Trim('"').Trim("'")
            if ([string]::IsNullOrWhiteSpace($value)) {
                return $null
            }
            return $value
        }
    }

    return $null
}

function New-RpcPayload {
    param(
        [object]$Id,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $payload = [ordered]@{
        jsonrpc = "2.0"
        method = $Method
        params = $Params
    }

    if ($null -ne $Id -and -not [string]::IsNullOrWhiteSpace([string]$Id)) {
        $payload.id = [string]$Id
    }

    return ($payload | ConvertTo-Json -Depth 10)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$envFilePath = Join-Path $repoRoot ".env"

if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_TOKEN"
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_BASE_URL"
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = "http://localhost:8111"
}

$base = $BaseUrl.TrimEnd('/')
$url = "$base/app/mcp"

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "TEAMCITY_TOKEN fehlt. Trage ihn in .env ein oder setze: `$env:TEAMCITY_TOKEN = '<token>'"
}

$headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
    "Content-Type" = "application/json"
}

function Invoke-Mcp {
    param(
        [string]$Label,
        [string]$Body
    )

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $url -Headers $headers -Body $Body -TimeoutSec 25
        Write-Host "POST $url ($Label) -> $([int]$response.StatusCode)"
        return [pscustomobject]@{
            ok = $true
            status = [int]$response.StatusCode
            body = [string]$response.Content
            sessionId = [string]$response.Headers['Mcp-Session-Id']
            error = ""
        }
    }
    catch {
        $status = $null
        $responseBody = ""
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $responseBody = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                }
            }
            catch {
            }
        }

        Write-Host "POST $url ($Label) -> $status ERR: $($_.Exception.Message)"
        return [pscustomobject]@{
            ok = $false
            status = $status
            body = $responseBody
            sessionId = ""
            error = [string]$_.Exception.Message
        }
    }
}

Write-Host "== MCP JSON-RPC Probe (pure MCP) =="

$initRes = Invoke-Mcp -Label "initialize" -Body (New-RpcPayload -Id "1" -Method "initialize" -Params @{
    protocolVersion = "2024-11-05"
    capabilities = @{}
    clientInfo = @{ name = "teamcity-mcp-direct-test"; version = "1.0" }
})

if (-not $initRes.ok) {
    Write-Host "MCP Probe fehlgeschlagen: initialize nicht erfolgreich."
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($initRes.sessionId)) {
    $headers['Mcp-Session-Id'] = $initRes.sessionId
    Write-Host "MCP Session: $($initRes.sessionId)"
}
else {
    Write-Host "MCP Probe fehlgeschlagen: kein Mcp-Session-Id Header in initialize Antwort."
    exit 1
}

$initializedRes = Invoke-Mcp -Label "notifications/initialized" -Body (New-RpcPayload -Id $null -Method "notifications/initialized" -Params @{})
if (-not $initializedRes.ok) {
    Write-Host "MCP Probe fehlgeschlagen: notifications/initialized nicht erfolgreich."
    exit 1
}

$toolsRes = Invoke-Mcp -Label "tools/list" -Body (New-RpcPayload -Id "2" -Method "tools/list" -Params @{})
if (-not $toolsRes.ok) {
    Write-Host "MCP Probe fehlgeschlagen: tools/list nicht erfolgreich."
    exit 1
}

Write-Host "MCP Probe erfolgreich: reine MCP-Kommunikation ueber /app/mcp bestaetigt."
exit 0
