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

    $lines = Get-Content -LiteralPath $EnvFilePath -ErrorAction Stop
    foreach ($line in $lines) {
        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match "^\s*$Key\s*=\s*(.*)\s*$") {
            $value = $Matches[1].Trim()

            if ($value.StartsWith('"') -and $value.EndsWith('"')) {
                $value = $value.Trim('"')
            }

            if ($value.StartsWith("'") -and $value.EndsWith("'")) {
                $value = $value.Trim("'")
            }

            if ([string]::IsNullOrWhiteSpace($value)) {
                return $null
            }

            return $value
        }
    }

    return $null
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

$headers = @{}
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $headers.Authorization = "Bearer $Token"
}
else {
    Write-Host "Hinweis: Kein TEAMCITY_TOKEN gefunden, Test laeuft ohne Auth und kann eingeschraenkt sein."
}

function Get-StatusCode {
    param(
        [string]$Url,
        [hashtable]$RequestHeaders
    )

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Url -Headers $RequestHeaders -TimeoutSec 20
        return @([int]$response.StatusCode, $response.StatusDescription)
    }
    catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $resp = $_.Exception.Response
            return @([int]$resp.StatusCode, $resp.StatusDescription)
        }

        throw
    }
}

Write-Host "== Plugin-Pruefung (REST) =="
$pluginsUrl = "$base/app/rest/server/plugins"
$pluginStatus = Get-StatusCode -Url $pluginsUrl -RequestHeaders $headers
Write-Host "GET $pluginsUrl -> $($pluginStatus[0]) $($pluginStatus[1])"

try {
    $pluginsResponse = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $pluginsUrl -Headers $headers -TimeoutSec 20
    if ($pluginsResponse.Content -match "(?i)mcp") {
        Write-Host "MCP Plugin-Hinweis gefunden (Textmatch auf 'mcp')."
    }
    else {
        Write-Host "Kein 'mcp'-Text in Pluginliste gefunden."
    }
}
catch {
    Write-Host "Pluginliste konnte nicht inhaltlich geprueft werden (z.B. wegen Auth)."
}

Write-Host ""
Write-Host "== MCP-Endpunkt-Probe =="
$candidates = @(
    "/app/mcp",
    "/app/mcp/sse",
    "/mcp"
)

$found = $false
foreach ($path in $candidates) {
    $url = "$base$path"
    $status = Get-StatusCode -Url $url -RequestHeaders $headers
    $code = [int]$status[0]
    $text = [string]$status[1]
    Write-Host "GET $url -> $code $text"

    if ($code -ne 404) {
        $found = $true
    }
}

Write-Host ""
if ($found) {
    Write-Host "MCP scheint erreichbar (mindestens ein Endpunkt liefert nicht 404)."
    exit 0
}

Write-Host "Kein MCP-Endpunkt gefunden (alle Kandidaten 404)."
exit 1
