<#
.SYNOPSIS
    Запускает citation validator внутри Python-tooling контейнера.

.DESCRIPTION
    Использует tooling-образ (или python:3.12-slim если образ ещё не
    собран). По умолчанию валидирует database/seeds/demo_synthetic_fixture.json.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [string]$Fixture = "database/seeds/demo_synthetic_fixture.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $repoRoot

Write-Host "[test-fixture] running citation validator on $Fixture"

# Prefer the local tooling image if it exists; otherwise fall back to
# python:3.12-slim (still avoids host Python).
$image = "effectivnost360/tooling:latest"
$useImage = $true
try {
    docker image inspect $image 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $useImage = $false }
} catch { $useImage = $false }

if ($useImage) {
    & docker run --rm -v "${repoRoot}:/work" -w /work $image python scripts/verify_fixture_citations.py --fixture $Fixture
} else {
    & docker run --rm -v "${repoRoot}:/work" -w /work python:3.12-slim python scripts/verify_fixture_citations.py --fixture $Fixture
}
exit $LASTEXITCODE
