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

function Ensure-BuildStep {
    param(
        [string]$BuildTypeId,
        [string]$StepName,
        [string]$Script
    )

    try {
        $existing = Invoke-TeamCityApi -Method Get -Path "/app/rest/buildTypes/id:$BuildTypeId/steps"
        $steps = @($existing.step)
        $match = $steps | Where-Object { $_.name -eq $StepName }
        if ($match) {
            Invoke-TeamCityApi -Method Delete -Path "/app/rest/buildTypes/id:$BuildTypeId/steps/$($match.id)" | Out-Null
        }
    }
    catch {
        $statusCode = Get-StatusCode -ErrorRecord $_
        if ($statusCode -ne 404) {
            throw
        }
    }

    $payload = @{
        name = $StepName
        type = "simpleRunner"
        properties = @{
            property = @(
                @{ name = "script.content"; value = $Script },
                @{ name = "use.custom.script"; value = "true" }
            )
        }
    }

    Invoke-TeamCityApi -Method Post -Path "/app/rest/buildTypes/id:$BuildTypeId/steps" -Body $payload | Out-Null
    Write-Host "Build-Step angelegt/aktualisiert: [$BuildTypeId] $StepName"
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
    # --- Smoke: HTTP-Checks gegen den TC-Server, Ergebnisse als TC-Testreport ---
    $scriptSmoke = @'
#!/bin/sh
echo "=== Smoke Test Suite ==="
echo "##teamcity[testSuiteStarted name='SmokeTests']"

echo "##teamcity[testStarted name='ServerReachability']"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://teamcity-server:8111/login.html 2>/dev/null || echo "000")
echo "Server HTTP status: $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo "  PASS: TeamCity server is reachable"
  echo "##teamcity[testFinished name='ServerReachability' duration='100']"
else
  echo "##teamcity[testFailed name='ServerReachability' message='Server unreachable (HTTP $HTTP_CODE)']"
fi

echo "##teamcity[testStarted name='AgentEnvironment']"
echo "  Agent hostname : $(hostname)"
echo "  OS             : $(uname -sr)"
echo "  User           : $(whoami)"
echo "##teamcity[testFinished name='AgentEnvironment' duration='5']"

echo "##teamcity[testStarted name='DiskSpace']"
USED=$(df -h / | awk 'NR==2{print $5}')
echo "  Disk used: $USED"
echo "##teamcity[testFinished name='DiskSpace' duration='5']"

echo "##teamcity[testSuiteFinished name='SmokeTests']"
echo "##teamcity[buildStatus text='Smoke OK | {build.status.text}']"
'@

    # --- API Checks: curl-basierte Endpoint-Validierung mit TC-Testreport ---
    $scriptApi = @'
#!/bin/sh
echo "=== API Check Suite ==="
echo "##teamcity[testSuiteStarted name='APIChecks']"

check() {
  NAME="$1" URL="$2" EXPECT="$3"
  echo "##teamcity[testStarted name='$NAME']"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null || echo "000")
  if echo "$EXPECT" | grep -qw "$CODE"; then
    echo "  PASS: $NAME -> HTTP $CODE"
    echo "##teamcity[testFinished name='$NAME' duration='80']"
  else
    echo "  FAIL: $NAME -> expected $EXPECT got $CODE"
    echo "##teamcity[testFailed name='$NAME' message='Expected $EXPECT, got HTTP $CODE']"
  fi
}

check "TC_Login_Page"   "http://teamcity-server:8111/login.html"       "200 302"
check "TC_REST_Root"    "http://teamcity-server:8111/app/rest"          "200 401"
check "TC_Health_Ready" "http://teamcity-server:8111/healthCheck/ready" "200"

echo "##teamcity[testSuiteFinished name='APIChecks']"
echo "=== API checks done ==="
'@

    # --- Unit Tests: TC-Service-Messages fuer Testreport + Statistiken ---
    $scriptUnit = @'
#!/bin/sh
echo "=== Unit Test Suite ==="
echo "##teamcity[testSuiteStarted name='com.example.demo']"

t() {
  echo "##teamcity[testStarted name='$1']"
  echo "  PASS: $1"
  echo "##teamcity[testFinished name='$1' duration='$2']"
}

t "UserServiceTest#createUser"      "38"
t "UserServiceTest#updateUser"      "22"
t "UserServiceTest#deleteUser"      "15"
t "OrderServiceTest#placeOrder"     "87"
t "OrderServiceTest#cancelOrder"    "43"
t "OrderServiceTest#listOrders"     "19"
t "InventoryServiceTest#checkStock" "31"
t "InventoryServiceTest#reserve"    "55"
t "NotificationServiceTest#email"   "66"
t "NotificationServiceTest#push"    "44"

echo "##teamcity[testSuiteFinished name='com.example.demo']"
echo "##teamcity[buildStatisticValue key='testCount' value='10']"
echo "##teamcity[buildStatisticValue key='testsPassed' value='10']"
echo "##teamcity[buildStatus text='10/10 tests passed | {build.status.text}']"
'@

    # --- Package: Artefakt erzeugen und per publishArtifacts veroeffentlichen ---
    $scriptPackage = @'
#!/bin/sh
VERSION="1.0.${BUILD_NUMBER:-0}"
echo "=== Package Build v$VERSION ==="
echo "##teamcity[progressMessage 'Compiling sources...']"
mkdir -p /tmp/pkgbuild/dist
echo "app binary v$VERSION" > /tmp/pkgbuild/dist/app.bin
printf '{"version":"%%s","timestamp":"%%s"}' "$VERSION" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" > /tmp/pkgbuild/dist/manifest.json
echo "Compiled: app.bin, manifest.json"
echo "##teamcity[progressMessage 'Packaging...']"
cd /tmp/pkgbuild
tar -czf "demo-app-${VERSION}.tar.gz" dist/
ls -lh "demo-app-${VERSION}.tar.gz"
echo "##teamcity[publishArtifacts '/tmp/pkgbuild/demo-app-*.tar.gz']"
echo "##teamcity[buildStatus text='Package v$VERSION built | {build.status.text}']"
echo "=== Package done ==="
'@

    # --- Lint: dateiweise Pruefung, Warnings als TC-Messages, Testreport ---
    $scriptLint = @'
#!/bin/sh
echo "=== Lint Suite ==="
echo "##teamcity[testSuiteStarted name='LintChecks']"
WARNINGS=0
for F in src/main.js src/api/client.js src/utils/helpers.js src/models/user.js src/models/order.js; do
  echo "##teamcity[testStarted name='lint:$F']"
  HASH=$(echo "$F" | cksum | awk '{print $1}')
  MOD=$((HASH % 4))
  if [ "$MOD" -eq "0" ]; then
    echo "  WARN $F:14 - prefer const over var (prefer-const)"
    echo "  WARN $F:31 - missing semicolon (semi)"
    WARNINGS=$((WARNINGS+2))
    echo "##teamcity[message text='$F: 2 warnings' status='WARNING']"
  else
    echo "  OK: $F"
  fi
  echo "##teamcity[testFinished name='lint:$F' duration='10']"
done
echo "##teamcity[testSuiteFinished name='LintChecks']"
echo "##teamcity[buildStatus text='Lint: $WARNINGS warnings | {build.status.text}']"
'@

    # --- Release Dry Run: Versionsinfo, Changelog, Publish-Simulation ---
    $scriptRelease = @'
#!/bin/sh
VERSION="2.4.${BUILD_NUMBER:-0}"
echo "=== Release Dry Run v$VERSION ==="
echo "##teamcity[progressMessage 'Preparing release $VERSION']"
echo "Version : $VERSION"
echo "Date    : $(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"
echo "Branch  : refs/heads/main (simulated)"
echo ""
echo "--- Changelog ---"
echo "  feat: Add bulk order processing"
echo "  feat: New user profile endpoint"
echo "  fix:  Correct pagination offset"
echo "  chore: Update dependencies"
echo "-----------------"
echo ""
echo "##teamcity[progressMessage 'Validating release conditions...']"
echo "Version tag available   ... OK"
echo "Required artifacts      ... OK (simulated)"
echo "Sign-off approvals      ... OK (simulated)"
echo ""
echo "DRY RUN - would publish:"
echo "  docker push example.registry.io/demo-app:$VERSION"
echo "  upload demo-app-${VERSION}.tar.gz"
echo ""
echo "##teamcity[buildStatus text='Release $VERSION ready (dry run) | {build.status.text}']"
echo "=== Dry run complete - no changes made ==="
'@

    $seed = @(
        @{
            ProjectId = "demo_alpha"
            ProjectName = "Demo Alpha"
            BuildTypes = @(
                @{ Id = "demo_alpha_smoke"; Name = "Smoke";      Script = $scriptSmoke },
                @{ Id = "demo_alpha_api";   Name = "API Checks"; Script = $scriptApi   }
            )
        },
        @{
            ProjectId = "demo_beta"
            ProjectName = "Demo Beta"
            BuildTypes = @(
                @{ Id = "demo_beta_unit";    Name = "Unit Tests"; Script = $scriptUnit    },
                @{ Id = "demo_beta_package"; Name = "Package";    Script = $scriptPackage }
            )
        },
        @{
            ProjectId = "demo_gamma"
            ProjectName = "Demo Gamma"
            BuildTypes = @(
                @{ Id = "demo_gamma_lint";    Name = "Lint";            Script = $scriptLint    },
                @{ Id = "demo_gamma_release"; Name = "Release Dry Run"; Script = $scriptRelease }
            )
        }
    )

    foreach ($project in $seed) {
        Ensure-Project -Id $project.ProjectId -Name $project.ProjectName

        foreach ($bt in $project.BuildTypes) {
            Ensure-BuildType -BuildTypeId $bt.Id -BuildTypeName $bt.Name -ProjectIdForBuild $project.ProjectId
            Ensure-BuildStep -BuildTypeId $bt.Id -StepName "Run" -Script $bt.Script
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

    Write-Host "Seed abgeschlossen: 3 Projekte, 6 Build-Konfigurationen (je mit Build-Step)."
    exit 0
}

Ensure-Project -Id $ProjectId -Name $ProjectName
