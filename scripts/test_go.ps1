<#
.SYNOPSIS
    Запускает `go test -count=1 ./...` внутри Go-контейнера.
.DESCRIPTION
    Тесты выполняются через `docker build --target test services/worker`
    (см. Stage 1b в services/worker/Dockerfile).

    Почему не `docker run -v <repo>:/src`: bind-mount из C:\home не
    пробрасывается в Docker Desktop на этой машине. Прежний вариант
    молча запускал `go test ./...` на ПУСТОМ каталоге внутри контейнера
    и возвращал exit 0 — то есть тесты НЕ выполнялись, а CI показывал
    зелёный статус. Build-контекст берётся из каталога сервиса и
    работает корректно: исходники копируются в образ, тесты реально
    выполняются, и падение теста валит build.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [string]$Package = "./...",
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $repoRoot

Write-Host "[test-go] building worker test stage (package: $Package)"
Write-Host "[test-go]   docker build --target test services/worker"

$dockerArgs = @(
    "build", "--target", "test",
    "-t", "effectivnost360/worker-test:latest",
    "services/worker"
)

& docker @dockerArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[test-go] FAILED: docker build --target test exited $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "[test-go] OK — go test -count=1 ./... ran inside the build stage"
exit 0
