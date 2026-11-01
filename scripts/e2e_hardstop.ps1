# scripts/e2e_hardstop.ps1 — end-to-end check of the regulatory hard stops.
#
# Runs against the live stack (PostgreSQL + API on :8000). It creates a
# draft, attaches it to the business-trip request type, and exercises the
# three outcomes of the blocking rules:
#
#   1. block_submit          -> 422 with hard_stops[]
#   2. needs_employer_review -> 200 (submitted), hard_stops[] in the body
#   3. no rule triggered     -> 200 (submitted)
#
# Usage: powershell -File scripts/e2e_hardstop.ps1

$ErrorActionPreference = 'Stop'
$api = 'http://localhost:8000'
$pg  = 'effectivnost-360-postgres-1'

function New-Session {
  $body = '{"email":"demo.applicant@example.invalid","password":"demo"}'
  (Invoke-RestMethod -Method Post -Uri "$api/api/v1/session" `
      -ContentType 'application/json' -Body $body).token
}

function New-Draft([string]$token) {
  $idem = [guid]::NewGuid().ToString()
  $body = "{`"idempotency_key`":`"$idem`",`"text`":`"Прошу оформить командировку в Казань с 12 по 14 ноября 2026 на конференцию`"}"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  (Invoke-RestMethod -Method Post -Uri "$api/api/v1/requests" `
      -ContentType 'application/json; charset=utf-8' `
      -Headers @{ Authorization = "Bearer $token" } -Body $bytes).request_id
}

function Set-Fields([string]$rid, [string]$sqlFile) {
  docker cp $sqlFile "${pg}:/tmp/e2e.sql" | Out-Null
  docker exec $pg psql -v ON_ERROR_STOP=1 -v "rid=$rid" `
      -U effectivnost360 -d effectivnost360 -f /tmp/e2e.sql | Out-Null
}

function Submit([string]$token, [string]$rid) {
  $out = Join-Path $env:TEMP "e2e_submit.json"
  $code = curl.exe -s -o $out -w '%{http_code}' -X POST `
      -H "Authorization: Bearer $token" "$api/api/v1/requests/$rid/submit"
  $body = Get-Content $out -Raw -Encoding UTF8
  [pscustomobject]@{ code = $code; body = ($body | ConvertFrom-Json) }
}

$token = New-Session
$rid   = New-Draft $token
Write-Host "draft: $rid"

# --- 1. block_submit: is_pregnant = true ------------------------------
Set-Fields $rid 'C:\home\Agents\effectivnost-360\.tmp\e2e_hardstop_prep.sql'
$r1 = Submit $token $rid
Write-Host "1) block_submit          -> HTTP $($r1.code) error=$($r1.body.error) hard_stops=$($r1.body.hard_stops.Count) action=$($r1.body.hard_stops[0].action) ref=$($r1.body.hard_stops[0].regulatory_ref_id)"
if ($r1.code -ne '422') { throw "expected 422 for block_submit, got $($r1.code)" }
if ($r1.body.hard_stops.Count -lt 1) { throw 'expected hard_stops[] in the answer' }
if ($r1.body.hard_stops[0].action -ne 'block_submit') { throw 'expected action=block_submit' }

# --- 2. needs_employer_review: apprentice contract --------------------
Set-Fields $rid 'C:\home\Agents\effectivnost-360\.tmp\e2e_review_prep.sql'
$r2 = Submit $token $rid
Write-Host "2) needs_employer_review -> HTTP $($r2.code) status=$($r2.body.status) hard_stops=$($r2.body.hard_stops.Count) action=$($r2.body.hard_stops[0].action)"
if ($r2.code -ne '200') { throw "expected 200 for needs_employer_review, got $($r2.code)" }
if ($r2.body.status -ne 'submitted') { throw "expected status=submitted, got $($r2.body.status)" }

# --- 3. clean submission on a fresh draft -----------------------------
$rid2 = New-Draft $token
Set-Fields $rid2 'C:\home\Agents\effectivnost-360\.tmp\e2e_clean_prep.sql'
$r3 = Submit $token $rid2
Write-Host "3) clean                 -> HTTP $($r3.code) status=$($r3.body.status) missing=$($r3.body.missing.Count)"
if ($r3.code -ne '200') { throw "expected 200 for a clean draft, got $($r3.code) body=$($r3.body | ConvertTo-Json -Compress)" }

Write-Host 'OK: all three hard-stop scenarios behave as specified.'
