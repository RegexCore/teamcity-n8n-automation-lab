param(
    [string]$BaseUrl = "",
    [string]$ProjectId = "",
    [string]$ProjectName = "",
    [string]$Token = $env:TEAMCITY_TOKEN,
    [switch]$SingleProject,
    [switch]$CreateTestData,
    [switch]$QueueBuilds
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

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    $ProjectId = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_DEFAULT_PROJECT_ID"
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    $ProjectId = "demo_project"
}

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    $ProjectName = Get-EnvValueFromDotEnv -EnvFilePath $envFilePath -Key "TEAMCITY_DEFAULT_PROJECT_NAME"
}

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    $ProjectName = "Demo Project"
}

$runSeedMode = $CreateTestData -or (-not $PSBoundParameters.ContainsKey('SingleProject') -and -not $PSBoundParameters.ContainsKey('CreateTestData'))

if ($SingleProject -and $CreateTestData) {
    throw "Bitte entweder -SingleProject oder -CreateTestData verwenden, nicht beides gleichzeitig."
}

if ($runSeedMode -and -not $PSBoundParameters.ContainsKey('QueueBuilds')) {
    $QueueBuilds = $true
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "TEAMCITY_TOKEN fehlt. Trage ihn in .env ein oder setze ihn im Terminal: `$env:TEAMCITY_TOKEN = '<dein-token>'"
}

$base = $BaseUrl.TrimEnd('/')

function Invoke-TeamCityApi {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body
    )

    $url = "$base$Path"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/json"
        "Content-Type" = "application/json"
    }

    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 15
        return Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -Body $json
    }

    return Invoke-RestMethod -Method $Method -Uri $url -Headers $headers
}

function Get-StatusCode {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }

    return $null
}

function Ensure-Project {
    param(
        [string]$Id,
        [string]$Name
    )

    try {
        $existing = Invoke-TeamCityApi -Method Get -Path "/app/rest/projects/id:$Id"
        Write-Host "Projekt vorhanden: $($existing.id)"
        return
    }
    catch {
        $statusCode = Get-StatusCode -ErrorRecord $_
        if ($statusCode -ne 404) {
            throw
        }
    }

    $payload = @{
        id = $Id
        name = $Name
        parentProject = @{ id = "_Root" }
    }

    $created = Invoke-TeamCityApi -Method Post -Path "/app/rest/projects" -Body $payload
    Write-Host "Projekt angelegt: $($created.id)"
}

function Ensure-BuildType {
    param(
        [string]$BuildTypeId,
        [string]$BuildTypeName,
        [string]$ProjectIdForBuild
    )

    try {
        $existing = Invoke-TeamCityApi -Method Get -Path "/app/rest/buildTypes/id:$BuildTypeId"
        Write-Host "Build-Konfiguration vorhanden: $($existing.id)"
        return
    }
    catch {
        $statusCode = Get-StatusCode -ErrorRecord $_
        if ($statusCode -ne 404) {
            throw
        }
    }

    $payload = @{
        id = $BuildTypeId
        name = $BuildTypeName
        project = @{ id = $ProjectIdForBuild }
    }

    $created = Invoke-TeamCityApi -Method Post -Path "/app/rest/buildTypes" -Body $payload
    Write-Host "Build-Konfiguration angelegt: $($created.id)"
}

function Queue-Build {
    param(
        [string]$BuildTypeIdForQueue
    )

    $payload = @{ buildType = @{ id = $BuildTypeIdForQueue } }
    $queued = Invoke-TeamCityApi -Method Post -Path "/app/rest/buildQueue" -Body $payload
    Write-Host "Build eingeplant: buildType=$BuildTypeIdForQueue queueId=$($queued.id)"
}

if ($runSeedMode) {
    $seed = @(
        @{
            ProjectId = "demo_alpha"
            ProjectName = "Demo Alpha"
            BuildTypes = @(
                @{ Id = "demo_alpha_smoke"; Name = "Smoke" },
                @{ Id = "demo_alpha_api"; Name = "API Checks" }
            )
        },
        @{
            ProjectId = "demo_beta"
            ProjectName = "Demo Beta"
            BuildTypes = @(
                @{ Id = "demo_beta_unit"; Name = "Unit Tests" },
                @{ Id = "demo_beta_package"; Name = "Package" }
            )
        },
        @{
            ProjectId = "demo_gamma"
            ProjectName = "Demo Gamma"
            BuildTypes = @(
                @{ Id = "demo_gamma_lint"; Name = "Lint" },
                @{ Id = "demo_gamma_release"; Name = "Release Dry Run" }
            )
        }
    )

    foreach ($project in $seed) {
        Ensure-Project -Id $project.ProjectId -Name $project.ProjectName

        foreach ($bt in $project.BuildTypes) {
            Ensure-BuildType -BuildTypeId $bt.Id -BuildTypeName $bt.Name -ProjectIdForBuild $project.ProjectId
            if ($QueueBuilds) {
                try {
                    Queue-Build -BuildTypeIdForQueue $bt.Id
                }
                catch {
                    Write-Host "Build konnte nicht eingeplant werden: $($bt.Id)"
                }
            }
        }
    }

    Write-Host "Seed abgeschlossen: 3 Projekte, 6 Build-Konfigurationen."
    exit 0
}

Ensure-Project -Id $ProjectId -Name $ProjectName
