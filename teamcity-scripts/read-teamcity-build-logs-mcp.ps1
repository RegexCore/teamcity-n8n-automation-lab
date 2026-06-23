param(
    [string]$BaseUrl = "",
    [string]$Token = $env:TEAMCITY_TOKEN,
    [string[]]$BuildId = @(),
    [string]$BuildTypeId = "",
    [switch]$AllBuilds,
    [int]$MaxBuilds = 5,
    [ValidateSet("all", "warnings", "errors")]
    [string]$LogFilter = "all",
    [int]$MaxLogLines = 120,
    [int]$MaxLineLength = 220,
    [int]$LogPageCount = 300,
    [int]$LogStart = 0,
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

function Get-EnvValueFromDotEnv {
    param([string]$EnvFilePath, [string]$Key)

    if (-not (Test-Path -LiteralPath $EnvFilePath)) {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $EnvFilePath -ErrorAction Stop)) {
        if ($line -match '^\s*#') { continue }
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

function ConvertFrom-JsonCompat {
    param([string]$Body, [int]$Depth = 40)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    try {
        return $Body | ConvertFrom-Json -Depth $Depth
    }
    catch {
        try {
            return $Body | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
}

function New-RpcPayload {
    param([object]$Id, [string]$Method, [hashtable]$Params = @{})

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

function New-McpHeaders {
    $headers = @{
        Authorization = "Bearer $script:Token"
        Accept = "application/json"
        "Content-Type" = "application/json"
    }

    if (-not [string]::IsNullOrWhiteSpace($script:McpSessionId)) {
        $headers["Mcp-Session-Id"] = $script:McpSessionId
    }

    return $headers
}

function Invoke-McpRaw {
    param([string]$Label, [string]$Body)

    $url = "$script:base/app/mcp"
    $headers = New-McpHeaders

    try {
        $res = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $url -Headers $headers -Body $Body -TimeoutSec 40
        $sessionId = [string]$res.Headers["Mcp-Session-Id"]
        if (-not [string]::IsNullOrWhiteSpace($sessionId) -and [string]::IsNullOrWhiteSpace($script:McpSessionId)) {
            $script:McpSessionId = $sessionId
        }

        Write-Host "  OK  [$($res.StatusCode)] $Label"
        return [pscustomobject]@{
            ok = $true
            status = [int]$res.StatusCode
            url = $url
            label = $Label
            requestBody = $Body
            responseBody = [string]$res.Content
            error = ""
            sessionId = $sessionId
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

        Write-Host "  ERR [$status] $Label -> $($_.Exception.Message)"
        return [pscustomobject]@{
            ok = $false
            status = $status
            url = $url
            label = $Label
            requestBody = $Body
            responseBody = $responseBody
            error = [string]$_.Exception.Message
            sessionId = ""
        }
    }
}

function Invoke-Rpc {
    param([object]$Id, [string]$Method, [hashtable]$Params, [string]$Label)

    $body = New-RpcPayload -Id $Id -Method $Method -Params $Params
    $exchange = Invoke-McpRaw -Label $Label -Body $body
    $parsed = ConvertFrom-JsonCompat -Body $exchange.responseBody -Depth 60

    return [pscustomobject]@{
        exchange = $exchange
        parsed = $parsed
    }
}

function Get-FirstContentText {
    param([object]$ParsedRpc)

    if ($null -eq $ParsedRpc -or $null -eq $ParsedRpc.result -or $null -eq $ParsedRpc.result.content) {
        return ""
    }

    $content = @($ParsedRpc.result.content)
    if ($content.Count -eq 0) {
        return ""
    }

    if ($null -eq $content[0] -or $null -eq $content[0].text) {
        return ""
    }

    return [string]$content[0].text
}

function Invoke-McpTool {
    param([string]$ToolName, [hashtable]$Arguments, [int]$RequestId)

    $rpc = Invoke-Rpc -Id ([string]$RequestId) -Method "tools/call" -Params @{ name = $ToolName; arguments = $Arguments } -Label "tools/call: $ToolName"
    return [pscustomobject]@{
        ok = $rpc.exchange.ok
        status = $rpc.exchange.status
        tool = $ToolName
        arguments = $Arguments
        error = $rpc.exchange.error
        requestBody = $rpc.exchange.requestBody
        responseBody = $rpc.exchange.responseBody
        parsedRpc = $rpc.parsed
        contentText = Get-FirstContentText -ParsedRpc $rpc.parsed
    }
}

function Parse-RestToolBody {
    param([string]$ToolContentText)

    $parsed = ConvertFrom-JsonCompat -Body $ToolContentText -Depth 60
    if ($null -eq $parsed) {
        return $null
    }

    if ($parsed.body) {
        return $parsed.body
    }

    return $parsed
}

function Get-BuildsFromRestToolResponse {
    param([string]$ToolContentText)

    $body = Parse-RestToolBody -ToolContentText $ToolContentText
    if ($null -eq $body) {
        return @()
    }

    if ($body.build) {
        return @($body.build)
    }

    if ($body.id) {
        return @($body)
    }

    return @()
}

function Get-FilteredLogLines {
    param(
        [string]$RawText,
        [string]$Filter,
        [int]$LineLimit,
        [int]$LineLength
    )

    if ([string]::IsNullOrWhiteSpace($RawText)) {
        return @()
    }

    $allLines = @($RawText -split "`r?`n")
    $filtered = @()

    foreach ($line in $allLines) {
        $current = ([string]$line).TrimEnd()
        if ([string]::IsNullOrWhiteSpace($current)) {
            continue
        }

        $include = $true
        switch ($Filter) {
            "errors" {
                $include = ($current -match '\[(FAILURE|ERROR)\]')
            }
            "warnings" {
                $include = ($current -match '\[(WARNING|FAILURE|ERROR)\]')
            }
            default {
                $include = $true
            }
        }

        if (-not $include) {
            continue
        }

        if ($current.Length -gt $LineLength) {
            $current = $current.Substring(0, $LineLength) + "..."
        }

        $filtered += $current
    }

    if ($filtered.Count -gt $LineLimit) {
        return @($filtered | Select-Object -First $LineLimit) + @("... (weitere $($filtered.Count - $LineLimit) Zeilen)")
    }

    return $filtered
}

function Write-BuildBlock {
    param(
        [object]$Build,
        [string[]]$Lines
    )

    Write-Host ""
    Write-Host ("=" * 110)
    Write-Host ("BuildId: {0} | BuildType: {1} | Number: {2} | Status: {3} | State: {4}" -f $Build.id, $Build.buildTypeId, $Build.number, $Build.status, $Build.state)
    Write-Host ("Branch:  {0}" -f $Build.branchName)
    Write-Host ("WebUrl:  {0}" -f $Build.webUrl)
    Write-Host ("=" * 110)

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        Write-Host "  (keine passenden Logzeilen gefunden)"
        return
    }

    $lineNo = 1
    foreach ($line in $Lines) {
        $prefix = "{0,4}" -f $lineNo
        if ($line -match '\[(FAILURE|ERROR)\]') {
            Write-Host "  $prefix | $line" -ForegroundColor Red
        }
        elseif ($line -match '\[WARNING\]') {
            Write-Host "  $prefix | $line" -ForegroundColor Yellow
        }
        else {
            Write-Host "  $prefix | $line"
        }
        $lineNo++
    }
}

function Select-BuildsViaMcp {
    $selected = @()

    if ($BuildId.Count -gt 0) {
        foreach ($id in ($BuildId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            $detailCall = Invoke-McpTool -ToolName "teamcity_rest_get" -Arguments @{ path = "/app/rest/builds/id:$id"; query = "fields=id,number,status,state,buildTypeId,branchName,webUrl,startDate,finishDate" } -RequestId $script:RequestId
            $script:RequestId++
            $script:Exchanges += $detailCall

            if ($detailCall.ok) {
                $buildRows = Get-BuildsFromRestToolResponse -ToolContentText $detailCall.contentText
                if ($buildRows.Count -gt 0) {
                    $selected += $buildRows[0]
                }
            }
        }

        return @($selected)
    }

    $locatorParts = @("state:finished")
    if (-not [string]::IsNullOrWhiteSpace($BuildTypeId)) {
        $locatorParts += "buildType:(id:$BuildTypeId)"
    }

    if ($AllBuilds) {
        $locatorParts += "count:$MaxBuilds"
    }
    else {
        $locatorParts += "count:1"
    }

    $locator = [string]::Join(",", $locatorParts)
    $buildListCall = Invoke-McpTool -ToolName "teamcity_rest_get" -Arguments @{ path = "/app/rest/builds"; query = "locator=$locator&fields=build(id,number,status,state,buildTypeId,branchName,webUrl,startDate,finishDate)" } -RequestId $script:RequestId
    $script:RequestId++
    $script:Exchanges += $buildListCall

    if ($buildListCall.ok) {
        return Get-BuildsFromRestToolResponse -ToolContentText $buildListCall.contentText
    }

    return @()
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

if ($MaxBuilds -lt 1) { $MaxBuilds = 1 }
if ($MaxLogLines -lt 1) { $MaxLogLines = 1 }
if ($MaxLineLength -lt 40) { $MaxLineLength = 40 }
if ($LogPageCount -lt 1) { $LogPageCount = 1 }
if ($LogPageCount -gt 300) { $LogPageCount = 300 }
if ($LogStart -lt 0) { $LogStart = 0 }

$script:Token = $Token
$script:base = $BaseUrl.TrimEnd('/')
$script:McpSessionId = ""
$script:RequestId = 100
$script:Exchanges = @()

Write-Host ""
Write-Host "== TeamCity Build Logs (MCP) =="
Write-Host "Base URL: $script:base"
Write-Host "Log filter: $LogFilter"
Write-Host ""

$initialize = Invoke-Rpc -Id "1" -Method "initialize" -Params @{
    protocolVersion = "2024-11-05"
    capabilities = @{}
    clientInfo = @{ name = "read-teamcity-build-logs-mcp"; version = "1.0" }
} -Label "initialize"
$script:Exchanges += $initialize
if (-not $initialize.exchange.ok) {
    throw "MCP initialize fehlgeschlagen: $($initialize.exchange.error)"
}

$initialized = Invoke-Rpc -Id $null -Method "notifications/initialized" -Params @{} -Label "notifications/initialized"
$script:Exchanges += $initialized

$tools = Invoke-Rpc -Id "2" -Method "tools/list" -Params @{} -Label "tools/list"
$script:Exchanges += $tools
if (-not $tools.exchange.ok) {
    throw "MCP tools/list fehlgeschlagen: $($tools.exchange.error)"
}

$toolNames = @()
if ($tools.parsed -and $tools.parsed.result -and $tools.parsed.result.tools) {
    $toolNames = @($tools.parsed.result.tools | ForEach-Object { [string]$_.name })
}

if ($toolNames -notcontains "teamcity_rest_get") {
    throw "MCP Tool 'teamcity_rest_get' fehlt."
}
if ($toolNames -notcontains "teamcity_build_log") {
    throw "MCP Tool 'teamcity_build_log' fehlt."
}

$selectedBuilds = Select-BuildsViaMcp
if ($selectedBuilds.Count -eq 0) {
    throw "Keine Builds gefunden. Nutze -BuildId <id> oder -AllBuilds (optional mit -BuildTypeId)."
}

$report = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    mode = "build-logs-mcp"
    baseUrl = $script:base
    mcpEndpoint = "$script:base/app/mcp"
    sessionId = $script:McpSessionId
    parameters = [ordered]@{
        buildId = $BuildId
        buildTypeId = $BuildTypeId
        allBuilds = [bool]$AllBuilds
        maxBuilds = $MaxBuilds
        logFilter = $LogFilter
        maxLogLines = $MaxLogLines
        logStart = $LogStart
        logPageCount = $LogPageCount
    }
    summary = [ordered]@{
        selectedBuilds = $selectedBuilds.Count
        successfulLogs = 0
        failedLogs = 0
    }
    builds = @()
    exchanges = @()
}

foreach ($build in $selectedBuilds) {
    $buildIdValue = [string]$build.id
    Write-Host "Lese Build-Log ueber MCP fuer BuildId: $buildIdValue"

    $arguments = @{ buildId = $buildIdValue; start = [string]$LogStart; count = [string]$LogPageCount }
    if ($LogFilter -ne "all") {
        $arguments.filter = $LogFilter
    }

    $logCall = Invoke-McpTool -ToolName "teamcity_build_log" -Arguments $arguments -RequestId $script:RequestId
    $script:RequestId++
    $script:Exchanges += $logCall

    if (-not $logCall.ok) {
        Write-Host "  ERR [$($logCall.status)] Build-Log $buildIdValue -> $($logCall.error)"
        $report.summary.failedLogs++
        $report.builds += [ordered]@{
            build = $build
            log = [ordered]@{
                ok = $false
                status = $logCall.status
                error = $logCall.error
                tool = "teamcity_build_log"
                lineCount = 0
                previewLines = @()
            }
        }
        continue
    }

    $previewLines = Get-FilteredLogLines -RawText $logCall.contentText -Filter $LogFilter -LineLimit $MaxLogLines -LineLength $MaxLineLength
    Write-BuildBlock -Build $build -Lines $previewLines

    $report.summary.successfulLogs++
    $report.builds += [ordered]@{
        build = $build
        log = [ordered]@{
            ok = $true
            status = $logCall.status
            error = ""
            tool = "teamcity_build_log"
            lineCount = $previewLines.Count
            previewLines = $previewLines
        }
    }
}

$report.exchanges = @($script:Exchanges | ForEach-Object {
    [ordered]@{
        label = if ($_.exchange) { $_.exchange.label } else { [string]$_.tool }
        ok = if ($_.exchange) { $_.exchange.ok } else { [bool]$_.ok }
        status = if ($_.exchange) { $_.exchange.status } else { $_.status }
        error = if ($_.exchange) { $_.exchange.error } else { $_.error }
        requestBody = if ($_.exchange) { $_.exchange.requestBody } else { $_.requestBody }
        responseBody = if ($_.exchange) { $_.exchange.responseBody } else { $_.responseBody }
    }
})

$defaultReportDir = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_REPORT_DIR"
$defaultReportDir = Resolve-ReportDirectory -ReportDir $defaultReportDir -RepoRoot $repoRoot

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path $defaultReportDir "tc-build-logs-mcp-$stamp.json"
}

Ensure-ParentDirectory -FilePath $ReportPath
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "Fertig. MCP-Report gespeichert: $ReportPath"
