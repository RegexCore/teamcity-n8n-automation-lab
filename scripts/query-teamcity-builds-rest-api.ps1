param(
    [string]$BaseUrl = "",
    [string]$Token = $env:TEAMCITY_TOKEN,
    [string]$BuildTypeId = "",
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

$repoRoot = Split-Path -Parent $PSScriptRoot
$envFilePath = Join-Path $repoRoot ".env"

if ([string]::IsNullOrWhiteSpace($Token))   { $Token   = Get-EnvValueFromDotEnv $envFilePath "TEAMCITY_TOKEN" }
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl  = Get-EnvValueFromDotEnv $envFilePath "TEAMCITY_BASE_URL" }
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl  = "http://localhost:8111" }

$base = $BaseUrl.TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "TEAMCITY_TOKEN fehlt. Trage ihn in .env ein oder setze: `$env:TEAMCITY_TOKEN = '<token>'"
}

$headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }

$report = [ordered]@{
    generatedAt       = (Get-Date).ToString("o")
    baseUrl           = $base
    sections          = [ordered]@{}
}

function Invoke-TC {
    param([string]$Path, [string]$Label)
    $url = "$base$Path"
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $url -Headers $headers -TimeoutSec 25
        $body = [string]$r.Content
        Write-Host "  OK  [$($r.StatusCode)] $Label"
        return [pscustomobject]@{ url=$url; status=[int]$r.StatusCode; ok=$true; body=$body; error="" }
    }
    catch {
        $status = $null
        $body   = ""
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $s = $_.Exception.Response.GetResponseStream()
                if ($s) { $body = (New-Object System.IO.StreamReader($s)).ReadToEnd() }
            } catch {}
        }
        Write-Host "  ERR [$status] $Label -> $($_.Exception.Message)"
        return [pscustomobject]@{ url=$url; status=$status; ok=$false; body=$body; error=[string]$_.Exception.Message }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Projekte auflisten
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 1. Projekte ==="
$report.sections.projects = Invoke-TC "/app/rest/projects" "Alle Projekte"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Build-Konfigurationen auflisten
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 2. Build-Konfigurationen ==="
$report.sections.buildTypes = Invoke-TC "/app/rest/buildTypes" "Alle Build-Konfigurationen"

# Ermittle alle BuildType-IDs fuer spaetere Abfragen
$allBuildTypeIds = @()
try {
    $btData = $report.sections.buildTypes.body | ConvertFrom-Json
    if ($btData.buildType) {
        $allBuildTypeIds = @($btData.buildType | ForEach-Object { $_.id })
    }
} catch {}

if (-not [string]::IsNullOrWhiteSpace($BuildTypeId)) {
    $allBuildTypeIds = @($BuildTypeId)
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Letzte Builds je Build-Konfiguration (max. 3)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 3. Letzte Builds je Build-Konfiguration ==="
$report.sections.recentBuildsPerType = [ordered]@{}

foreach ($btId in $allBuildTypeIds) {
    $res = Invoke-TC "/app/rest/builds?locator=buildType:$btId,count:3&fields=build(id,number,status,state,startDate,finishDate,buildTypeId)" "Builds fuer $btId"
    $report.sections.recentBuildsPerType[$btId] = $res
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Build-Queue (ausstehende Builds)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 4. Build-Queue ==="
$report.sections.buildQueue = Invoke-TC "/app/rest/buildQueue" "Build-Queue"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Laufende Builds
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 5. Laufende Builds ==="
$report.sections.runningBuilds = Invoke-TC "/app/rest/builds?locator=running:true" "Laufende Builds"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Fehlgeschlagene Builds (letzte 10)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 6. Fehlgeschlagene Builds (letzte 10) ==="
$report.sections.failedBuilds = Invoke-TC "/app/rest/builds?locator=status:FAILURE,count:10&fields=build(id,number,status,buildTypeId,startDate)" "Fehlgeschlagene Builds"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Build-Logs eines konkreten Builds
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 7. Build-Log ==="

# Letzten abgeschlossenen Build automatisch ermitteln falls kein -BuildId gesetzt
$resolvedBuildId = $BuildId
if ([string]::IsNullOrWhiteSpace($resolvedBuildId)) {
    try {
        $latestBuilds = Invoke-RestMethod -Method GET -Uri "$base/app/rest/builds?locator=count:1,state:finished" -Headers $headers
        if ($latestBuilds.build) {
            $resolvedBuildId = [string]($latestBuilds.build | Select-Object -First 1 -ExpandProperty id)
            Write-Host "  (auto-detected buildId: $resolvedBuildId)"
        }
    } catch {}
}

if (-not [string]::IsNullOrWhiteSpace($resolvedBuildId)) {
    # Build-Detail
    $report.sections.buildDetail = Invoke-TC "/app/rest/builds/id:$resolvedBuildId" "Build-Detail fuer Build $resolvedBuildId"

    # Build-Log (plain text)
    $logUrl = "$base/downloadBuildLog.html?buildId=$resolvedBuildId"
    $logHeaders = @{ Authorization = "Bearer $Token"; Accept = "text/plain" }
    try {
        $logRes = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $logUrl -Headers $logHeaders -TimeoutSec 30
        $logText = [string]$logRes.Content
        Write-Host "  OK  [$($logRes.StatusCode)] Build-Log ($($logText.Length) Zeichen)"
        $report.sections.buildLog = [pscustomobject]@{
            url    = $logUrl
            status = [int]$logRes.StatusCode
            ok     = $true
            body   = if ($logText.Length -gt 8000) { $logText.Substring(0, 8000) + "`n... (gekuerzt)" } else { $logText }
            error  = ""
        }
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        Write-Host "  ERR [$status] Build-Log -> $($_.Exception.Message)"
        $report.sections.buildLog = [pscustomobject]@{ url=$logUrl; status=$status; ok=$false; body=""; error=[string]$_.Exception.Message }
    }

    # Build-Log via REST (strukturiert, letzten 100 Eintraege)
    $report.sections.buildLogRest = Invoke-TC "/app/rest/builds/id:$resolvedBuildId/resulting-properties" "Build Resulting Properties fuer $resolvedBuildId"

    # Test-Ergebnisse
    Write-Host ""
    Write-Host "=== 8. Test-Ergebnisse ==="
    $report.sections.testOccurrences = Invoke-TC "/app/rest/testOccurrences?locator=build:(id:$resolvedBuildId)&fields=testOccurrence(name,status,duration,details)" "Test-Ergebnisse fuer Build $resolvedBuildId"

    # Artefakte
    Write-Host ""
    Write-Host "=== 9. Artefakte ==="
    $report.sections.artifacts = Invoke-TC "/app/rest/builds/id:$resolvedBuildId/artifacts/children/" "Artefakt-Liste fuer Build $resolvedBuildId"

    # Build-Statistiken
    Write-Host ""
    Write-Host "=== 10. Build-Statistiken ==="
    $report.sections.buildStatistics = Invoke-TC "/app/rest/builds/id:$resolvedBuildId/statistics/" "Statistiken fuer Build $resolvedBuildId"
}
else {
    Write-Host "  SKIP: Kein abgeschlossener Build gefunden. Sections 7-10 werden uebersprungen."
    Write-Host "         Tipp: -BuildId <id> uebergeben oder erst Builds ausfuehren."
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. Test-Occurrences projektuebergreifend (letzte 20 Fehlschlaege)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 11. Test-Fehlschlaege projektuebergreifend (letzte 20) ==="
$report.sections.failedTests = Invoke-TC "/app/rest/testOccurrences?locator=status:FAILURE,count:20&fields=testOccurrence(name,status,buildTypeId,build(id,number))" "Fehlgeschlagene Tests"

# ─────────────────────────────────────────────────────────────────────────────
# 12. Agents
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== 12. Agents ==="
$report.sections.agents         = Invoke-TC "/app/rest/agents?locator=authorized:true" "Autorisierte Agents"
$report.sections.agentsUnauth   = Invoke-TC "/app/rest/agents?locator=authorized:false" "Nicht autorisierte Agents"
$report.sections.agentsRunning  = Invoke-TC "/app/rest/agents?locator=enabled:true,connected:true" "Verbundene und aktivierte Agents"

# ─────────────────────────────────────────────────────────────────────────────
# 13. Build triggern (nur dokumentiert, nicht ausgefuehrt)
# ─────────────────────────────────────────────────────────────────────────────
# POST /app/rest/buildQueue  Body: {"buildType":{"id":"demo_beta_unit"}}
# -> startet einen Build sofort in die Queue
$report.sections.triggerBuildExample = [pscustomobject]@{
    description = "Beispiel: Build per REST triggern (nicht ausgefuehrt)"
    method      = "POST"
    url         = "$base/app/rest/buildQueue"
    body        = '{"buildType":{"id":"demo_beta_unit"}}'
    note        = "Diesen Request absenden um demo_beta_unit sofort zu starten"
}

# ─────────────────────────────────────────────────────────────────────────────
# Report speichern
# ─────────────────────────────────────────────────────────────────────────────
$defaultReportDir = Get-EnvValueFromDotEnv $envFilePath "TEAMCITY_REPORT_DIR"
$defaultReportDir = Resolve-ReportDirectory $defaultReportDir $repoRoot

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path $defaultReportDir "tc-builds-query-rest-api-$stamp.json"
}

Ensure-ParentDirectory $ReportPath
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host ""
Write-Host "Report gespeichert: $ReportPath"
