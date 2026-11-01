﻿<#
.SYNOPSIS
    Smoke-проверки API/infra каркаса Эффективность 360.
.NOTES
    Использует ручной разбор аргументов вместо param() для совместимости с PS 5.1.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Manual arg parsing (PS 5.1 friendly) ---
$ApiUrl = "http://localhost:8000"
$IdempotencyKey = ""
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ($args[$i]) {
        '^-(?i:apiurl)$'         { $ApiUrl = $args[$i + 1]; $i++ }
        '^-(?i:idempotencykey)$' { $IdempotencyKey = $args[$i + 1]; $i++ }
        '^-(?i:help)$|^-\?$'     {
            Write-Host "Usage: .\scripts\smoke_checks.ps1 [-ApiUrl <url>] [-IdempotencyKey <key>]"
            Write-Host "  -ApiUrl         Base URL of the API. Default: http://localhost:8000"
            Write-Host "  -IdempotencyKey Key for POST /api/v1/requests. Default: random GUID."
            exit 0
        }
        default { Write-Host ("Unknown argument: {0}" -f $args[$i]) -ForegroundColor Yellow }
    }
}

if (-not $IdempotencyKey) {
    $IdempotencyKey = [guid]::NewGuid().ToString()
}

$Pass = 0
$Fail = 0
$Total = 0

function Write-CheckResult {
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    $script:Total++
    if ($Ok) {
        $script:Pass++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
    }
    if ($Detail) {
        Write-Host ("       {0}" -f $Detail)
    }
}

Write-Host "====================================="
Write-Host ("Smoke checks against {0}" -f $ApiUrl)
Write-Host ("Idempotency key: {0}" -f $IdempotencyKey)
Write-Host "====================================="

# --- 1. /health ---
try {
    $resp = Invoke-WebRequest -Uri ("{0}/health" -f $ApiUrl) -Method Get -UseBasicParsing -TimeoutSec 5
    $ok = ($resp.StatusCode -eq 200) -and ($resp.Content -match '"status"\s*:\s*"ok"')
    Write-CheckResult "/health" $ok ("status={0} body={1}" -f $resp.StatusCode, $resp.Content.Trim())
} catch {
    Write-CheckResult "/health" $false ("exception: {0}" -f $_.Exception.Message)
}

# --- 2. /ready ---
try {
    $resp = Invoke-WebRequest -Uri ("{0}/ready" -f $ApiUrl) -Method Get -UseBasicParsing -TimeoutSec 5
    $ok = ($resp.StatusCode -eq 200) -and ($resp.Content -match '"status"\s*:\s*"ready"')
    Write-CheckResult "/ready" $ok ("status={0} body={1}" -f $resp.StatusCode, $resp.Content.Trim())
} catch {
    Write-CheckResult "/ready" $false ("exception: {0}" -f $_.Exception.Message)
}

# --- 3. POST first time ---
$Body = @{
    idempotency_key = $IdempotencyKey
    text            = ("Системный smoke-check (v0.1) - {0}" -f $IdempotencyKey)
} | ConvertTo-Json -Compress

$FirstId = $null
try {
    $resp = Invoke-WebRequest -Uri ("{0}/api/v1/requests" -f $ApiUrl) `
        -Method Post `
        -ContentType "application/json" `
        -Body $Body `
        -UseBasicParsing `
        -TimeoutSec 10
    $ok = ($resp.StatusCode -eq 202) -and ($resp.Content -match '"created"\s*:\s*true')
    Write-CheckResult "POST /api/v1/requests (first, expect 202/created=true)" $ok ("status={0} body={1}" -f $resp.StatusCode, $resp.Content.Trim())
    if ($ok) {
        $FirstId = ($resp.Content | ConvertFrom-Json).request_id
    }
} catch {
    Write-CheckResult "POST /api/v1/requests (first)" $false ("exception: {0}" -f $_.Exception.Message)
}

# --- 4. POST second time (same idempotency_key) ---
if ($FirstId) {
    try {
        $resp = Invoke-WebRequest -Uri ("{0}/api/v1/requests" -f $ApiUrl) `
            -Method Post `
            -ContentType "application/json" `
            -Body $Body `
            -UseBasicParsing `
            -TimeoutSec 10
        $ok = ($resp.StatusCode -eq 200) -and ($resp.Content -match '"created"\s*:\s*false')
        $SecondId = ($resp.Content | ConvertFrom-Json).request_id
        $sameId = ($SecondId -eq $FirstId)
        Write-CheckResult "POST /api/v1/requests (second, expect 200/created=false, same id)" ($ok -and $sameId) ("status={0} first_id={1} second_id={2}" -f $resp.StatusCode, $FirstId, $SecondId)
    } catch {
        Write-CheckResult "POST /api/v1/requests (second)" $false ("exception: {0}" -f $_.Exception.Message)
    }
} else {
    Write-CheckResult "POST /api/v1/requests (second)" $false "skipped: first POST did not return a request_id"
}

# --- 5. outbox-relay logs ---
Write-Host ""
Write-Host "--- outbox-relay logs (last 50) ---"
if (Test-Path ".compose-project") {
    $ProjectName = (Get-Content ".compose-project" -Raw).Trim()
    docker compose -p $ProjectName logs --tail=50 outbox-relay 2>$null
} else {
    docker compose logs --tail=50 outbox-relay 2>$null
}

# --- 6. Fixture citation validator (advisory) ---
# The validator is expected to FAIL while business_trip_fixture.json is in
# TODO state (no ПП № 501 quotes yet). This check is non-fatal for the
# overall smoke — it just surfaces the current state.
Write-Host ""
Write-Host "--- Fixture citation validator (advisory) ---"
try {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $validatorOut = & python "$repoRoot\scripts\verify_fixture_citations.py" 2>&1
    $validatorExit = $LASTEXITCODE
    if ($validatorExit -eq 0) {
        Write-Host "[INFO] citation validator PASS (fixture is ready for use)"
    } else {
        Write-Host "[WARN] citation validator found errors (fixture not yet ready; this is expected while TODO quotes exist)" -ForegroundColor Yellow
        # Show first 20 lines for context.
        ($validatorOut | Select-Object -First 20) | ForEach-Object { Write-Host "       $_" }
    }
} catch {
    Write-Host "[WARN] could not run citation validator: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- Summary ---
Write-Host ""
Write-Host "====================================="
if ($Fail -eq 0) {
    Write-Host ("ALL CHECKS PASSED ({0}/{1})" -f $Pass, $Total) -ForegroundColor Green
} else {
    Write-Host ("FAILURES: {0} of {1}" -f $Fail, $Total) -ForegroundColor Red
}
Write-Host "====================================="
exit $Fail
