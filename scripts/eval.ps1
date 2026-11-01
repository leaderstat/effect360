<#
.SYNOPSIS
    Запускает Python eval harness внутри tooling контейнера.

.DESCRIPTION
    По умолчанию вызывает `scripts/eval_harness.py --classifier heuristic`,
    чтобы получить детерминированные метрики. Реальный LLM-прогон
    выполняется отдельной командой `make live-eval` (см. docs/DEV_DOCKER.md).
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [string]$Classifier = "heuristic"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $repoRoot

Write-Host "[eval] running eval_harness.py --classifier $Classifier"

$image = "effectivnost360/tooling:latest"
$useImage = $true
try {
    docker image inspect $image 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $useImage = $false }
} catch { $useImage = $false }

if ($useImage) {
    & docker run --rm -v "${repoRoot}:/work" -w /work $image python scripts/eval_harness.py --classifier $Classifier
} else {
    & docker run --rm -v "${repoRoot}:/work" -w /work python:3.12-slim python scripts/eval_harness.py --classifier $Classifier
}
exit $LASTEXITCODE
