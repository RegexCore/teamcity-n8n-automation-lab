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

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "TEAMCITY_TOKEN fehlt. Trage ihn in .env ein oder setze ihn im Terminal."
}

$headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/json"
}

$projects = Invoke-RestMethod -Method Get -Uri "$base/app/rest/projects" -Headers $headers
$buildTypes = Invoke-RestMethod -Method Get -Uri "$base/app/rest/buildTypes" -Headers $headers
$queued = Invoke-RestMethod -Method Get -Uri "$base/app/rest/buildQueue" -Headers $headers

Write-Host "Projekte gesamt: $($projects.count)"
Write-Host "Build-Konfigurationen gesamt: $($buildTypes.count)"
Write-Host "Build Queue gesamt: $($queued.count)"
Write-Host ""
Write-Host "Projekte (Top 20):"
$projects.project | Select-Object -First 20 | ForEach-Object {
    Write-Host "- $($_.id) | $($_.name)"
}
Write-Host ""
Write-Host "Build-Konfigurationen (Top 30):"
$buildTypes.buildType | Select-Object -First 30 | ForEach-Object {
    Write-Host "- $($_.id) | $($_.name)"
}
