param(
    [string]$BaseUrl = "",
    [string]$Token = $env:TEAMCITY_TOKEN,
    [switch]$McpOnly = $true,
    [switch]$IncludeDirectApiChecks,
    [switch]$SkipRestInventory,
    [switch]$JsonRpcProbes,
    [switch]$RawBodies,
    [switch]$NdjsonTrace,
    [switch]$RawJsonOutput,
    [string]$RawJsonPath = "",
    [string]$NdjsonPath = "",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$base = $BaseUrl.TrimEnd('/')

function Get-TokenFromDotEnv {
    param(
        [string]$EnvFilePath
    )

    if (-not (Test-Path -LiteralPath $EnvFilePath)) {
        return $null
    }

    $lines = Get-Content -LiteralPath $EnvFilePath -ErrorAction Stop
    foreach ($line in $lines) {
        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match '^\s*TEAMCITY_TOKEN\s*=\s*(.*)\s*$') {
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

function New-Headers {
    param(
        [bool]$IncludeContentType
    )

    $headers = @{
        Accept = "application/json"
    }

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers.Authorization = "Bearer $Token"
    }

    if ($IncludeContentType) {
        $headers."Content-Type" = "application/json"
    }

    return $headers
}

function Get-RequestHeadersSnapshot {
    param(
        [hashtable]$Headers
    )

    $snapshot = [ordered]@{}
    foreach ($key in $Headers.Keys) {
        $value = [string]$Headers[$key]
        $snapshot[$key] = $value
    }

    return $snapshot
}

function ConvertTo-ReadableRpcMessage {
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

function Add-RpcReadabilityFields {
    param([pscustomobject]$Entry)

    $requestJson = ConvertTo-ReadableRpcMessage -Body $Entry.rawRequestBody
    $responseJson = ConvertTo-ReadableRpcMessage -Body $Entry.rawResponseBody

    $rpcMethod = if ($requestJson -and $requestJson.PSObject.Properties.Name -contains 'method') { [string]$requestJson.method } else { Get-RegexMatchValue -Text $Entry.rawRequestBody -Pattern '"method"\s*:\s*"([^"]+)"' }
    $rpcId = if ($requestJson -and $requestJson.PSObject.Properties.Name -contains 'id') { [string]$requestJson.id } else { Get-RegexMatchValue -Text $Entry.rawRequestBody -Pattern '"id"\s*:\s*"?([^"\r\n,}]+)"?' }
    $toolName = if ($requestJson -and $requestJson.PSObject.Properties.Name -contains 'params' -and $requestJson.params.PSObject.Properties.Name -contains 'name') { [string]$requestJson.params.name } else { Get-RegexMatchValue -Text $Entry.rawRequestBody -Pattern '"name"\s*:\s*"([^"]+)"' }

    $Entry | Add-Member -NotePropertyName rpcMethod -NotePropertyValue $rpcMethod -Force
    $Entry | Add-Member -NotePropertyName rpcId -NotePropertyValue $rpcId -Force
    $Entry | Add-Member -NotePropertyName toolName -NotePropertyValue $toolName -Force
    $Entry | Add-Member -NotePropertyName arguments -NotePropertyValue $(if ($requestJson -and $requestJson.PSObject.Properties.Name -contains 'params' -and $requestJson.params.PSObject.Properties.Name -contains 'arguments') { $requestJson.params.arguments } else { $null }) -Force
    $Entry | Add-Member -NotePropertyName rawRequestBody -NotePropertyValue $Entry.rawRequestBody -Force
    $Entry | Add-Member -NotePropertyName rawResponseBody -NotePropertyValue $Entry.rawResponseBody -Force
    $Entry | Add-Member -NotePropertyName parsedRequest -NotePropertyValue $(if ($requestJson) { $requestJson } else { [pscustomobject]@{ method = $rpcMethod; id = $rpcId; toolName = $toolName; arguments = $Entry.arguments } }) -Force
    $Entry | Add-Member -NotePropertyName parsedResponse -NotePropertyValue $(if ($responseJson) { $responseJson } else { [pscustomobject]@{ hasResult = [bool]($Entry.rawResponseBody -match '"result"\s*:'); hasError = [bool]($Entry.rawResponseBody -match '"error"\s*:'); raw = $Entry.rawResponseBody } }) -Force
    $Entry | Add-Member -NotePropertyName parsedResponseResult -NotePropertyValue $(if ($responseJson -and $responseJson.PSObject.Properties.Name -contains 'result') { $responseJson.result } else { $(if ($Entry.rawResponseBody -match '"result"\s*:') { [pscustomobject]@{ raw = $Entry.rawResponseBody } } else { $null }) }) -Force
    $Entry | Add-Member -NotePropertyName parsedResponseError -NotePropertyValue $(if ($responseJson -and $responseJson.PSObject.Properties.Name -contains 'error') { $responseJson.error } else { $(if ($Entry.rawResponseBody -match '"error"\s*:') { [pscustomobject]@{ raw = $Entry.rawResponseBody } } else { $null }) }) -Force

    if ($rpcMethod -eq 'tools/list' -and $responseJson -and $responseJson.PSObject.Properties.Name -contains 'result' -and $responseJson.result.PSObject.Properties.Name -contains 'tools') {
        $Entry | Add-Member -NotePropertyName discoveredTools -NotePropertyValue @(
            $responseJson.result.tools | ForEach-Object {
                [ordered]@{
                    name = [string]$_.name
                    description = [string]$_.description
                    inputSchema = $_.inputSchema
                }
            }
        ) -Force
    }

    return $Entry
}

function Invoke-Endpoint {
    param(
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers,
        [string]$Body
    )

    $safeHeaders = Get-RequestHeadersSnapshot -Headers $Headers
    $requestBody = if ([string]::IsNullOrWhiteSpace($Body)) { "" } else { $Body }

    try {
        if ([string]::IsNullOrWhiteSpace($Body)) {
            $response = Invoke-WebRequest -UseBasicParsing -Method $Method -Uri $Url -Headers $Headers -TimeoutSec 25
        }
        else {
            $response = Invoke-WebRequest -UseBasicParsing -Method $Method -Uri $Url -Headers $Headers -Body $Body -TimeoutSec 25
        }

        $respHeaders = [ordered]@{}
        if ($response.Headers) {
            foreach ($key in $response.Headers.AllKeys) {
                $respHeaders[$key] = [string]$response.Headers[$key]
            }
        }

        return [pscustomobject]@{
            timestamp = (Get-Date).ToString("o")
            method = $Method
            url = $Url
            requestHeaders = $safeHeaders
            rawRequestBody = $requestBody
            status = [int]$response.StatusCode
            statusText = [string]$response.StatusDescription
            contentType = [string]$response.Headers["Content-Type"]
            allow = [string]$response.Headers["Allow"]
            responseHeaders = $respHeaders
            sessionId = [string]$response.Headers['Mcp-Session-Id']
            bodyLength = if ($response.Content) { [int]$response.Content.Length } else { 0 }
            bodySnippet = if ($response.Content) { [string]$response.Content } else { "" }
            rawResponseBody = if ($response.Content) { [string]$response.Content } else { "" }
            bodyRaw = if ($RawBodies -and $response.Content) { [string]$response.Content } else { "" }
            rpcMethod = ""
            rpcId = ""
            toolName = ""
            arguments = $null
            parsedRequest = $null
            parsedResponse = $null
            parsedResponseResult = $null
            parsedResponseError = $null
            ok = $true
            error = ""
        }
    }
    catch {
        $status = $null
        $statusText = ""
        $contentType = ""
        $allow = ""
        $bodySnippet = ""
        $respHeaders = [ordered]@{}

        if ($_.Exception.Response) {
            $resp = $_.Exception.Response
            if ($resp.StatusCode) {
                $status = [int]$resp.StatusCode
                $statusText = [string]$resp.StatusDescription
            }

            try {
                if ($resp.Headers) {
                    $contentType = [string]$resp.Headers["Content-Type"]
                    $allow = [string]$resp.Headers["Allow"]

                    foreach ($key in $resp.Headers.AllKeys) {
                        $respHeaders[$key] = [string]$resp.Headers[$key]
                    }
                }
            }
            catch {
            }

            try {
                $stream = $resp.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $raw = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $bodySnippet = $raw
                    }
                }
            }
            catch {
            }
        }

        return [pscustomobject]@{
            timestamp = (Get-Date).ToString("o")
            method = $Method
            url = $Url
            requestHeaders = $safeHeaders
            rawRequestBody = $requestBody
            status = $status
            statusText = $statusText
            contentType = $contentType
            allow = $allow
            responseHeaders = $respHeaders
            sessionId = [string]$resp.Headers['Mcp-Session-Id']
            bodyLength = if ($bodySnippet) { [int]$bodySnippet.Length } else { 0 }
            bodySnippet = $bodySnippet
            rawResponseBody = $bodySnippet
            bodyRaw = if ($RawBodies) { $bodySnippet } else { "" }
            rpcMethod = ""
            rpcId = ""
            toolName = ""
            arguments = $null
            parsedRequest = $null
            parsedResponse = $null
            parsedResponseResult = $null
            parsedResponseError = $null
            ok = $false
            error = [string]$_.Exception.Message
        }
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$envFilePath = Join-Path $repoRoot ".env"
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = Get-TokenFromDotEnv -EnvFilePath $envFilePath
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_BASE_URL"
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = "http://localhost:8111"
}

$defaultReportDir = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_REPORT_DIR"
$defaultReportDir = Resolve-ReportDirectory -ReportDir $defaultReportDir -RepoRoot $repoRoot

$base = $BaseUrl.TrimEnd('/')

# Default behavior: when no explicit output mode is selected,
# always produce full raw server/client exchange JSON.
if (-not $RawJsonOutput -and -not $NdjsonTrace -and -not $RawBodies) {
    $RawJsonOutput = $true
    $RawBodies = $true
}

if ($IncludeDirectApiChecks) {
    $McpOnly = $false
}

if ($McpOnly) {
    # Strict MCP mode: skip direct REST inventory and ensure JSON-RPC MCP probes run.
    $SkipRestInventory = $true
    $JsonRpcProbes = $true
}

Write-Host ""
if ($McpOnly) {
    Write-Host "MODE: MCP-only (nur JSON-RPC ueber /app/mcp)"
}
else {
    Write-Host "MODE: Mixed (Direct API Checks + MCP JSON-RPC)"
}
Write-Host ""

$results = [ordered]@{}
$results.generatedAt = (Get-Date).ToString("s")
$results.baseUrl = $base
$results.tokenDetected = -not [string]::IsNullOrWhiteSpace($Token)
$results.rawBodiesEnabled = [bool]$RawBodies
$results.ndjsonTraceEnabled = [bool]$NdjsonTrace
$results.rawJsonOutputEnabled = [bool]$RawJsonOutput
$results.mcpOnlyMode = [bool]$McpOnly
$results.fieldLegend = @(
    [ordered]@{ field = "rawRequestBody"; meaning = "unveraenderter Request-Body" }
    [ordered]@{ field = "rawResponseBody"; meaning = "unveraenderter Response-Body" }
    [ordered]@{ field = "parsedRequest"; meaning = "lesbare JSON-Auswertung des Requests" }
    [ordered]@{ field = "parsedResponse"; meaning = "lesbare JSON-Auswertung der Response" }
    [ordered]@{ field = "parsedResponseResult"; meaning = "nur der result-Teil der Response, falls vorhanden" }
    [ordered]@{ field = "parsedResponseError"; meaning = "nur der error-Teil der Response, falls vorhanden" }
)
$results.restInventory = @()
$results.restSummary = @{}
$results.mcpEndpointChecks = @()
$results.jsonRpcProbes = @()

if (-not $SkipRestInventory) {
    Write-Host "== REST Inventar =="
    $restUrls = @(
        "$base/app/rest/projects",
        "$base/app/rest/buildTypes",
        "$base/app/rest/buildQueue",
        "$base/app/rest/server/plugins"
    )

    foreach ($url in $restUrls) {
        $res = Invoke-Endpoint -Method "GET" -Url $url -Headers (New-Headers -IncludeContentType:$false) -Body ""
        $results.restInventory += $res
        $statusOut = if ($null -ne $res.status) { "$($res.status) $($res.statusText)" } else { "NO_STATUS" }
        Write-Host "GET $url -> $statusOut"
    }

    try {
        $jsonHeaders = New-Headers -IncludeContentType:$false
        $projectsData = Invoke-RestMethod -Method Get -Uri "$base/app/rest/projects" -Headers $jsonHeaders
        $buildTypesData = Invoke-RestMethod -Method Get -Uri "$base/app/rest/buildTypes" -Headers $jsonHeaders
        $queueData = Invoke-RestMethod -Method Get -Uri "$base/app/rest/buildQueue" -Headers $jsonHeaders

        $projectIds = @()
        if ($projectsData.project) {
            $projectIds = @($projectsData.project | ForEach-Object { $_.id })
        }

        $buildTypeIds = @()
        if ($buildTypesData.buildType) {
            $buildTypeIds = @($buildTypesData.buildType | ForEach-Object { $_.id })
        }

        $queueIds = @()
        if ($queueData.build) {
            $queueIds = @($queueData.build | ForEach-Object { $_.id })
        }

        $results.restSummary = [ordered]@{
            projectCount = [int]$projectsData.count
            projectIds = $projectIds
            buildTypeCount = [int]$buildTypesData.count
            buildTypeIds = $buildTypeIds
            queueCount = [int]$queueData.count
            queueBuildIds = $queueIds
        }

        Write-Host ""
        Write-Host "REST Summary:"
        Write-Host "- Projekte: $($results.restSummary.projectCount)"
        Write-Host "- Projekt-IDs: $(([string[]]$results.restSummary.projectIds) -join ', ')"
        Write-Host "- BuildTypes: $($results.restSummary.buildTypeCount)"
        Write-Host "- BuildType-IDs: $(([string[]]$results.restSummary.buildTypeIds) -join ', ')"
        Write-Host "- Queue Builds: $($results.restSummary.queueCount)"
    }
    catch {
        Write-Host "REST Summary konnte nicht vollstaendig aufgebaut werden."
    }

    Write-Host ""
}

Write-Host "== MCP Endpoint Checks =="
if ($McpOnly) {
    Write-Host "SKIP (McpOnly): Direkte Endpoint-Checks deaktiviert."
}
else {
    $mcpCandidates = @(
        "/app/mcp",
        "/app/mcp/sse",
        "/mcp"
    )

    foreach ($path in $mcpCandidates) {
        $url = "$base$path"

        $getRes = Invoke-Endpoint -Method "GET" -Url $url -Headers (New-Headers -IncludeContentType:$false) -Body ""
        $results.mcpEndpointChecks += $getRes
        $getStatus = if ($null -ne $getRes.status) { "$($getRes.status) $($getRes.statusText)" } else { "NO_STATUS" }
        Write-Host "GET $url -> $getStatus"

        $optionsRes = Invoke-Endpoint -Method "OPTIONS" -Url $url -Headers (New-Headers -IncludeContentType:$false) -Body ""
        $results.mcpEndpointChecks += $optionsRes
        $optStatus = if ($null -ne $optionsRes.status) { "$($optionsRes.status) $($optionsRes.statusText)" } else { "NO_STATUS" }
        $allowText = if (-not [string]::IsNullOrWhiteSpace($optionsRes.allow)) { " | Allow: $($optionsRes.allow)" } else { "" }
        Write-Host "OPTIONS $url -> $optStatus$allowText"
    }
}

Write-Host ""
if ($JsonRpcProbes) {
    Write-Host "== JSON-RPC Probes (MCP) =="
    $rpcUrl = "$base/app/mcp"

    $initializePayload = @{
        jsonrpc = "2.0"
        id = "init-1"
        method = "initialize"
        params = @{
            protocolVersion = "2024-11-05"
            capabilities = @{}
            clientInfo = @{
                name = "teamcity-mcp-advanced-test"
                version = "1.0"
            }
        }
    } | ConvertTo-Json -Depth 10

    $initRes = Invoke-Endpoint -Method "POST" -Url $rpcUrl -Headers (New-Headers -IncludeContentType:$true) -Body $initializePayload
    $initRes = Add-RpcReadabilityFields -Entry $initRes
    $results.jsonRpcProbes += $initRes
    $initStatus = if ($null -ne $initRes.status) { "$($initRes.status) $($initRes.statusText)" } else { "NO_STATUS" }
    Write-Host "POST $rpcUrl (initialize) -> $initStatus"

    $mcpSessionId = [string]$initRes.sessionId
    if (-not [string]::IsNullOrWhiteSpace($mcpSessionId)) {
        Write-Host "MCP Session: $mcpSessionId"
    }

    $mcpHeaders = New-Headers -IncludeContentType:$true
    if (-not [string]::IsNullOrWhiteSpace($mcpSessionId)) {
        $mcpHeaders['Mcp-Session-Id'] = $mcpSessionId
    }

    $initializedPayload = @{
        jsonrpc = "2.0"
        method = "notifications/initialized"
        params = @{}
    } | ConvertTo-Json -Depth 10

    $initializedRes = Invoke-Endpoint -Method "POST" -Url $rpcUrl -Headers $mcpHeaders -Body $initializedPayload
    $initializedRes = Add-RpcReadabilityFields -Entry $initializedRes
    $results.jsonRpcProbes += $initializedRes
    $initializedStatus = if ($null -ne $initializedRes.status) { "$($initializedRes.status) $($initializedRes.statusText)" } else { "NO_STATUS" }
    Write-Host "POST $rpcUrl (notifications/initialized) -> $initializedStatus"

    $toolsPayload = @{
        jsonrpc = "2.0"
        id = "tools-1"
        method = "tools/list"
        params = @{}
    } | ConvertTo-Json -Depth 10

    $toolsRes = Invoke-Endpoint -Method "POST" -Url $rpcUrl -Headers $mcpHeaders -Body $toolsPayload
    $toolsRes = Add-RpcReadabilityFields -Entry $toolsRes
    $results.jsonRpcProbes += $toolsRes
    $toolsStatus = if ($null -ne $toolsRes.status) { "$($toolsRes.status) $($toolsRes.statusText)" } else { "NO_STATUS" }
    Write-Host "POST $rpcUrl (tools/list) -> $toolsStatus"

    Write-Host ""
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path $defaultReportDir "teamcity-rest-api-and-mcp-json-rpc-report-$stamp.json"
}

Ensure-ParentDirectory -FilePath $ReportPath
$results | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host "Report gespeichert: $ReportPath"

if ($RawJsonOutput) {
    if ([string]::IsNullOrWhiteSpace($RawJsonPath)) {
        $stampRawJson = Get-Date -Format "yyyyMMdd-HHmmss"
        $RawJsonPath = Join-Path $defaultReportDir "teamcity-rest-api-and-mcp-json-rpc-raw-$stampRawJson.json"
    }

    $rawExchanges = @()

    foreach ($entry in $results.restInventory) {
        $rawExchanges += [pscustomobject]@{
            category = "restInventory"
            request = [pscustomobject]@{
                timestamp = $entry.timestamp
                method = $entry.method
                url = $entry.url
                headers = $entry.requestHeaders
                body = $entry.rawRequestBody
            }
            response = [pscustomobject]@{
                status = $entry.status
                statusText = $entry.statusText
                headers = $entry.responseHeaders
                body = $entry.rawResponseBody
            }
        }
    }

    foreach ($entry in $results.mcpEndpointChecks) {
        $rawExchanges += [pscustomobject]@{
            category = "mcpEndpointChecks"
            request = [pscustomobject]@{
                timestamp = $entry.timestamp
                method = $entry.method
                url = $entry.url
                headers = $entry.requestHeaders
                body = $entry.rawRequestBody
            }
            response = [pscustomobject]@{
                status = $entry.status
                statusText = $entry.statusText
                headers = $entry.responseHeaders
                body = $entry.rawResponseBody
            }
        }
    }

    foreach ($entry in $results.jsonRpcProbes) {
        $rawExchanges += [pscustomobject]@{
            category = "jsonRpcProbes"
            rpcMethod = $entry.rpcMethod
            rpcId = $entry.rpcId
            toolName = $entry.toolName
            arguments = $entry.arguments
            request = [pscustomobject]@{
                timestamp = $entry.timestamp
                method = $entry.method
                url = $entry.url
                headers = $entry.requestHeaders
                body = $entry.rawRequestBody
            }
            response = [pscustomobject]@{
                status = $entry.status
                statusText = $entry.statusText
                headers = $entry.responseHeaders
                body = $entry.rawResponseBody
            }
            parsedRequest = $entry.parsedRequest
            parsedResponse = $entry.parsedResponse
            parsedResponseResult = $entry.parsedResponseResult
            parsedResponseError = $entry.parsedResponseError
            discoveredTools = $(if ($entry.PSObject.Properties.Name -contains 'discoveredTools') { $entry.discoveredTools } else { $null })
        }
    }

    $rawPayload = [ordered]@{
        generatedAt = $results.generatedAt
        baseUrl = $results.baseUrl
        tokenDetected = $results.tokenDetected
        fieldLegend = $results.fieldLegend
        exchanges = $rawExchanges
    }

    Ensure-ParentDirectory -FilePath $RawJsonPath
    $rawPayload | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $RawJsonPath -Encoding UTF8
    Write-Host "Raw JSON gespeichert: $RawJsonPath"
}

if ($NdjsonTrace) {
    if ([string]::IsNullOrWhiteSpace($NdjsonPath)) {
        $stampForNdjson = Get-Date -Format "yyyyMMdd-HHmmss"
        $NdjsonPath = Join-Path $defaultReportDir "teamcity-rest-api-and-mcp-json-rpc-trace-$stampForNdjson.ndjson"
    }

    $traceEntries = @()

    foreach ($entry in $results.restInventory) {
        $traceEntries += [pscustomobject]@{
            category = "restInventory"
            record = $entry
        }
    }

    foreach ($entry in $results.mcpEndpointChecks) {
        $traceEntries += [pscustomobject]@{
            category = "mcpEndpointChecks"
            record = $entry
        }
    }

    foreach ($entry in $results.jsonRpcProbes) {
        $traceEntries += [pscustomobject]@{
            category = "jsonRpcProbes"
            record = $entry
        }
    }

    $meta = [pscustomobject]@{
        category = "meta"
        record = [pscustomobject]@{
            generatedAt = $results.generatedAt
            baseUrl = $results.baseUrl
            tokenDetected = $results.tokenDetected
            rawBodiesEnabled = $results.rawBodiesEnabled
            ndjsonTraceEnabled = $results.ndjsonTraceEnabled
            fieldLegend = $results.fieldLegend
        }
    }

    $summary = [pscustomobject]@{
        category = "restSummary"
        record = $results.restSummary
    }

    $allNdjsonEntries = @($meta) + $traceEntries + @($summary)
    $ndjsonLines = $allNdjsonEntries | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }
    Ensure-ParentDirectory -FilePath $NdjsonPath
    $ndjsonLines | Set-Content -LiteralPath $NdjsonPath -Encoding UTF8
    Write-Host "NDJSON Trace gespeichert: $NdjsonPath"
}

$reachable = $false
foreach ($r in $results.mcpEndpointChecks) {
    if ($null -ne $r.status -and $r.status -ne 404) {
        $reachable = $true
        break
    }
}

$rpcReachable = $false
foreach ($r in $results.jsonRpcProbes) {
    if ($null -ne $r.status -and $r.status -ge 200 -and $r.status -lt 300) {
        $rpcReachable = $true
        break
    }
}

Write-Host ""
if ($McpOnly -and $rpcReachable) {
    Write-Host "MCP Probe (McpOnly): JSON-RPC Kommunikation erfolgreich erreichbar."
    exit 0
}

if ((-not $McpOnly) -and $reachable) {
    Write-Host "MCP Probe: mindestens ein Endpunkt antwortet nicht mit 404."
    exit 0
}

if ($McpOnly) {
    Write-Host "MCP Probe (McpOnly): keine erfolgreiche JSON-RPC Kommunikation festgestellt."
    exit 1
}

Write-Host "MCP Probe: alle geprueften Endpunkte liefern 404."
exit 1
