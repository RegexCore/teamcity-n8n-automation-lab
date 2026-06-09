param(
    [string]$BaseUrl = "",
    [string]$Token = $env:TEAMCITY_TOKEN,
    [string]$BuildId = "",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

function Get-EnvValueFromDotEnv {
    param([string]$EnvFilePath, [string]$Key)
    if (-not (Test-Path -LiteralPath $EnvFilePath)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $EnvFilePath -ErrorAction Stop)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match "^\s*$Key\s*=\s*(.*)\s*$") {
            $v = $Matches[1].Trim().Trim('"').Trim("'")
            if ([string]::IsNullOrWhiteSpace($v)) {
                return $null
            }
            return $v
        }
    }
    return $null
}

function Resolve-ReportDirectory {
    param([string]$ReportDir, [string]$RepoRoot)

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
    param([string]$FilePath)

    $parentDir = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
}

function New-RpcPayload {
    param([string]$Id, [string]$Method, [hashtable]$Params = @{})
    return @{ jsonrpc = "2.0"; id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 10
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$envFilePath = Join-Path $repoRoot ".env"

if ([string]::IsNullOrWhiteSpace($Token))   { $Token = Get-EnvValueFromDotEnv $envFilePath "TEAMCITY_TOKEN" }
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = Get-EnvValueFromDotEnv $envFilePath "TEAMCITY_BASE_URL" }
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = "http://localhost:8111" }

$base = $BaseUrl.TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "TEAMCITY_TOKEN fehlt. Trage ihn in .env ein oder setze: `$env:TEAMCITY_TOKEN = '<token>'"
}

$headers = @{ Authorization = "Bearer $Token"; Accept = "application/json"; "Content-Type" = "application/json" }

function Invoke-Mcp {
    param([string]$Label, [string]$Body)

    $url = "$base/app/mcp"
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $url -Headers $headers -Body $Body -TimeoutSec 25
        $responseBody = [string]$response.Content
        Write-Host "  OK  [$($response.StatusCode)] $Label"
        return [pscustomobject]@{ url = $url; status = [int]$response.StatusCode; ok = $true; body = $responseBody; error = "" }
    }
    catch {
        $status = $null
        $responseBody = ""
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) { $responseBody = (New-Object System.IO.StreamReader($stream)).ReadToEnd() }
            } catch {}
        }
        Write-Host "  ERR [$status] $Label -> $($_.Exception.Message)"
        return [pscustomobject]@{ url = $url; status = $status; ok = $false; body = $responseBody; error = [string]$_.Exception.Message }
    }
}

$report = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    queryMode   = "mcp"
    baseUrl     = $base
    sections    = [ordered]@{}
}

Write-Host ""
Write-Host "=== 1. MCP initialize ==="
$report.sections.initialize = Invoke-Mcp "MCP initialize" (New-RpcPayload "1" "initialize" @{
    protocolVersion = "2024-11-05"
    capabilities    = @{}
    clientInfo      = @{ name = "tc-builds-query-mcp"; version = "1.0" }
})

Write-Host ""
Write-Host "=== 2. MCP tools/list ==="
$report.sections.toolsList = Invoke-Mcp "MCP tools/list" (New-RpcPayload "2" "tools/list" @{})

Write-Host ""
Write-Host "=== 3. MCP list_projects ==="
$report.sections.projects = Invoke-Mcp "MCP tools/call: list_projects" (New-RpcPayload "3" "tools/call" @{
    name      = "list_projects"
    arguments = @{}
})

Write-Host ""
Write-Host "=== 4. MCP list_build_configurations ==="
$report.sections.buildTypes = Invoke-Mcp "MCP tools/call: list_build_configurations" (New-RpcPayload "4" "tools/call" @{
    name      = "list_build_configurations"
    arguments = @{}
})

Write-Host ""
Write-Host "=== 5. MCP list_builds ==="
$report.sections.builds = Invoke-Mcp "MCP tools/call: list_builds" (New-RpcPayload "5" "tools/call" @{
    name      = "list_builds"
    arguments = @{ count = 10 }
})

if (-not [string]::IsNullOrWhiteSpace($BuildId)) {
    Write-Host ""
    Write-Host "=== 6. MCP get_build_log ==="
    $report.sections.buildLog = Invoke-Mcp "MCP tools/call: get_build_log" (New-RpcPayload "6" "tools/call" @{
        name      = "get_build_log"
        arguments = @{ buildId = [int]$BuildId }
    })

    Write-Host ""
    Write-Host "=== 7. MCP get_test_results ==="
    $report.sections.testResults = Invoke-Mcp "MCP tools/call: get_test_results" (New-RpcPayload "7" "tools/call" @{
        name      = "get_test_results"
        arguments = @{ buildId = [int]$BuildId }
    })
}
else {
    Write-Host ""
    Write-Host "SKIP: Kein -BuildId gesetzt. get_build_log und get_test_results werden uebersprungen."
}

Write-Host ""
Write-Host "=== 8. MCP resources/list ==="
$report.sections.resources = Invoke-Mcp "MCP resources/list" (New-RpcPayload "8" "resources/list" @{})

Write-Host ""
Write-Host "=== 9. MCP prompts/list ==="
$report.sections.prompts = Invoke-Mcp "MCP prompts/list" (New-RpcPayload "9" "prompts/list" @{})

$defaultReportDir = Get-EnvValueFromDotEnv $envFilePath "TEAMCITY_REPORT_DIR"
$defaultReportDir = Resolve-ReportDirectory $defaultReportDir $repoRoot

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path $defaultReportDir "tc-builds-query-mcp-$stamp.json"
}

Ensure-ParentDirectory $ReportPath
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host ""
Write-Host "Report gespeichert: $ReportPath"