<#
.SYNOPSIS
    Останавливает Compose-стенд «Эффективность 360», поднятый через up.ps1.

.DESCRIPTION
    По умолчанию использует project name 'effectivnost360' (или значение из
    .compose-project, если оно было создано up.ps1). Можно переопределить
    через -Project.

.PARAMETER Project
    Имя Compose-проекта. Если не задано — берётся из .compose-project
    или используется 'effectivnost360'.

.PARAMETER Clean
    Дополнительно удалить все volumes (PostgreSQL, NATS, frontend_dist).

.EXAMPLE
    .\scripts\down.ps1
    .\scripts\down.ps1 -Clean
    .\scripts\down.ps1 -Project myproj -Clean
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [string]$Project = "",
    [switch]$Clean
)

if (-not $Project -and (Test-Path ".compose-project")) {
    $Project = (Get-Content ".compose-project" -Raw).Trim()
}
if (-not $Project) {
    $Project = "effectivnost360"
}

Write-Host "Stopping project: $Project"

$ComposeArgs = @("-p", $Project, "down", "--remove-orphans")
if ($Clean) { $ComposeArgs += "--volumes" }

& docker compose @ComposeArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: docker compose down failed with code $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

if ($Clean -and (Test-Path ".compose-project")) {
    Remove-Item ".compose-project"
}

Write-Host "Stack stopped."
