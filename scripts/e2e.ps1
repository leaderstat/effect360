<#
.SYNOPSIS
    Запускает Playwright E2E через tooling контейнер.

.DESCRIPTION
    Должен выполняться ТОЛЬКО при поднятом Compose-стенде (api + web).
    Использует mcr.microsoft.com/playwright:v1.49.1-jammy, чтобы избежать
    глобальной установки Playwright и Chromium на хосте.

    Скрипт scripts/qa_e2e.mjs принимает на вход URL фронтенда через env
    WEB_BASE_URL. По умолчанию используется http://web:8050 (внутри сети
    Compose) — он слушается в контейнере web.

.PARAMETER WebBaseUrl
    URL, доступный из контейнера. По умолчанию http://web:8050.

.PARAMETER ApiBaseUrl
    URL API, доступный из контейнера. По умолчанию http://api:8000.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [string]$WebBaseUrl = "http://web:8050",
    [string]$ApiBaseUrl = "http://api:8000"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $repoRoot

Write-Host "[e2e] running scripts/qa_e2e.mjs against $WebBaseUrl"

# Prefer the tooling image (carries Node + Playwright deps).
$image = "effectivnost360/tooling:latest"
$useImage = $true
try {
    docker image inspect $image 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $useImage = $false }
} catch { $useImage = $false }

if ($useImage) {
    & docker run --rm `
        --network effectivnost360_default `
        -v "${repoRoot}:/work" -w /work `
        -e "WEB_BASE_URL=$WebBaseUrl" `
        -e "API_BASE_URL=$ApiBaseUrl" `
        $image node scripts/qa_e2e.mjs
} else {
    & docker run --rm `
        --network effectivnost360_default `
        -v "${repoRoot}:/work" -w /work `
        -e "WEB_BASE_URL=$WebBaseUrl" `
        -e "API_BASE_URL=$ApiBaseUrl" `
        mcr.microsoft.com/playwright:v1.49.1-jammy node scripts/qa_e2e.mjs
}
exit $LASTEXITCODE
