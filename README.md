# TeamCity Docker Setup with MCP Test Data

A local TeamCity test environment using Docker Compose, plus PowerShell scripts for creating sample projects, listing TeamCity data, and capturing MCP-related request/response traffic.

## Table of Contents

- [1. Purpose](#1-purpose)
- [1a. Disclaimer](#1a-disclaimer)
- [2. What This Repository Contains](#2-what-this-repository-contains)
- [3. Architecture](#3-architecture)
- [4. Requirements](#4-requirements)
- [5. Platform Compatibility](#5-platform-compatibility)
- [6. Configuration](#6-configuration)
- [7. First Start](#7-first-start)
- [8. Token Setup in TeamCity](#8-token-setup-in-teamcity)
- [8a. Agent Authorization](#8a-agent-authorization)
- [9. Scripts](#9-scripts)
- [10. Output Files and Reports](#10-output-files-and-reports)
- [11. What the Raw MCP Files Actually Contain](#11-what-the-raw-mcp-files-actually-contain)
- [12. Recommended Test Flow](#12-recommended-test-flow)
- [13. Docker Persistence](#13-docker-persistence)
- [14. Useful Commands](#14-useful-commands)
- [15. Public GitHub Repository Notes](#15-public-github-repository-notes)
- [16. Legal Notice and Third-Party Terms](#16-legal-notice-and-third-party-terms)
- [17. Troubleshooting](#17-troubleshooting)

## 1. Purpose

This repository is designed as a learning and testing project for:

- running TeamCity locally in Docker
- creating multiple TeamCity projects and build configurations quickly
- testing TeamCity's MCP plugin availability
- capturing request and response data sent between the script and the TeamCity server

The goal is to have a reproducible local setup that can be used to inspect TeamCity REST and MCP-related behavior.

## 1a. Disclaimer

This repository is intended for local testing, learning, and demonstration purposes only.

It is provided as-is, without any guarantee of correctness, completeness, security, or fitness for production use. Use it at your own risk.

Do not treat the included scripts, Docker setup, or generated reports as production-ready security guidance, operational best practice, or a supported deployment model.

## 2. What This Repository Contains

- [docker-compose.yml](docker-compose.yml): TeamCity server and agent services
- [docker/teamcity-server/Dockerfile](docker/teamcity-server/Dockerfile): TeamCity server image wrapper
- [docker/teamcity-agent/Dockerfile](docker/teamcity-agent/Dockerfile): TeamCity agent image wrapper
- [.env](.env): local runtime configuration
- [scripts/create-teamcity-project-rest-api.ps1](scripts/create-teamcity-project-rest-api.ps1): creates sample TeamCity data directly via the TeamCity REST API
- [scripts/list-teamcity-data-rest-api.ps1](scripts/list-teamcity-data-rest-api.ps1): lists projects, build configurations, and queue entries directly via the TeamCity REST API
- [scripts/query-teamcity-builds-rest-api.ps1](scripts/query-teamcity-builds-rest-api.ps1): queries builds, logs, tests, artifacts, and agents directly via the TeamCity REST API
- [scripts/query-teamcity-builds-mcp.ps1](scripts/query-teamcity-builds-mcp.ps1): MCP-only query flow (JSON-RPC over `/app/mcp`)
- [scripts/test-teamcity-direct-api-variants.ps1](scripts/test-teamcity-direct-api-variants.ps1): direct REST API test variants (`inventory`, `filters`, `methods`, `plugins`, `negative`)
- [scripts/test-teamcity-mcp-all-tools.ps1](scripts/test-teamcity-mcp-all-tools.ps1): MCP probe that discovers tools and calls all available tool functions with practical variants
- [scripts/test-teamcity-mcp-handshake.ps1](scripts/test-teamcity-mcp-handshake.ps1): MCP-only handshake smoke test (`initialize -> initialized -> tools/list`)
- [LICENSE](LICENSE): repository license

## 3. Architecture

```mermaid
flowchart LR
    A[Docker Compose] --> B[TeamCity Server]
    A --> C[TeamCity Agent]
    B --> D[REST API]
    B --> E[MCP Plugin Endpoint]
  D --> F[create-teamcity-project-rest-api.ps1]
  D --> G[list-teamcity-data-rest-api.ps1]
  D --> H[query-teamcity-builds-rest-api.ps1]
  D --> I[test-teamcity-direct-api-variants.ps1]
  E --> J[query-teamcity-builds-mcp.ps1]
  E --> K[test-teamcity-mcp-handshake.ps1]
  E --> L[test-teamcity-mcp-all-tools.ps1]
```

```mermaid
sequenceDiagram
    participant U as User
    participant S as PowerShell Script
    participant T as TeamCity Server
  U->>S: create-teamcity-project-rest-api.ps1
    S->>T: Create projects, build types, queue builds
  U->>S: list-teamcity-data-rest-api.ps1
    S->>T: GET projects/buildTypes/buildQueue
  U->>S: query-teamcity-builds-rest-api.ps1
  S->>T: GET builds/logs/tests/artifacts/agents
  U->>S: query-teamcity-builds-mcp.ps1
  S->>T: POST MCP JSON-RPC tools/list and tools/call
  U->>S: test-teamcity-mcp-handshake.ps1
    S->>T: POST MCP JSON-RPC initialize, initialized, tools/list via /app/mcp
  U->>S: test-teamcity-direct-api-variants.ps1
    S->>T: GET/HEAD/OPTIONS against /app/rest/... variants
  U->>S: test-teamcity-mcp-all-tools.ps1
    S->>T: tools/list and tools/call across available MCP tools
    T-->>S: status, headers, body
    S-->>U: report files
```

## 4. Requirements

- Docker Desktop installed and running
- Docker Compose v2 available
- PowerShell 7 available as `pwsh`
- initial TeamCity setup completed once in the browser

## 5. Platform Compatibility

The scripts are written in PowerShell and are intended to work across:

- Windows
- Linux
- macOS

Recommended shell on all platforms:

```text
pwsh
```

If `pwsh` is not installed yet, install PowerShell 7 first.

Typical examples:

- Windows: install PowerShell 7 and run it as `pwsh`
- Linux: install the `powershell` package for your distribution and run `pwsh`
- macOS: install PowerShell 7 and run `pwsh`

Recommended usage:

- use `pwsh` on Windows as well
- use the same commands on Linux and macOS
- treat Windows PowerShell 5.1 as optional, not as the primary shell
- run all documented script commands from the repository root unless noted otherwise

Examples:

Windows:

```powershell
pwsh ./scripts/create-teamcity-project-rest-api.ps1
```

Linux or macOS:

```bash
pwsh ./scripts/create-teamcity-project-rest-api.ps1
```

If script execution is blocked on Windows, run this once per session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

On Linux and macOS, `Set-ExecutionPolicy` is usually not needed, but `pwsh` must be installed.

## 6. Configuration

The repository uses [.env](.env) for shared defaults.

Current supported values:

```env
TEAMCITY_HTTP_PORT=8111
TEAMCITY_BASE_URL=http://localhost:8111
TEAMCITY_REPORT_DIR=reports
TEAMCITY_TOKEN=your_token_here
```

What each value means:

- `TEAMCITY_HTTP_PORT`: published TeamCity web port on the host
- `TEAMCITY_BASE_URL`: default base URL used by all PowerShell scripts when `-BaseUrl` is omitted
- `TEAMCITY_REPORT_DIR`: output directory for generated reports; relative paths are resolved from the repository root and the folder is created automatically
- `TEAMCITY_TOKEN`: TeamCity access token used by the scripts

All scripts first use explicitly passed parameters, then environment variables, then `.env` values.

## 7. First Start

Run all commands from the repository root:

```text
teamcity-test-server/
```

Start the stack:

```powershell
docker compose up -d --build
```

Open TeamCity:

`http://localhost:8111`

Complete the TeamCity startup wizard once.

## 8. Token Setup in TeamCity

To create the token used by the scripts:

1. Open TeamCity in the browser.
2. Click your user profile.
3. Open the profile or access token section.
4. Create a new access token.
5. Copy the token immediately.
6. Store it in [.env](.env) as `TEAMCITY_TOKEN=...`

Note: the token may not be shown again in full after creation.

## 8a. Agent Authorization

After the first start, the TeamCity agent (`docker-agent-01`) connects to the server but is initially **Unauthorized**.
Builds will stay in the queue and never be picked up until the agent is authorized.

### Option A – Authorize manually in the UI (recommended for first setup)

1. Open TeamCity in the browser: `http://localhost:8111`
2. Go to **Agents** in the top navigation.
3. Select the tab **Unauthorized**.
4. Click `docker-agent-01`.
5. Click **Authorize**.

The agent moves to **Connected & Authorized** and starts picking up queued builds immediately.

### Option B – Authorize via REST API (e.g. from a script or terminal)

Replace `<TOKEN>` with your TeamCity token from [.env](.env):

```powershell
Invoke-RestMethod `
  -Method Put `
  -Uri "http://localhost:8111/app/rest/agents/name:docker-agent-01/authorized" `
  -Headers @{ Authorization = "Bearer <TOKEN>"; "Content-Type" = "text/plain" } `
  -Body "true"
```

Or with `curl`:

```bash
curl -s -X PUT \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: text/plain" \
  -d "true" \
  http://localhost:8111/app/rest/agents/name:docker-agent-01/authorized
```

A `204 No Content` response means the agent is now authorized.

### When to re-authorize

Authorization is stored in the `agent_conf` Docker volume and survives container restarts.
You only need to authorize again after running `docker compose down -v` (full volume wipe).

## 9. Scripts

### 9.a Script Summary (What Is Tested)

- `create-teamcity-project-rest-api.ps1` (REST): creates or updates demo projects/build configurations and can queue builds; tests write access and object creation flow on `/app/rest/...`.
- `list-teamcity-data-rest-api.ps1` (REST): reads project/buildType/queue inventory; tests basic read access and visibility of TeamCity objects.
- `query-teamcity-builds-rest-api.ps1` (REST): performs broader build diagnostics (builds, queue, running, failed, tests, artifacts, agents); tests multi-endpoint REST querying and report generation.
- `test-teamcity-direct-api-variants.ps1` (REST): runs grouped direct API variants (`inventory`, `filters`, `methods`, `plugins`, `negative`); tests endpoint behavior, locator/query behavior, HTTP method handling, and expected error cases.
- `test-teamcity-mcp-handshake.ps1` (MCP): runs MCP session bootstrap (`initialize -> notifications/initialized -> tools/list`); tests that MCP endpoint and session handling work end-to-end.
- `test-teamcity-mcp-all-tools.ps1` (MCP): discovers available tools and executes tool calls with multiple variants; tests practical MCP usage and captures full raw MCP client-server exchanges.
- `query-teamcity-builds-mcp.ps1` (MCP): executes build-related queries through MCP tools; tests MCP-based read workflow for projects/build configurations/builds (optional build-specific calls).

Expected output artifacts by script family:

- REST variants: `teamcity-direct-api-variants-<variant>-*.json`
- REST query: `tc-builds-query-rest-api-*.json`
- MCP handshake/all-tools/query: `teamcity-mcp-all-tools-*.json`, `tc-builds-query-mcp-*.json`

### 9.b Copy-Paste API Calls (Terminal)

These examples are direct API commands you can run in `pwsh` without using the helper scripts.

Official TeamCity MCP documentation:

- https://www.jetbrains.com/help/teamcity/2026.1/ai-agent-integration.html#TeamCity+MCP

Set base variables first:

```powershell
$baseUrl = "http://localhost:8111"
$token = "<TEAMCITY_TOKEN>"
```

Direct REST API examples:

```powershell
$headers = @{ Authorization = "Bearer $token"; Accept = "application/json" }

Invoke-RestMethod -Method GET -Uri "$baseUrl/app/rest/projects" -Headers $headers
Invoke-RestMethod -Method GET -Uri "$baseUrl/app/rest/buildTypes" -Headers $headers
Invoke-RestMethod -Method GET -Uri "$baseUrl/app/rest/buildQueue" -Headers $headers
Invoke-RestMethod -Method GET -Uri "$baseUrl/app/rest/builds?locator=count:5" -Headers $headers
```

REST API log reading in practice (without helper scripts):

```powershell
# 1) Build list via /app/rest
$buildsRes = Invoke-RestMethod -Method GET -Uri "$baseUrl/app/rest/builds?locator=state:finished,count:5&fields=build(id,number,status,buildTypeId,webUrl)" -Headers $headers
$builds = @($buildsRes.build)

# 2) Full log text per build (TeamCity log endpoint)
foreach ($b in $builds) {
  Write-Host ""
  Write-Host ("=== Build {0} #{1} ({2}) ===" -f $b.id, $b.number, $b.status)

  $logRes = Invoke-WebRequest -Method GET -Uri "$baseUrl/downloadBuildLog.html?buildId=$($b.id)" -Headers @{ Authorization = "Bearer $token"; Accept = "text/plain" }
  $lines = @($logRes.Content -split "`r?`n")

  # Example: keep only warnings/errors and print first 80 lines
  $important = @($lines | Where-Object { $_ -match "\[(WARNING|FAILURE|ERROR)\]" })
  if ($important.Count -eq 0) { $important = $lines }
  $important | Select-Object -First 80 | ForEach-Object { Write-Host $_ }
}
```

  Short flow (REST):

  1. Fetch recent builds including `id`, `number`, and `status` via `/app/rest/builds`.
  2. Use each `buildId` to fetch that build's log text.
  3. Optionally filter log lines to `WARNING|FAILURE|ERROR` and print the first lines.

  API clarification (REST):

  - Yes: `/app/rest/builds` is the correct TeamCity REST API for build metadata.
  - Yes: The shown log-text call works in practice for build logs.
  - Important: Log text is fetched via `downloadBuildLog.html?buildId=...`, not via a `/app/rest/...` path.

MCP JSON-RPC examples (raw client-server flow):

The block below includes exactly 4 MCP requests after handshake setup:

- request 1: `tools/list`
- request 2: `tools/call` for `teamcity_rest_get`
- request 3: `tools/call` for `teamcity_build_log`
- request 4: `tools/call` for `teamcity_rest_post`

```powershell
$mcpUrl = "$baseUrl/app/mcp"
$mcpHeaders = @{ Authorization = "Bearer $token"; Accept = "application/json"; "Content-Type" = "application/json" }

$initPayload = @{
  jsonrpc = "2.0"
  id = "1"
  method = "initialize"
  params = @{
    protocolVersion = "2024-11-05"
    capabilities = @{}
    clientInfo = @{ name = "manual-mcp-client"; version = "1.0" }
  }
} | ConvertTo-Json -Depth 10

$initRes = Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $mcpHeaders -Body $initPayload
$sessionId = [string]$initRes.Headers['Mcp-Session-Id']
$mcpHeaders['Mcp-Session-Id'] = $sessionId

$initializedPayload = @{ jsonrpc = "2.0"; method = "notifications/initialized"; params = @{} } | ConvertTo-Json -Depth 10
Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $mcpHeaders -Body $initializedPayload

function Invoke-McpRpc {
  param(
    [string]$Id,
    [string]$Method,
    [hashtable]$Params = @{}
  )

  $payload = @{ jsonrpc = "2.0"; id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20
  Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $mcpHeaders -Body $payload
}

# 1) tools/list
$toolsListRes = Invoke-McpRpc -Id "2" -Method "tools/list" -Params @{}
$toolsListRes.Content

# 2) tools/call -> teamcity_rest_get
$restGetRes = Invoke-McpRpc -Id "3" -Method "tools/call" -Params @{
  name = "teamcity_rest_get"
  arguments = @{ path = "/app/rest/projects" }
}
$restGetRes.Content

# 3) tools/call -> teamcity_build_log
# Note: adjust buildId as needed
$buildLogRes = Invoke-McpRpc -Id "4" -Method "tools/call" -Params @{
  name = "teamcity_build_log"
  arguments = @{ buildId = "1"; count = "50" }
}
$buildLogRes.Content

# Optional: only warnings/errors from the log
$buildLogWarnRes = Invoke-McpRpc -Id "4b" -Method "tools/call" -Params @{
  name = "teamcity_build_log"
  arguments = @{ buildId = "1"; filter = "warnings"; start = "0"; count = "100" }
}
$buildLogWarnRes.Content

# 4) tools/call -> teamcity_rest_post
# Safe demo with intentionally invalid BuildType ID (shows request/response, does not start a real build)
$restPostRes = Invoke-McpRpc -Id "5" -Method "tools/call" -Params @{
  name = "teamcity_rest_post"
  arguments = @{ path = "/app/rest/buildQueue"; body = '{"buildType":{"id":"__does_not_exist__"}}' }
}
$restPostRes.Content
```

MCP API log reading in practice (without helper scripts):

```powershell
# Handshake
$mcpUrl = "$baseUrl/app/mcp"
$mcpHeaders = @{ Authorization = "Bearer $token"; Accept = "application/json"; "Content-Type" = "application/json" }

$initPayload = @{ jsonrpc = "2.0"; id = "1"; method = "initialize"; params = @{ protocolVersion = "2024-11-05"; capabilities = @{}; clientInfo = @{ name = "manual-mcp-client"; version = "1.0" } } } | ConvertTo-Json -Depth 20
$initRes = Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $mcpHeaders -Body $initPayload
$mcpHeaders["Mcp-Session-Id"] = [string]$initRes.Headers["Mcp-Session-Id"]

$initializedPayload = @{ jsonrpc = "2.0"; method = "notifications/initialized"; params = @{} } | ConvertTo-Json -Depth 10
Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $mcpHeaders -Body $initializedPayload | Out-Null

function Invoke-McpRpc {
  param([string]$Id, [string]$Method, [hashtable]$Params = @{})
  $payload = @{ jsonrpc = "2.0"; id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 30
  Invoke-WebRequest -Method POST -Uri $mcpUrl -Headers $mcpHeaders -Body $payload
}

# 1) Build IDs via teamcity_rest_get tool
$buildsCall = Invoke-McpRpc -Id "10" -Method "tools/call" -Params @{ name = "teamcity_rest_get"; arguments = @{ path = "/app/rest/builds"; query = "locator=state:finished,count:5&fields=build(id,number,status,buildTypeId,webUrl)" } }
$buildsEnvelope = ($buildsCall.Content | ConvertFrom-Json -Depth 60)
$buildsJsonText = [string]$buildsEnvelope.result.content[0].text
$buildsBody = (($buildsJsonText | ConvertFrom-Json -Depth 60).body)
$builds = @($buildsBody.build)

# 2) Log text via teamcity_build_log tool
foreach ($b in $builds) {
  Write-Host ""
  Write-Host ("=== Build {0} #{1} ({2}) ===" -f $b.id, $b.number, $b.status)

  $logCall = Invoke-McpRpc -Id "20" -Method "tools/call" -Params @{ name = "teamcity_build_log"; arguments = @{ buildId = [string]$b.id; count = "200" } }
  $logEnvelope = ($logCall.Content | ConvertFrom-Json -Depth 60)
  $logText = [string]$logEnvelope.result.content[0].text
  $logLines = @($logText -split "`r?`n")

  # Example: keep only warnings/errors and print first 80 lines
  $important = @($logLines | Where-Object { $_ -match "\[(WARNING|FAILURE|ERROR)\]" })
  if ($important.Count -eq 0) { $important = $logLines }
  $important | Select-Object -First 80 | ForEach-Object { Write-Host $_ }
}
```

Short flow (MCP):

1. Start the MCP session with `initialize` and `notifications/initialized`.
2. Fetch the build list via `tools/call` using `teamcity_rest_get`.
3. Fetch each build log via `tools/call` using `teamcity_build_log`, and filter warnings/errors if needed.

API clarification (MCP):

- Yes: `teamcity_build_log` is the correct MCP tool command for build logs.
- Yes: The correct MCP call is `tools/call` with `name = "teamcity_build_log"`.
- Typical arguments are `buildId` (required), with optional `count`, `start`, and `filter`.

### 9.0 Quick Test Matrix (MCP vs Direct API)

- MCP-only tests (no direct REST endpoint checks from client):
  - `pwsh ./scripts/test-teamcity-mcp-handshake.ps1`
  - `pwsh ./scripts/test-teamcity-mcp-all-tools.ps1`
  - `pwsh ./scripts/query-teamcity-builds-mcp.ps1`
  - `pwsh ./scripts/read-teamcity-build-logs-mcp.ps1 -AllBuilds -MaxBuilds 5 -LogFilter all`
- Direct API tests (client calls `/app/rest/...` directly):
  - `pwsh ./scripts/test-teamcity-direct-api-variants.ps1 -Variant all`
  - `pwsh ./scripts/test-teamcity-direct-api-variants.ps1 -Variant filters`
  - `pwsh ./scripts/test-teamcity-direct-api-variants.ps1 -Variant negative`
  - `pwsh ./scripts/list-teamcity-data-rest-api.ps1`
  - `pwsh ./scripts/query-teamcity-builds-rest-api.ps1`
  - `pwsh ./scripts/read-teamcity-build-logs-rest.ps1 -AllBuilds -MaxBuilds 5 -LogFilter all`
  - `pwsh ./scripts/create-teamcity-project-rest-api.ps1`


If PowerShell blocks script execution, allow it for the current session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

### 9.1 create-teamcity-project-rest-api.ps1

File: [scripts/create-teamcity-project-rest-api.ps1](scripts/create-teamcity-project-rest-api.ps1)

Default behavior:

```powershell
pwsh ./scripts/create-teamcity-project-rest-api.ps1
```

By default this script creates full demo test data and queues builds automatically.

Default output created by this script:

- 3 projects: `demo_alpha`, `demo_beta`, `demo_gamma`
- 6 build configurations total
- 6 queued builds

Single project mode:

```powershell
pwsh ./scripts/create-teamcity-project-rest-api.ps1 -SingleProject -ProjectId "demo_project" -ProjectName "Demo Project"
```

Explicit test-data mode:

```powershell
pwsh ./scripts/create-teamcity-project-rest-api.ps1 -CreateTestData
```

Explicit test-data mode with build queue:

```powershell
pwsh ./scripts/create-teamcity-project-rest-api.ps1 -CreateTestData -QueueBuilds
```

What the script does internally:

- reads `TEAMCITY_TOKEN` and `TEAMCITY_BASE_URL`
- creates missing TeamCity projects
- creates missing build configurations
- optionally queues builds
- skips objects that already exist

### 9.2 list-teamcity-data-rest-api.ps1

File: [scripts/list-teamcity-data-rest-api.ps1](scripts/list-teamcity-data-rest-api.ps1)

Run:

```powershell
pwsh ./scripts/list-teamcity-data-rest-api.ps1
```

What it does:

- calls TeamCity REST API
- lists current projects
- lists current build configurations
- lists current build queue count

What it prints:

- total project count
- total build configuration count
- total queued build count
- a short project list
- a short build configuration list

This script is REST-only. It does not test MCP directly.

### 9.3 test-teamcity-direct-api-variants.ps1

File: [scripts/test-teamcity-direct-api-variants.ps1](scripts/test-teamcity-direct-api-variants.ps1)

Run all direct API variants:

```powershell
pwsh ./scripts/test-teamcity-direct-api-variants.ps1 -Variant all
```

Run a single direct API variant:

```powershell
pwsh ./scripts/test-teamcity-direct-api-variants.ps1 -Variant filters
```

Available variants:

- `inventory`: core direct `/app/rest/...` endpoints
- `filters`: query and locator variations
- `methods`: HTTP method checks (`GET`, `HEAD`, `OPTIONS`)
- `plugins`: plugin inventory endpoint checks
- `negative`: expected-error paths for diagnostics

Raw protocol fields per direct API call in the report:

- `method`, `url`, `requestHeaders`, `rawRequestBody`
- `status`, `responseHeaders`, `rawResponseBody`
- `ok`, `error`, `responseSnippet`

### 9.4 test-teamcity-mcp-all-tools.ps1

File: [scripts/test-teamcity-mcp-all-tools.ps1](scripts/test-teamcity-mcp-all-tools.ps1)

Run:

```powershell
pwsh ./scripts/test-teamcity-mcp-all-tools.ps1
```

What it does:

- executes `initialize`, `notifications/initialized`, `tools/list`, and `resources/list`
- discovers tool definitions dynamically from `tools/list`
- calls every discovered tool at least once
- executes practical variants for known TeamCity tools (for example multiple `teamcity_rest_get` requests)
- stores raw and parsed request/response payloads in one report

Raw protocol fields per MCP exchange in the report:

- `requestMethod`, `url`, `requestHeaders`, `rawRequestBody`
- `status`, `responseHeaders`, `rawResponseBody`
- `label`, `ok`, `error`

Complete communication trace:

- `exchanges[]` contains setup calls, meta calls, and every `tools/call` exchange in order

How to read report sections quickly:

- `setup`: MCP session bootstrap (`initialize`, `notifications/initialized`, `tools/list`)
- `toolCatalog`: discovered capabilities from `tools/list` (what the server offers)
- `toolCalls`: executed `tools/call` test cases (what the script actually ran)
- `metaCalls`: auxiliary calls not counted as main tool test cases (for example `resources/list`)
- `exchanges`: chronological timeline of all captured exchanges across setup, meta, and tool calls

Rule of thumb:

- `toolCatalog` = possible
- `toolCalls` = executed
- `exchanges` = full timeline

Optional write-mode for `teamcity_rest_post` tools:

```powershell
pwsh ./scripts/test-teamcity-mcp-all-tools.ps1 -AllowWriteOperations
```

### 9.5 test-teamcity-mcp-handshake.ps1

File: [scripts/test-teamcity-mcp-handshake.ps1](scripts/test-teamcity-mcp-handshake.ps1)

Run:

```powershell
pwsh ./scripts/test-teamcity-mcp-handshake.ps1
```

This is the clear MCP-only handshake smoke test entrypoint.

### 9.6 query-teamcity-builds-rest-api.ps1

File: [scripts/query-teamcity-builds-rest-api.ps1](scripts/query-teamcity-builds-rest-api.ps1)

Run:

```powershell
pwsh ./scripts/query-teamcity-builds-rest-api.ps1
```

What it does:

- queries TeamCity build data directly via `/app/rest/...`
- collects builds, queue state, running builds, failed builds, tests, artifacts, and agents
- writes a REST-only report file by default

Default report pattern:

- `tc-builds-query-rest-api-*.json`

### 9.7 query-teamcity-builds-mcp.ps1

File: [scripts/query-teamcity-builds-mcp.ps1](scripts/query-teamcity-builds-mcp.ps1)

Run:

```powershell
pwsh ./scripts/query-teamcity-builds-mcp.ps1
```

Optional build-specific MCP calls:

```powershell
pwsh ./scripts/query-teamcity-builds-mcp.ps1 -BuildId 123
```

What it does:

- calls TeamCity MCP via `/app/mcp`
- runs `initialize`, `tools/list`, `list_projects`, `list_build_configurations`, and `list_builds`
- optionally runs `get_build_log` and `get_test_results` for a specific build ID
- writes an MCP-only report file by default

Default report pattern:

- `tc-builds-query-mcp-*.json`

## 10. Output Files and Reports

All generated report files are written to `reports/` by default via `TEAMCITY_REPORT_DIR=reports` in [.env](.env).

### 10.1 Direct API Variant Reports

Pattern:

- `teamcity-direct-api-variants-<variant>-*.json`

Source script:

- `test-teamcity-direct-api-variants.ps1`

### 10.2 MCP All-Tools Reports

Pattern:

- `teamcity-mcp-all-tools-*.json`

Source script:

- `test-teamcity-mcp-all-tools.ps1`

### 10.3 REST Query Reports

Pattern:

- `tc-builds-query-rest-api-*.json`

Source script:

- `query-teamcity-builds-rest-api.ps1`

### 10.4 MCP Query Reports

Pattern:

- `tc-builds-query-mcp-*.json`

Source script:

- `query-teamcity-builds-mcp.ps1`

## 11. What the Raw MCP Files Actually Contain

This is the most important distinction in this repository.

### 11.1 What is captured exactly

The raw files capture:

- the HTTP request sent by the script
- the HTTP response returned by TeamCity

That includes:

- method
- URL
- headers
- request body
- response status
- response headers
- response body

### 11.2 What is considered original

For this repository, the raw report is intended to preserve the request and response content exactly as used in the HTTP exchange.

That means:

- the request body is stored as sent
- the response body is stored as returned
- the authorization header is stored as sent
- response headers are stored as returned

### 11.3 Why the JSON file still looks escaped

The file itself is a JSON document.

So characters may appear escaped, for example:

- `\"`
- `\u003c`
- `\n`

This is normal JSON encoding of the saved file.
It does not mean the request or response content was semantically changed.

### 11.4 Which fields matter most

If you want the most direct request/response view, focus on:

- raw report file: `request.headers`, `request.body`, `response.headers`, `response.body`
- advanced report file: `requestHeaders`, `requestBody`, `responseHeaders`, `responseBodyRaw`

### 11.5 bodySnippet vs bodyRaw vs responseBodyRaw

In the advanced report:

- `bodySnippet`: currently stores the full response body in this project
- `bodyRaw`: stores the same body when raw body capture is enabled
- `responseBodyRaw`: stores the response body as returned by the server

For practical inspection, `responseBodyRaw` is the clearest field to treat as the captured server response body.

## 12. Recommended Test Flow

1. Start TeamCity:

```powershell
docker compose up -d --build
```

2. Seed sample TeamCity data:

```powershell
pwsh ./scripts/create-teamcity-project-rest-api.ps1
```

3. Verify projects, build types, and queue entries:

```powershell
pwsh ./scripts/list-teamcity-data-rest-api.ps1
```

4. Run the MCP JSON-RPC handshake smoke test:

```powershell
pwsh ./scripts/test-teamcity-mcp-handshake.ps1
```

5. Run direct API variants (clear direct-only test):

```powershell
pwsh ./scripts/test-teamcity-direct-api-variants.ps1 -Variant all
```

6. Run explicit build queries depending on protocol:

```powershell
pwsh ./scripts/query-teamcity-builds-rest-api.ps1
pwsh ./scripts/query-teamcity-builds-mcp.ps1
```

7. Inspect the generated files:

- by default under `reports/`
- `teamcity-direct-api-variants-<variant>-*.json`
- `teamcity-mcp-all-tools-*.json`
- `tc-builds-query-rest-api-*.json`
- `tc-builds-query-mcp-*.json`

## 13. Docker Persistence

Docker named volumes are used:

- `teamcity_data`
- `teamcity_logs`
- `agent_conf`
- `agent_work`
- `agent_temp`
- `agent_system`

These survive `docker compose down`.
A full clean reinstall requires removing volumes too:

```powershell
docker compose down -v
```

## 14. Useful Commands

Start:

```powershell
docker compose up -d --build
```

Status:

```powershell
docker compose ps
```

Server logs:

```powershell
docker compose logs -f teamcity-server
```

Agent logs:

```powershell
docker compose logs --tail=120 teamcity-agent
```

Stop:

```powershell
docker compose down
```

Full clean reinstall:

```powershell
docker compose down -v --remove-orphans
docker compose up -d --build
```

Build logs via MCP (recommended MCP flow):

```powershell
# Last finished build via MCP
pwsh ./scripts/read-teamcity-build-logs-mcp.ps1

# Multiple builds via MCP
pwsh ./scripts/read-teamcity-build-logs-mcp.ps1 -AllBuilds -MaxBuilds 5 -LogFilter all

# Specific build IDs via MCP
pwsh ./scripts/read-teamcity-build-logs-mcp.ps1 -BuildId 6,5 -LogFilter warnings
```

Build logs via direct API (REST):

```powershell
# Scripted REST flow
pwsh ./scripts/read-teamcity-build-logs-rest.ps1 -AllBuilds -MaxBuilds 5 -LogFilter all
```

## 15. Public GitHub Repository Notes

This repository can generally be published as a public GitHub repository as a learning project.

Important distinction:

- this repository contains your own setup, scripts, and documentation
- TeamCity itself is pulled from official JetBrains Docker images at runtime

That means this repository is primarily configuration and test tooling, not a redistribution of TeamCity binaries by itself.

About the license file:

- [LICENSE](LICENSE) is the license for this repository
- it is not a TeamCity license file
- you do not need to add a TeamCity product license file to publish this repository

Current repository behavior to be aware of:

- `.env` may contain a real TeamCity token
- generated raw report files may contain real authorization headers and raw request/response content
- this is intentional in this project for test and learning purposes

By default, generated reports are written to `reports/`, and `reports/` is ignored by Git in this repository.

You would only publish raw traffic captures if you explicitly add those ignored files to version control or move them to a tracked location.

The `.env` file itself can still contain a real TeamCity token and should be handled as sensitive local configuration.

For legal scope and third-party details, see section 16 and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## 16. Legal Notice and Third-Party Terms

This repository is licensed under the MIT License.

Scope clarification:

- the MIT License in [LICENSE](LICENSE) applies to this repository's own content only (scripts, Docker Compose setup, and documentation)
- TeamCity is third-party software provided by JetBrains and is used under JetBrains terms and licenses
- this repository does not claim ownership of TeamCity

Trademark and affiliation notice:

- TeamCity is a trademark of JetBrains s.r.o.
- this repository is an independent community project and is not affiliated with, endorsed by, or sponsored by JetBrains

Third-party notices:

- see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

This section is for transparency and is not legal advice.

## 17. Troubleshooting

### 17.1 401 Unauthorized

Cause:

- missing token
- invalid token
- expired token

Fix:

1. Create a new TeamCity access token.
2. Update `TEAMCITY_TOKEN` in [.env](.env).
3. Run the script again.

### 17.2 404 on MCP paths

Cause:

- wrong endpoint path
- MCP plugin not active

Fix:

1. Check TeamCity Administration -> Plugins.
2. Verify the MCP Server plugin is active.
3. Run [scripts/test-teamcity-mcp-handshake.ps1](scripts/test-teamcity-mcp-handshake.ps1) again.

### 17.3 405 on `/app/mcp`

Meaning:

- the endpoint exists
- the endpoint does not accept the probe request method for that specific test

In this repository, a `405` on `/app/mcp` is generally treated as evidence that the endpoint exists.

### 17.4 PowerShell execution policy blocks scripts

Typical error on Windows:

- `File <path> cannot be loaded because running scripts is disabled on this system.`
- `... because script execution is disabled on this system.`

Meaning:

- PowerShell execution policy is preventing local script execution

Run once per session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

Then run the script again in the same terminal.

### 17.5 TeamCity not reachable

Check:

```powershell
docker compose ps
docker compose logs --tail=120 teamcity-server
```

Common fix:

- change `TEAMCITY_HTTP_PORT` in [.env](.env)
- restart Docker Compose

### 17.6 Queue stays empty or stuck

Check:

- whether the TeamCity agent is connected
- whether projects and build configurations were created
- whether queue entries exist via [scripts/list-teamcity-data-rest-api.ps1](scripts/list-teamcity-data-rest-api.ps1)

Agent log check:

```powershell
docker compose logs --tail=120 teamcity-agent
```

### 17.7 Agent is connected but builds are never picked up

Cause:

- the agent is **Unauthorized** — this is the default state after the first start

Fix A (UI):

1. Open TeamCity → **Agents** → tab **Unauthorized**.
2. Click `docker-agent-01` → **Authorize**.

Fix B (REST API):

```powershell
Invoke-RestMethod `
  -Method Put `
  -Uri "http://localhost:8111/app/rest/agents/name:docker-agent-01/authorized" `
  -Headers @{ Authorization = "Bearer <TOKEN>"; "Content-Type" = "text/plain" } `
  -Body "true"
```

See [section 8a](#8a-agent-authorization) for the full explanation.
