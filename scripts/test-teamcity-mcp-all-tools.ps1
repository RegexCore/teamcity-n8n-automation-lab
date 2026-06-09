param(
    [string]$BaseUrl = "",
    [string]$Token = $env:TEAMCITY_TOKEN,
    [string]$BuildId = "",
    [switch]$AllowWriteOperations,
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

    return ($payload | ConvertTo-Json -Depth 20)
}

function Invoke-Mcp {
    param(
        [string]$Label,
        [string]$Body,
        [hashtable]$Headers,
        [string]$Url
    )

    try {
        $requestHeadersSnapshot = Get-HeadersSnapshot -Headers $Headers
        $response = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $Url -Headers $Headers -Body $Body -TimeoutSec 30

        $responseHeaders = [ordered]@{}
        if ($response.Headers) {
            foreach ($key in $response.Headers.AllKeys) {
                $responseHeaders[$key] = [string]$response.Headers[$key]
            }
        }

        Write-Host "  OK  [$($response.StatusCode)] $Label"
        return [pscustomobject]@{
            timestamp = (Get-Date).ToString("o")
            label = $Label
            url = $Url
            requestMethod = "POST"
            requestHeaders = $requestHeadersSnapshot
            ok = $true
            status = [int]$response.StatusCode
            error = ""
            rawRequestBody = $Body
            rawResponseBody = [string]$response.Content
            sessionId = [string]$response.Headers['Mcp-Session-Id']
            responseHeaders = $responseHeaders
        }
    }
    catch {
        $requestHeadersSnapshot = Get-HeadersSnapshot -Headers $Headers
        $status = $null
        $rawBody = ""
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $rawBody = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                }
            }
            catch {
            }
        }

        Write-Host "  ERR [$status] $Label -> $($_.Exception.Message)"
        return [pscustomobject]@{
            timestamp = (Get-Date).ToString("o")
            label = $Label
            url = $Url
            requestMethod = "POST"
            requestHeaders = $requestHeadersSnapshot
            ok = $false
            status = $status
            error = [string]$_.Exception.Message
            rawRequestBody = $Body
            rawResponseBody = $rawBody
            sessionId = ""
            responseHeaders = @{}
        }
    }
}

function ConvertFrom-JsonSafe {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    try {
        return ($Body | ConvertFrom-Json -Depth 50)
    }
    catch {
        try {
            # Windows PowerShell 5.1 does not support -Depth for ConvertFrom-Json.
            return ($Body | ConvertFrom-Json)
        }
        catch {
            return $null
        }
    }
}

function New-McpHeaders {
    $headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/json"
        "Content-Type" = "application/json"
    }

    if (-not [string]::IsNullOrWhiteSpace($script:McpSessionId)) {
        $headers['Mcp-Session-Id'] = $script:McpSessionId
    }

    return $headers
}

function Invoke-RpcMethod {
    param(
        [string]$Method,
        [object]$Id,
        [hashtable]$Params,
        [string]$Label
    )

    $payload = New-RpcPayload -Id $Id -Method $Method -Params $Params
    $exchange = Invoke-Mcp -Label $Label -Body $payload -Headers (New-McpHeaders) -Url $script:McpUrl

    if (-not [string]::IsNullOrWhiteSpace($exchange.sessionId) -and [string]::IsNullOrWhiteSpace($script:McpSessionId)) {
        $script:McpSessionId = $exchange.sessionId
    }

    $parsed = ConvertFrom-JsonSafe -Body $exchange.rawResponseBody
    return [pscustomobject]@{
        exchange = $exchange
        parsed = $parsed
    }
}

function Add-ToolCallResult {
    param(
        [string]$ToolName,
        [string]$Variant,
        [hashtable]$Arguments,
        [int]$CallId,
        [string]$Note = ""
    )

    $rpc = Invoke-RpcMethod -Method "tools/call" -Id ([string]$CallId) -Params @{ name = $ToolName; arguments = $Arguments } -Label "tools/call: $ToolName ($Variant)"

    $result = [ordered]@{
        toolName = $ToolName
        variant = $Variant
        note = $Note
        arguments = $Arguments
        requestMethod = $rpc.exchange.requestMethod
        url = $rpc.exchange.url
        requestHeaders = $rpc.exchange.requestHeaders
        status = $rpc.exchange.status
        ok = $rpc.exchange.ok
        error = $rpc.exchange.error
        responseHeaders = $rpc.exchange.responseHeaders
        rawRequestBody = $rpc.exchange.rawRequestBody
        rawResponseBody = $rpc.exchange.rawResponseBody
        parsedResponse = $rpc.parsed
    }

    $script:ToolCallResults += $result
    $report.exchanges += [ordered]@{ category = "tool"; stage = "tools/call"; label = $rpc.exchange.label; exchange = $rpc.exchange }
}

function New-GenericArgsFromSchema {
    param(
        [pscustomobject]$Tool,
        [string]$AutoBuildId
    )

    $args = @{}
    $requiredFields = @()

    if ($Tool.inputSchema -and $Tool.inputSchema.required) {
        $requiredFields = @($Tool.inputSchema.required)
    }

    foreach ($field in $requiredFields) {
        switch ($field) {
            "path" { $args[$field] = "/app/rest/projects" }
            "query" { $args[$field] = "locator=count:5" }
            "buildId" { $args[$field] = if (-not [string]::IsNullOrWhiteSpace($AutoBuildId)) { $AutoBuildId } else { "1" } }
            "id" { $args[$field] = "1" }
            "count" { $args[$field] = "50" }
            "body" { $args[$field] = "{}" }
            default { $args[$field] = "demo" }
        }
    }

    return $args
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
$script:McpUrl = "$base/app/mcp"
$script:McpSessionId = ""
$script:ToolCallResults = @()

Write-Host ""
Write-Host "== TeamCity MCP All-Tools Probe =="
Write-Host "Base URL: $base"
Write-Host "Write operations enabled: $([bool]$AllowWriteOperations)"
Write-Host ""

$report = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    mode = "mcp-all-tools"
    baseUrl = $base
    allowWriteOperations = [bool]$AllowWriteOperations
    sessionId = ""
    setup = [ordered]@{}
    toolCatalog = @()
    toolCalls = @()
    metaCalls = [ordered]@{}
    exchanges = @()
}

$init = Invoke-RpcMethod -Method "initialize" -Id "1" -Params @{
    protocolVersion = "2024-11-05"
    capabilities = @{}
    clientInfo = @{ name = "teamcity-mcp-all-tools"; version = "1.0" }
} -Label "initialize"
$report.setup.initialize = $init.exchange
$report.exchanges += [ordered]@{ category = "setup"; stage = "initialize"; label = $init.exchange.label; exchange = $init.exchange }

if (-not $init.exchange.ok) {
    $reportPathError = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        Join-Path $defaultReportDir ("teamcity-mcp-all-tools-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")
    }
    else {
        $ReportPath
    }

    Ensure-ParentDirectory -FilePath $reportPathError
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reportPathError -Encoding UTF8
    throw "MCP initialize fehlgeschlagen. Report gespeichert: $reportPathError"
}

$report.sessionId = $script:McpSessionId

$initialized = Invoke-RpcMethod -Method "notifications/initialized" -Id $null -Params @{} -Label "notifications/initialized"
$report.setup.initialized = $initialized.exchange
$report.exchanges += [ordered]@{ category = "setup"; stage = "notifications/initialized"; label = $initialized.exchange.label; exchange = $initialized.exchange }

$tools = Invoke-RpcMethod -Method "tools/list" -Id "2" -Params @{} -Label "tools/list"
$report.setup.toolsList = $tools.exchange
$report.exchanges += [ordered]@{ category = "setup"; stage = "tools/list"; label = $tools.exchange.label; exchange = $tools.exchange }

$toolCatalog = @()
if ($tools.parsed -and $tools.parsed.result -and $tools.parsed.result.tools) {
    $toolCatalog = @($tools.parsed.result.tools)
}

$report.toolCatalog = @($toolCatalog | ForEach-Object {
    [ordered]@{
        name = [string]$_.name
        description = [string]$_.description
        inputSchema = $_.inputSchema
    }
})

$resources = Invoke-RpcMethod -Method "resources/list" -Id "3" -Params @{} -Label "resources/list"
$report.metaCalls.resourcesList = $resources.exchange
$report.exchanges += [ordered]@{ category = "meta"; stage = "resources/list"; label = $resources.exchange.label; exchange = $resources.exchange }

$report.metaCalls.promptsList = [ordered]@{
    skipped = $true
    reason = "removed: prompts/list is not supported by this TeamCity MCP server"
}

$resolvedBuildId = $BuildId
if ([string]::IsNullOrWhiteSpace($resolvedBuildId) -and ($toolCatalog | Where-Object { $_.name -eq "teamcity_rest_get" } | Select-Object -First 1)) {
    $buildProbe = Invoke-RpcMethod -Method "tools/call" -Id "5" -Params @{
        name = "teamcity_rest_get"
        arguments = @{ path = "/app/rest/builds"; query = "locator=state:finished,count:1&fields=build(id)" }
    } -Label "tools/call: teamcity_rest_get (auto-build-id)"

    $script:ToolCallResults += [ordered]@{
        toolName = "teamcity_rest_get"
        variant = "auto-build-id"
        note = "Hilfsaufruf zur BuildId-Ermittlung"
        arguments = @{ path = "/app/rest/builds"; query = "locator=state:finished,count:1&fields=build(id)" }
        requestMethod = $buildProbe.exchange.requestMethod
        url = $buildProbe.exchange.url
        requestHeaders = $buildProbe.exchange.requestHeaders
        status = $buildProbe.exchange.status
        ok = $buildProbe.exchange.ok
        error = $buildProbe.exchange.error
        responseHeaders = $buildProbe.exchange.responseHeaders
        rawRequestBody = $buildProbe.exchange.rawRequestBody
        rawResponseBody = $buildProbe.exchange.rawResponseBody
        parsedResponse = $buildProbe.parsed
    }
    $report.exchanges += [ordered]@{ category = "tool"; stage = "tools/call"; label = $buildProbe.exchange.label; exchange = $buildProbe.exchange }

    if ($buildProbe.parsed -and $buildProbe.parsed.result -and $buildProbe.parsed.result.content) {
        try {
            $contentText = [string]$buildProbe.parsed.result.content[0].text
            $buildJson = $contentText | ConvertFrom-Json -Depth 20
            if ($buildJson.build) {
                $firstBuild = @($buildJson.build | Select-Object -First 1)[0]
                if ($firstBuild -and $firstBuild.id) {
                    $resolvedBuildId = [string]$firstBuild.id
                }
            }
        }
        catch {
        }
    }
}

Write-Host "Aufrufe aller verfuegbaren Tools..."

$callId = 100
foreach ($tool in $toolCatalog) {
    $toolName = [string]$tool.name

    switch ($toolName) {
        "teamcity_rest_get" {
            Add-ToolCallResult -ToolName $toolName -Variant "projects" -Arguments @{ path = "/app/rest/projects" } -CallId $callId -Note "Basisinventar"
            $callId++
            Add-ToolCallResult -ToolName $toolName -Variant "buildTypes" -Arguments @{ path = "/app/rest/buildTypes" } -CallId $callId -Note "Build-Konfigurationen"
            $callId++
            Add-ToolCallResult -ToolName $toolName -Variant "builds" -Arguments @{ path = "/app/rest/builds"; query = "locator=count:10" } -CallId $callId -Note "Build-Liste mit Query"
            $callId++
            Add-ToolCallResult -ToolName $toolName -Variant "agents" -Arguments @{ path = "/app/rest/agents" } -CallId $callId -Note "Agent-Liste"
            $callId++
        }
        "teamcity_build_log" {
            $bid = if (-not [string]::IsNullOrWhiteSpace($resolvedBuildId)) { $resolvedBuildId } else { "1" }
            Add-ToolCallResult -ToolName $toolName -Variant "build-log" -Arguments @{ buildId = $bid; count = "200" } -CallId $callId -Note "Build-Log fuer BuildId $bid"
            $callId++
        }
        "teamcity_rest_post" {
            if ($AllowWriteOperations) {
                Add-ToolCallResult -ToolName $toolName -Variant "post-negative-demo" -Arguments @{ path = "/app/rest/buildQueue"; body = '{"buildType":{"id":"__does_not_exist__"}}' } -CallId $callId -Note "Schreibpfad-Demo mit absichtlich ungueltiger BuildType-ID"
                $callId++
            }
            else {
                $script:ToolCallResults += [ordered]@{
                    toolName = $toolName
                    variant = "write-skipped"
                    note = "Uebersprungen. Mit -AllowWriteOperations aktivieren."
                    arguments = @{}
                    requestMethod = ""
                    url = ""
                    requestHeaders = @{}
                    status = $null
                    ok = $false
                    error = "Write operation skipped"
                    responseHeaders = @{}
                    rawRequestBody = ""
                    rawResponseBody = ""
                    parsedResponse = $null
                }
            }
        }
        default {
            $genericArgs = New-GenericArgsFromSchema -Tool $tool -AutoBuildId $resolvedBuildId
            Add-ToolCallResult -ToolName $toolName -Variant "generic-from-schema" -Arguments $genericArgs -CallId $callId -Note "Generischer Aufruf basierend auf required-Feldern"
            $callId++
        }
    }
}

$report.toolCalls = $script:ToolCallResults

$report.summary = [ordered]@{
    discoveredTools = $toolCatalog.Count
    attemptedCalls = $report.toolCalls.Count
    successfulCalls = (@($report.toolCalls | Where-Object { $_.ok }).Count)
    failedCalls = (@($report.toolCalls | Where-Object { -not $_.ok }).Count)
    resolvedBuildId = $resolvedBuildId
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path $defaultReportDir "teamcity-mcp-all-tools-$stamp.json"
}

Ensure-ParentDirectory -FilePath $ReportPath
$report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "Fertig. Report gespeichert: $ReportPath"
exit 0
