# scripts/apply_db.ps1
# scripts/apply_db.ps1 — применение миграций и seed-файлов к PostgreSQL.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ СКРИПТ
#   SQL-файлы с кириллицей нельзя передавать в psql через конвейер
#   PowerShell (`Get-Content file.sql | psql`): конвейер перекодирует байты по
#   кодовой странице консоли (cp866/cp1251), и PostgreSQL сохраняет
#   "Р”РµРјРѕ" вместо "Демо". Поэтому файл КОПИРУЕТСЯ в контейнер через
#   `docker cp` (байты сохраняются) и выполняется там через `psql -f`.
#
# ИСПОЛЬЗОВАНИЕ
#   powershell -ExecutionPolicy Bypass -File scripts\apply_db.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\apply_db.ps1 -MigrationsOnly
#   powershell -ExecutionPolicy Bypass -File scripts\apply_db.ps1 -SeedsOnly
#
# ПАРАМЕТРЫ
#   -MigrationsOnly  применить только миграции
#   -SeedsOnly       применить только seed-файлы
#   -Container       имя контейнера PostgreSQL (по умолчанию из docker compose)

param(
  [switch]$MigrationsOnly,
  [switch]$SeedsOnly,
  [string]$Container = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Container) {
  # Канонический файл манифеста в проекте — compose.yaml (docker-compose.yml
  # в репозитории отсутствует).
  $Container = (docker compose -f (Join-Path $root 'compose.yaml') ps --format '{{.Name}}' postgres 2>$null |
    Where-Object { $_ -match 'postgres' } | Select-Object -First 1)
}
if (-not $Container) {
  throw 'Не удалось определить контейнер PostgreSQL. Запустите docker compose ps.'
}

Write-Host "Контейнер PostgreSQL: $Container" -ForegroundColor Cyan

function Invoke-SqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$LocalPath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -LiteralPath $LocalPath)) {
    Write-Warning "$Label : файл не найден ($LocalPath) — пропускаем"
    return
  }

  # Имя файла в контейнере должно быть уникальным, чтобы параллельные
  # запуски не мешали друг другу.
  $remote = "/tmp/apply_{0}_{1}.sql" -f ([guid]::NewGuid().ToString('N').Substring(0,8)), (Split-Path $LocalPath -Leaf)

  docker cp $LocalPath "${Container}:$remote" | Out-Null

  # -v ON_ERROR_STOP=1 — psql прерывается на первой ошибке, и код возврата
  # становится не��улевым. Это обязательно: иначе «успешная» миграция может
  # наполовину примениться.
  docker exec $Container psql -v ON_ERROR_STOP=1 -U effectivnost360 -d effectivnost360 -f $remote
  $code = $LASTEXITCODE

  docker exec $Container rm -f $remote | Out-Null

  if ($code -ne 0) {
    throw "$Label : применение не удалось (код выхода $code)"
  }
  Write-Host "OK  $Label" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Миграции
# ---------------------------------------------------------------------------
if (-not $SeedsOnly) {
  Write-Host ''
  Write-Host '== Миграции ==' -ForegroundColor Cyan
  $migrations = Get-ChildItem (Join-Path $root 'database\migrations') -Filter '*.sql' |
    Sort-Object Name
  foreach ($m in $migrations) {
    Invoke-SqlFile -LocalPath $m.FullName -Label $m.Name
  }
}

# ---------------------------------------------------------------------------
# Seed-файлы
# ---------------------------------------------------------------------------
if (-not $MigrationsOnly) {
  Write-Host ''
  Write-Host '== Seed-файлы ==' -ForegroundColor Cyan
  # Применяем только файлы вида *_seed_*.sql. Rollback-скрипты
  # (002_rollback_demo_business_trip.sql и т.п.) — это НЕ seed-файлы: они
  # удаляют данные и запускаются вручную, когда нужно откатить DEMO-набор.
  # Раньше они попадали в общий список и ломали установку.
  $seeds = Get-ChildItem (Join-Path $root 'database\seeds') -Filter '*_seed_*.sql' |
    Sort-Object Name
  foreach ($s in $seeds) {
    Invoke-SqlFile -LocalPath $s.FullName -Label $s.Name
  }
}

Write-Host ''
Write-Host 'Готово.' -ForegroundColor Cyan
