<#
.SYNOPSIS
    Проверяет синтаксис JS-файлов внутри Node-контейнера.

.DESCRIPTION
    Запускает `node --check` на services/web/app.js и scripts/qa_e2e.mjs.
    Использует node:20-alpine.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $repoRoot

Write-Host "[test-js] node --check services/web/app.js scripts/qa_e2e.mjs"

& docker run --rm -v "${repoRoot}:/work" -w /work node:20-alpine sh -lc "node --check services/web/app.js && node --check scripts/qa_e2e.mjs && echo '[test-js] OK'"
exit $LASTEXITCODE
