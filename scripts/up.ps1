<#
.SYNOPSIS
    Поднимает Compose-стенд «Эффективность 360» для локального тестирования.

.DESCRIPTION
    Использует стабильное имя проекта (по умолчанию effectivnost360, можно
    переопределить через -Project). По умолчанию volumes сохраняются между
    запусками — данные PostgreSQL и NATS переживают рестарт.

.PARAMETER Project
    Имя Compose-проекта. По умолчанию effectivnost360.

.PARAMETER Fresh
    Полностью пересоздать все volumes (удалить данные PostgreSQL, NATS,
    frontend_dist). Используйте для чистого старта.

.PARAMETER Build
    Пересобрать образы API/worker/tooling перед стартом.

.EXAMPLE
    .\scripts\up.ps1
    .\scripts\up.ps1 -Build
    .\scripts\up.ps1 -Fresh
    .\scripts\up.ps1 -Project myproj
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [string]$Project = "effectivnost360",
    [switch]$Fresh,
    [switch]$Build
)

Write-Host "====================================="
Write-Host "Starting Effectivnost 360 stack"
Write-Host "Project name: $Project"
Write-Host "====================================="

if ($Fresh) {
    Write-Host "Stopping previous project (if any) and removing volumes..."
    docker compose -p $Project down --remove-orphans --volumes 2>$null
}

$ComposeArgs = @("-p", $Project, "up", "-d")
if ($Build) {
    $ComposeArgs += "--build"
}
$ComposeArgs += "--force-recreate"

& docker compose @ComposeArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: docker compose up failed with code $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

$Project | Out-File -FilePath ".compose-project" -Encoding ASCII -NoNewline

Write-Host "====================================="
Write-Host "Stack is up. Project name: $Project"
Write-Host "Next: make smoke / make e2e / make test"
Write-Host "====================================="
