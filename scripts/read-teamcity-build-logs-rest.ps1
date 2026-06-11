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
    param([string]$Body, [int]$Depth = 30)

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

function Invoke-TcJson {
    param([string]$Path, [string]$Label)

    $url = "$script:base$Path"
    try {
        $res = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $url -Headers $script:headers -TimeoutSec 30
        $body = [string]$res.Content
        $parsed = ConvertFrom-JsonCompat -Body $body -Depth 40
        Write-Host "  OK  [$($res.StatusCode)] $Label"
        return [pscustomobject]@{
            ok = $true
            status = [int]$res.StatusCode
            url = $url
            body = $body
            parsed = $parsed
            error = ""
        }
    }
    catch {
        $status = $null
        $body = ""
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
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
            body = $body
            parsed = $null
            error = [string]$_.Exception.Message
        }
    }
}

function Invoke-BuildLogText {
    param([string]$BuildIdValue)

    $url = "$script:base/downloadBuildLog.html?buildId=$BuildIdValue"
    $logHeaders = @{ Authorization = "Bearer $script:Token"; Accept = "text/plain" }

    try {
        $res = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $url -Headers $logHeaders -TimeoutSec 60
        return [pscustomobject]@{
            ok = $true
            status = [int]$res.StatusCode
            url = $url
            text = [string]$res.Content
            error = ""
        }
    }
    catch {
        $status = $null
        $body = ""
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                }
            }
            catch {
            }
        }

        return [pscustomobject]@{
            ok = $false
            status = $status
            url = $url
            text = $body
            error = [string]$_.Exception.Message
        }
    }
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

function Get-BuildSelection {
    param(
        [string[]]$Ids,
        [string]$BuildType,
        [switch]$FetchAll,
        [int]$Limit
    )

    $builds = @()

    if ($Ids.Count -gt 0) {
        foreach ($id in ($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            $detail = Invoke-TcJson -Path "/app/rest/builds/id:$id?fields=id,number,status,state,buildTypeId,branchName,webUrl,startDate,finishDate" -Label "Build details $id"
            if ($detail.ok -and $detail.parsed) {
                $builds += $detail.parsed
            }
        }
        return $builds
    }

    $locatorParts = @()
    $locatorParts += "state:finished"

    if (-not [string]::IsNullOrWhiteSpace($BuildType)) {
        $locatorParts += "buildType:(id:$BuildType)"
    }

    if ($FetchAll) {
        $locatorParts += "count:$Limit"
    }
    else {
        $locatorParts += "count:1"
    }

    $locator = [string]::Join(",", $locatorParts)
    $queryPath = "/app/rest/builds?locator=$locator&fields=build(id,number,status,state,buildTypeId,branchName,webUrl,startDate,finishDate)"
    $res = Invoke-TcJson -Path $queryPath -Label "Build selection"

    if ($res.ok -and $res.parsed -and $res.parsed.build) {
        return @($res.parsed.build)
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

$script:Token = $Token
$script:base = $BaseUrl.TrimEnd('/')
$script:headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }

Write-Host ""
Write-Host "== TeamCity Build Logs (REST) =="
Write-Host "Base URL: $script:base"
Write-Host "Log filter: $LogFilter"
Write-Host ""

$selectedBuilds = Get-BuildSelection -Ids $BuildId -BuildType $BuildTypeId -FetchAll:$AllBuilds -Limit $MaxBuilds
if ($selectedBuilds.Count -eq 0) {
    throw "Keine Builds gefunden. Nutze -BuildId <id> oder -AllBuilds (optional mit -BuildTypeId)."
}

$report = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    mode = "build-logs-rest"
    baseUrl = $script:base
    parameters = [ordered]@{
        buildId = $BuildId
        buildTypeId = $BuildTypeId
        allBuilds = [bool]$AllBuilds
        maxBuilds = $MaxBuilds
        logFilter = $LogFilter
        maxLogLines = $MaxLogLines
    }
    summary = [ordered]@{
        selectedBuilds = $selectedBuilds.Count
        successfulLogs = 0
        failedLogs = 0
    }
    builds = @()
}

foreach ($build in $selectedBuilds) {
    $buildIdValue = [string]$build.id
    Write-Host "Lese Build-Log fuer BuildId: $buildIdValue"

    $logRes = Invoke-BuildLogText -BuildIdValue $buildIdValue
    if (-not $logRes.ok) {
        Write-Host "  ERR [$($logRes.status)] Build-Log $buildIdValue -> $($logRes.error)"
        $report.summary.failedLogs++
        $report.builds += [ordered]@{
            build = $build
            log = [ordered]@{
                ok = $false
                status = $logRes.status
                url = $logRes.url
                error = $logRes.error
                lineCount = 0
                previewLines = @()
            }
        }
        continue
    }

    $previewLines = Get-FilteredLogLines -RawText $logRes.text -Filter $LogFilter -LineLimit $MaxLogLines -LineLength $MaxLineLength
    Write-BuildBlock -Build $build -Lines $previewLines

    $report.summary.successfulLogs++
    $report.builds += [ordered]@{
        build = $build
        log = [ordered]@{
            ok = $true
            status = $logRes.status
            url = $logRes.url
            error = ""
            lineCount = $previewLines.Count
            previewLines = $previewLines
        }
    }
}

$defaultReportDir = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_REPORT_DIR"
$defaultReportDir = Resolve-ReportDirectory -ReportDir $defaultReportDir -RepoRoot $repoRoot

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path $defaultReportDir "tc-build-logs-rest-$stamp.json"
}

Ensure-ParentDirectory -FilePath $ReportPath
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "Fertig. Report gespeichert: $ReportPath"
