<#
.SYNOPSIS
    Показывает последние логи указанного сервиса Compose-стека.

.PARAMETER Service
    Имя сервиса: api, postgres, nats, outbox-relay, consumer, web.
    По умолчанию api.

.PARAMETER Tail
    Сколько последних строк показать. По умолчанию 100.

.PARAMETER Follow
    Следить за логами в реальном времени (как docker compose logs -f).

.PARAMETER Project
    Имя Compose-проекта. По умолчанию effectivnost360.

.EXAMPLE
    .\scripts\logs.ps1
    .\scripts\logs.ps1 -Service outbox-relay -Tail 200
    .\scripts\logs.ps1 -Service api -Follow
    .\scripts\logs.ps1 -Service consumer -Project myproj
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [ValidateSet("api", "postgres", "nats", "outbox-relay", "consumer", "web")]
    [string]$Service = "api",
    [int]$Tail = 100,
    [switch]$Follow,
    [string]$Project = ""
)

if (-not $Project -and (Test-Path ".compose-project")) {
    $Project = (Get-Content ".compose-project" -Raw).Trim()
}
if (-not $Project) {
    $Project = "effectivnost360"
}

$ComposeArgs = @("-p", $Project, "logs", "--tail=$Tail")
if ($Follow) { $ComposeArgs += "-f" }
$ComposeArgs += $Service

& docker compose @ComposeArgs
