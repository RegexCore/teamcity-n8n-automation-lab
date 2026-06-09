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
    param([object]$Id, [string]$Method, [hashtable]$Params = @{})

    $payload = [ordered]@{
        jsonrpc = "2.0"
        method = $Method
        params = $Params
    }

    if ($null -ne $Id -and -not [string]::IsNullOrWhiteSpace([string]$Id)) {
        $payload.id = $Id
    }

    return $payload | ConvertTo-Json -Depth 10
}

function ConvertFrom-RpcResponse {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    try {
        return $Body | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function ConvertTo-ReadableRpcMessage {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    try {
        return $Body | ConvertFrom-Json -Depth 20
    }
    catch {
        return $null
    }
}

function Get-RegexMatchValue {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success -and $match.Groups.Count -gt 1) {
        return $match.Groups[1].Value
    }

    return $null
}

function New-ReadableMcpSection {
    param(
        [pscustomobject]$Exchange,
        [string]$ToolName = "",
        [hashtable]$ToolArguments = @{}
    )

    $requestJson = ConvertTo-ReadableRpcMessage -Body $Exchange.rawRequestBody
    $responseJson = ConvertTo-ReadableRpcMessage -Body $Exchange.rawResponseBody

    $rpcMethod = if ($null -ne $requestJson -and $requestJson.PSObject.Properties.Name -contains 'method') { [string]$requestJson.method } else { Get-RegexMatchValue -Text $Exchange.rawRequestBody -Pattern '"method"\s*:\s*"([^"]+)"' }
    $rpcId = if ($null -ne $requestJson -and $requestJson.PSObject.Properties.Name -contains 'id') { [string]$requestJson.id } else { Get-RegexMatchValue -Text $Exchange.rawRequestBody -Pattern '"id"\s*:\s*"?([^"\r\n,}]+)"?' }
    $rpcParams = if ($null -ne $requestJson -and $requestJson.PSObject.Properties.Name -contains 'params') { $requestJson.params } else { $null }

    $responseResult = $null
    $responseError = $null
    if ($null -ne $responseJson) {
        if ($responseJson.PSObject.Properties.Name -contains 'result') {
            $responseResult = $responseJson.result
        }
        if ($responseJson.PSObject.Properties.Name -contains 'error') {
            $responseError = $responseJson.error
        }
    }

    if ($null -eq $responseResult -and -not [string]::IsNullOrWhiteSpace($Exchange.rawResponseBody) -and $Exchange.rawResponseBody -match '"result"\s*:') {
        $responseResult = [pscustomobject]@{ raw = $Exchange.rawResponseBody }
    }

    if ($null -eq $responseError -and -not [string]::IsNullOrWhiteSpace($Exchange.rawResponseBody) -and $Exchange.rawResponseBody -match '"error"\s*:') {
        $responseError = [pscustomobject]@{ raw = $Exchange.rawResponseBody }
    }

    return [ordered]@{
        url = $Exchange.url
        status = $Exchange.status
        ok = $Exchange.ok
        rpcMethod = $rpcMethod
        rpcId = $rpcId
        toolName = $ToolName
        arguments = $ToolArguments
        rawRequestBody = $Exchange.rawRequestBody
        rawResponseBody = $Exchange.rawResponseBody
        parsedRequest = if ($null -ne $requestJson) { $requestJson } else { [ordered]@{ method = $rpcMethod; id = $rpcId; toolName = $ToolName; arguments = $ToolArguments } }
        parsedResponse = if ($null -ne $responseJson) { $responseJson } else { [ordered]@{ hasResult = [bool]($Exchange.rawResponseBody -match '"result"\s*:'); hasError = [bool]($Exchange.rawResponseBody -match '"error"\s*:'); raw = $Exchange.rawResponseBody } }
        parsedResponseResult = $responseResult
        parsedResponseError = $responseError
        responseHeaders = $Exchange.responseHeaders
        sessionId = $Exchange.sessionId
        error = $Exchange.error
    }
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

Write-Host ""
Write-Host "MODE: MCP-only (Client spricht nur /app/mcp via JSON-RPC)"
Write-Host "Hinweis: /app/rest/... kann als Tool-Argument vorkommen, bleibt aber serverseitige Tool-Ausfuehrung."
Write-Host ""

function Invoke-Mcp {
    param([string]$Label, [string]$Body)

    $url = "$base/app/mcp"
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $url -Headers $headers -Body $Body -TimeoutSec 25
        $responseBody = [string]$response.Content
        $responseHeaders = [ordered]@{}
        $sessionId = [string]$response.Headers['Mcp-Session-Id']
        if ($response.Headers) {
            foreach ($key in $response.Headers.AllKeys) {
                $responseHeaders[$key] = [string]$response.Headers[$key]
            }
        }
        Write-Host "  OK  [$($response.StatusCode)] $Label"
        return [pscustomobject]@{ url = $url; status = [int]$response.StatusCode; ok = $true; rawRequestBody = $Body; rawResponseBody = $responseBody; error = ""; responseHeaders = $responseHeaders; sessionId = $sessionId }
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
        return [pscustomobject]@{ url = $url; status = $status; ok = $false; rawRequestBody = $Body; rawResponseBody = $responseBody; error = [string]$_.Exception.Message; responseHeaders = @{}; sessionId = "" }
    }
}

$report = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    queryMode   = "mcp"
    baseUrl     = $base
    sections    = [ordered]@{}
}

$report.sections.meta = [ordered]@{
    protocol = "MCP 2024-11-05"
    endpoint = "$base/app/mcp"
    note = "Raw JSON bodies are preserved in rawRequestBody/rawResponseBody. parsedRequest/parsedResponse add a readable view of the MCP payload."
    fieldLegend = @(
        [ordered]@{ field = "rawRequestBody"; meaning = "unveraenderter Request-Body" }
        [ordered]@{ field = "rawResponseBody"; meaning = "unveraenderter Response-Body" }
        [ordered]@{ field = "parsedRequest"; meaning = "lesbare JSON-Auswertung des Requests" }
        [ordered]@{ field = "parsedResponse"; meaning = "lesbare JSON-Auswertung der Response" }
        [ordered]@{ field = "parsedResponseResult"; meaning = "nur der result-Teil der Response, falls vorhanden" }
        [ordered]@{ field = "parsedResponseError"; meaning = "nur der error-Teil der Response, falls vorhanden" }
    )
}

Write-Host ""
Write-Host "=== 1. MCP initialize ==="
$report.sections.initialize = Invoke-Mcp "MCP initialize" (New-RpcPayload "1" "initialize" @{
    protocolVersion = "2024-11-05"
    capabilities    = @{}
    clientInfo      = @{ name = "tc-builds-query-mcp"; version = "1.0" }
})

$mcpSessionId = [string]$report.sections.initialize.sessionId
if (-not [string]::IsNullOrWhiteSpace($mcpSessionId)) {
    $headers['Mcp-Session-Id'] = $mcpSessionId
    Write-Host "MCP Session: $mcpSessionId"
}

Write-Host ""
Write-Host "=== 1b. MCP notifications/initialized ==="
$report.sections.initialized = Invoke-Mcp "MCP notifications/initialized" (New-RpcPayload $null "notifications/initialized" @{})

Write-Host ""
Write-Host "=== 2. MCP tools/list ==="
$report.sections.toolsList = Invoke-Mcp "MCP tools/list" (New-RpcPayload "2" "tools/list" @{})

$availableTools = @('teamcity_build_log', 'teamcity_rest_get', 'teamcity_rest_post')
$toolCatalog = @()
$toolsResponse = ConvertFrom-RpcResponse -Body $report.sections.toolsList.rawResponseBody
if ($toolsResponse -and $toolsResponse.result -and $toolsResponse.result.tools) {
    $toolCatalog = @($toolsResponse.result.tools | ForEach-Object {
        [ordered]@{
            name = [string]$_.name
            description = [string]$_.description
            inputSchema = $_.inputSchema
        }
    })
    $availableTools = @($toolCatalog | ForEach-Object { $_.name })
}

Write-Host "MCP Tools: $([string]::Join(', ', $availableTools))"

$report.sections.toolsCatalog = $toolCatalog
$report.sections.meta.toolCatalog = $toolCatalog

$report.sections.initialize = New-ReadableMcpSection -Exchange $report.sections.initialize
$report.sections.initialized = New-ReadableMcpSection -Exchange $report.sections.initialized
$report.sections.toolsList = New-ReadableMcpSection -Exchange $report.sections.toolsList

function Get-ToolDefinition {
    param([string]$ToolName)

    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        return $null
    }

    return $toolCatalog | Where-Object { $_.name -eq $ToolName } | Select-Object -First 1
}

function Invoke-IfToolExists {
    param(
        [string]$SectionName,
        [string]$ToolName,
        [int]$RequestId,
        [hashtable]$Arguments
    )

    if ($availableTools -notcontains $ToolName) {
        Write-Host "SKIP: Tool '$ToolName' nicht in tools/list gefunden."
        $toolDefinition = Get-ToolDefinition -ToolName $ToolName
        $report.sections[$SectionName] = [ordered]@{
            url = "$base/app/mcp"
            status = $null
            ok = $false
            rpcMethod = "tools/call"
            rpcId = ""
            toolName = $ToolName
            toolDescription = if ($null -ne $toolDefinition) { $toolDefinition.description } else { "" }
            toolInputSchema = if ($null -ne $toolDefinition) { $toolDefinition.inputSchema } else { $null }
            toolSource = "tools/list"
            arguments = $Arguments
            rawRequestBody = ""
            rawResponseBody = ""
            responseHeaders = @{}
            sessionId = $mcpSessionId
            error = "Tool '$ToolName' nicht in tools/list gefunden"
        }
        return
    }

    $callExchange = Invoke-Mcp "MCP tools/call: $ToolName" (New-RpcPayload ([string]$RequestId) "tools/call" @{
        name = $ToolName
        arguments = $Arguments
    })

    $toolDefinition = Get-ToolDefinition -ToolName $ToolName
    $section = New-ReadableMcpSection -Exchange $callExchange -ToolName $ToolName -ToolArguments $Arguments
    $section.toolDescription = if ($null -ne $toolDefinition) { $toolDefinition.description } else { "" }
    $section.toolInputSchema = if ($null -ne $toolDefinition) { $toolDefinition.inputSchema } else { $null }
    $section.toolSource = "tools/list"
    $report.sections[$SectionName] = $section
}

Write-Host ""
Write-Host "=== 3. MCP teamcity_rest_get / projects ==="
Invoke-IfToolExists -SectionName "projects" -ToolName "teamcity_rest_get" -RequestId 3 -Arguments @{ path = "/app/rest/projects" }

Write-Host ""
Write-Host "=== 4. MCP teamcity_rest_get / buildTypes ==="
Invoke-IfToolExists -SectionName "buildTypes" -ToolName "teamcity_rest_get" -RequestId 4 -Arguments @{ path = "/app/rest/buildTypes" }

Write-Host ""
Write-Host "=== 5. MCP teamcity_rest_get / builds ==="
Invoke-IfToolExists -SectionName "builds" -ToolName "teamcity_rest_get" -RequestId 5 -Arguments @{ path = "/app/rest/builds"; query = "locator=start:0,count:10&fields=build(id,number,status,state,startDate,finishDate,buildTypeId)" }

if (-not [string]::IsNullOrWhiteSpace($BuildId)) {
    Write-Host ""
    Write-Host "=== 6. MCP teamcity_build_log ==="
    Invoke-IfToolExists -SectionName "buildLog" -ToolName "teamcity_build_log" -RequestId 6 -Arguments @{ buildId = [string]$BuildId; count = "300" }

    Write-Host ""
    Write-Host "=== 7. MCP teamcity_rest_get / testOccurrences ==="
    Invoke-IfToolExists -SectionName "testResults" -ToolName "teamcity_rest_get" -RequestId 7 -Arguments @{ path = "/app/rest/testOccurrences"; query = "locator=build:(id:$BuildId)&fields=testOccurrence(name,status,duration,details)" }
}
else {
    Write-Host ""
    Write-Host "SKIP: Kein -BuildId gesetzt. get_build_log und get_test_results werden uebersprungen."
}

Write-Host ""
Write-Host "=== 8. MCP resources/list ==="
$report.sections.resources = New-ReadableMcpSection -Exchange (Invoke-Mcp "MCP resources/list" (New-RpcPayload "8" "resources/list" @{}))

Write-Host ""
$report.sections.prompts = [ordered]@{
    url = "$base/app/mcp"
    status = $null
    ok = $false
    rpcMethod = "prompts/list"
    rpcId = ""
    toolName = ""
    arguments = @{}
    rawRequestBody = ""
    rawResponseBody = ""
    responseHeaders = @{}
    sessionId = $mcpSessionId
    error = "Server does not support prompts/list"
}

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