param(
    [string]$BaseUrl = "",
    [string]$Token = $env:TEAMCITY_TOKEN,
    [ValidateSet("all", "inventory", "filters", "methods", "plugins", "negative")]
    [string]$Variant = "all",
    [string]$ReportPath = ""
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

function Resolve-ReportDirectory {
    param(
        [string]$ReportDir,
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($ReportDir)) {
        $resolvedDir = $RepoRoot
    }
    elseif ([System.IO.Path]::IsPathRooted($ReportDir)) {
        $resolvedDir = $ReportDir
    }
    else {
        $resolvedDir = Join-Path $RepoRoot $ReportDir
    }

    if (-not (Test-Path -LiteralPath $resolvedDir)) {
        New-Item -ItemType Directory -Path $resolvedDir -Force | Out-Null
    }

    return $resolvedDir
}

function Ensure-ParentDirectory {
    param(
        [string]$FilePath
    )

    $parentDir = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
}

function New-AuthHeaders {
    $headers = @{ Accept = "application/json" }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers.Authorization = "Bearer $Token"
    }
    return $headers
}

function New-Case {
    param(
        [string]$Group,
        [string]$Name,
        [string]$Method,
        [string]$Path,
        [string]$Body = ""
    )

    return [pscustomobject]@{
        group = $Group
        name = $Name
        method = $Method
        path = $Path
        body = $Body
    }
}

function Get-HeadersSnapshot {
    param(
        [hashtable]$Headers
    )

    $snapshot = [ordered]@{}
    foreach ($key in $Headers.Keys) {
        $snapshot[$key] = [string]$Headers[$key]
    }

    return $snapshot
}

function Get-ResponseHeadersSnapshot {
    param(
        $Response
    )

    $snapshot = [ordered]@{}
    if ($null -eq $Response -or $null -eq $Response.Headers) {
        return $snapshot
    }

    try {
        foreach ($key in $Response.Headers.AllKeys) {
            $snapshot[$key] = [string]$Response.Headers[$key]
        }
    }
    catch {
    }

    return $snapshot
}

function Invoke-DirectCase {
    param(
        [pscustomobject]$Case,
        [string]$Base
    )

    $url = "$Base$($Case.path)"
    $headers = New-AuthHeaders
    $requestBody = if ([string]::IsNullOrWhiteSpace($Case.body)) { "" } else { [string]$Case.body }

    try {
        if ([string]::IsNullOrWhiteSpace($requestBody)) {
            $response = Invoke-WebRequest -UseBasicParsing -Method $Case.method -Uri $url -Headers $headers -TimeoutSec 25
        }
        else {
            $headers["Content-Type"] = "application/json"
            $response = Invoke-WebRequest -UseBasicParsing -Method $Case.method -Uri $url -Headers $headers -Body $requestBody -TimeoutSec 25
        }

        $responseBody = if ($response.Content) { [string]$response.Content } else { "" }
        $snippet = $responseBody
        if ($snippet.Length -gt 500) {
            $snippet = $snippet.Substring(0, 500)
        }

        $requestHeadersSnapshot = Get-HeadersSnapshot -Headers $headers
        $responseHeadersSnapshot = Get-ResponseHeadersSnapshot -Response $response

        Write-Host "  OK  [$($response.StatusCode)] $($Case.method) $($Case.path)"

        return [pscustomobject]@{
            timestamp = (Get-Date).ToString("o")
            group = $Case.group
            name = $Case.name
            method = $Case.method
            path = $Case.path
            url = $url
            status = [int]$response.StatusCode
            ok = $true
            error = ""
            requestHeaders = $requestHeadersSnapshot
            rawRequestBody = $requestBody
            responseHeaders = $responseHeadersSnapshot
            rawResponseBody = $responseBody
            responseSnippet = $snippet
        }
    }
    catch {
        $status = $null
        $rawBody = ""
        $responseHeadersSnapshot = [ordered]@{}

        if ($_.Exception.Response) {
            $errResponse = $_.Exception.Response
            $status = [int]$errResponse.StatusCode
            $responseHeadersSnapshot = Get-ResponseHeadersSnapshot -Response $errResponse
            try {
                $stream = $errResponse.GetResponseStream()
                if ($stream) {
                    $rawBody = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                }
            }
            catch {
            }
        }

        if ($rawBody.Length -gt 500) {
            $rawBody = $rawBody.Substring(0, 500)
        }

        $requestHeadersSnapshot = Get-HeadersSnapshot -Headers $headers

        Write-Host "  ERR [$status] $($Case.method) $($Case.path) -> $($_.Exception.Message)"

        return [pscustomobject]@{
            timestamp = (Get-Date).ToString("o")
            group = $Case.group
            name = $Case.name
            method = $Case.method
            path = $Case.path
            url = $url
            status = $status
            ok = $false
            error = [string]$_.Exception.Message
            requestHeaders = $requestHeadersSnapshot
            rawRequestBody = $requestBody
            responseHeaders = $responseHeadersSnapshot
            rawResponseBody = $rawBody
            responseSnippet = $rawBody
        }
    }
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

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "TEAMCITY_TOKEN fehlt. Trage ihn in .env ein oder setze: `$env:TEAMCITY_TOKEN = '<token>'"
}

$defaultReportDir = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_REPORT_DIR"
$defaultReportDir = Resolve-ReportDirectory -ReportDir $defaultReportDir -RepoRoot $repoRoot
$base = $BaseUrl.TrimEnd('/')

Write-Host ""
Write-Host "== TeamCity Direct API Variants =="
Write-Host "Variant: $Variant"
Write-Host "Base URL: $base"
Write-Host ""

$cases = @(
    New-Case -Group "inventory" -Name "projects" -Method "GET" -Path "/app/rest/projects"
    New-Case -Group "inventory" -Name "buildTypes" -Method "GET" -Path "/app/rest/buildTypes"
    New-Case -Group "inventory" -Name "buildQueue" -Method "GET" -Path "/app/rest/buildQueue"
    New-Case -Group "inventory" -Name "agents" -Method "GET" -Path "/app/rest/agents"

    New-Case -Group "filters" -Name "builds-count-5" -Method "GET" -Path "/app/rest/builds?locator=count:5"
    New-Case -Group "filters" -Name "builds-running" -Method "GET" -Path "/app/rest/builds?locator=running:true"
    New-Case -Group "filters" -Name "failed-builds" -Method "GET" -Path "/app/rest/builds?locator=status:FAILURE,count:10"
    New-Case -Group "filters" -Name "projects-fields" -Method "GET" -Path "/app/rest/projects?fields=project(id,name,archived)"
    New-Case -Group "filters" -Name "tests-failed" -Method "GET" -Path "/app/rest/testOccurrences?locator=status:FAILURE,count:20"

    New-Case -Group "methods" -Name "options-projects" -Method "OPTIONS" -Path "/app/rest/projects"
    New-Case -Group "methods" -Name "head-projects" -Method "HEAD" -Path "/app/rest/projects"
    New-Case -Group "methods" -Name "options-builds" -Method "OPTIONS" -Path "/app/rest/builds"

    New-Case -Group "plugins" -Name "server-plugins" -Method "GET" -Path "/app/rest/server/plugins"

    New-Case -Group "negative" -Name "not-found" -Method "GET" -Path "/app/rest/does-not-exist"
    New-Case -Group "negative" -Name "invalid-locator" -Method "GET" -Path "/app/rest/builds?locator=__invalid__:true"
)

$selectedCases = if ($Variant -eq "all") {
    $cases
}
else {
    @($cases | Where-Object { $_.group -eq $Variant })
}

if ($selectedCases.Count -eq 0) {
    throw "Keine Testfaelle fuer Variant '$Variant' gefunden."
}

$results = @()
foreach ($case in $selectedCases) {
    $results += Invoke-DirectCase -Case $case -Base $base
}

$summaryByGroup = [ordered]@{}
$allGroups = @($selectedCases | Select-Object -ExpandProperty group -Unique)
foreach ($group in $allGroups) {
    $groupRows = @($results | Where-Object { $_.group -eq $group })
    $summaryByGroup[$group] = [ordered]@{
        total = $groupRows.Count
        ok = (@($groupRows | Where-Object { $_.ok }).Count)
        failed = (@($groupRows | Where-Object { -not $_.ok }).Count)
    }
}

$report = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    mode = "direct-api-variants"
    variant = $Variant
    baseUrl = $base
    summary = [ordered]@{
        total = $results.Count
        ok = (@($results | Where-Object { $_.ok }).Count)
        failed = (@($results | Where-Object { -not $_.ok }).Count)
        byGroup = $summaryByGroup
    }
    results = $results
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path $defaultReportDir "teamcity-direct-api-variants-$Variant-$stamp.json"
}

Ensure-ParentDirectory -FilePath $ReportPath
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "Fertig. Report gespeichert: $ReportPath"
exit 0
