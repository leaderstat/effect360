# 05 — Регрессионный чек-лист перед демонстрацией

> **Назначение:** короткий пошаговый список проверок, который член команды или внешний проверяющий может выполнить за ~10 минут перед demo или сдачей. Каждый пункт — конкретное действие с ожидаемым результатом.
> **Дата среза:** 2026-11-01.
> **Связанные документы:** [`02-coverage-matrix.md`](02-coverage-matrix.md) — матрица, [`03-test-evidence.md`](03-test-evidence.md) — доказательства, [`04-test-gaps.md`](04-test-gaps.md) — пробелы.

## 0. Предусловие

- Docker Desktop запущен, WSL2 backend.
- В корне репозитория: `Test-Path .\.env` → True. Если False — `.\scripts\up.ps1` создаст его автоматически.

## 1. Стек

| # | Действие | Ожидаемый результат | PASS-критерий | Типичные причины FAIL |
|---|---|---|---|---|
| 1.1 | `.\scripts\up.ps1` | Команда завершается с exit 0 | exit 0 | Нет `.env`; порт 8000 занят |
| 1.2 | `docker compose ps` | 6 контейнеров `Up`/`healthy`: `postgres`, `nats`, `api`, `outbox-relay`, `consumer`, `web` | `Status` всех = `Up` или `Up (healthy)` | Healthcheck не прошёл; pull образа не завершился |
| 1.3 | Подождать 30 секунд после `up.ps1` | — | — | — |

## 2. API

| # | Действие | Ожидаемый результат | PASS-критерий | Типичные причины FAIL |
|---|---|---|---|---|
| 2.1 | `curl http://localhost:8000/health` | `200 {"status":"ok"}` | status 200, body содержит `"ok"` | API-контейнер не стартовал |
| 2.2 | `curl http://localhost:8000/ready` | `200 {"status":"ready"}` | status 200, body содержит `"ready"` | PostgreSQL не healthcheck-прошёл |
| 2.3 | `POST /api/v1/session` с `demo`/`demo.applicant@example.invalid` | `200 {…,"token":"…"}` | status 200, поле `token` присутствует | Учётная запись `demo.applicant` не в БД |
| 2.4 | `POST /api/v1/requests` с `Authorization: Bearer <token>` и `{"text":"…","idempotency_key":"<new-uuid>"}` | `202 {…,"request_id":"…","created":true}` | status 202, поле `created:true` | Невалидный токен; пустой `text` |
| 2.5 | Повторить тот же POST с тем же `idempotency_key` | `200 {…,"request_id":"<тот же>","created":false}` | status 200, `created:false`, `request_id` совпадает с шагом 2.4 | Если UUID не совпадает — идемпотентность сломана |
| 2.6 | `POST /api/v1/requests` без Bearer-токена | `401 {"error":"unauthorized"}` (или аналогичный) | status 401 | Если 200 — аутентификация не работает |

## 3. База данных

| # | Действие | Ожидаемый результат | PASS-критерий | Типичные причины FAIL |
|---|---|---|---|---|
| 3.1 | `docker exec -it <postgres> psql -U effectivnost360 -d effectivnost360 -c "\dt"` | ≥ 10 таблиц: `requests`, `users`, `regulations`, `clauses`, `request_types`, `requirements`, `gaps`, `request_events`, `audit_log`, `job_runs`, `outbox` (плюс возможные `sessions`, `departments`, …) | Список содержит все 11 ключевых таблиц | Миграции не применились |
| 3.2 | `SELECT COUNT(*) FROM outbox WHERE published_at IS NOT NULL` | Число ≈ `SELECT COUNT(*) FROM outbox` (в этой среде оба = 115) | Доля непубликованных < 1% | Relay не работает; NATS недоступен |
| 3.3 | `SELECT COUNT(*) FROM requests WHERE id='<id из 2.4>'::uuid` | 1 | count = 1 | Запись не сохранилась (идемпотентность сломана или БД read-only) |

## 4. Outbox и NATS

| # | Действие | Ожидаемый результат | PASS-критерий | Типичные причины FAIL |
|---|---|---|---|---|
| 4.1 | `docker logs --tail 50 effectivnost-360-outbox-relay-1` | Видна хотя бы одна строка `outbox events published, count: N` за последнюю минуту | Лог содержит свежее сообщение | Relay-контейнер упал |
| 4.2 | `docker logs --tail 50 effectivnost-360-consumer-1` | Видна хотя бы одна строка `job succeeded, subject=requests.created` за последнюю минуту | Лог содержит свежее `job succeeded` | Consumer упал; LLM недоступна |

## 5. Бизнес-логика

| # | Действие | Ожидаемый результат | PASS-критерий | Типичные причины FAIL |
|---|---|---|---|---|
| 5.1 | `python scripts/verify_fixture_citations.py --fixture database/seeds/business_trip_fixture.json` | `Passed checks : 21`, exit 0 | exit 0, `Errors : 0` | TODO-цитаты; структура fixture сломана |
| 5.2 | `python -m unittest scripts.test_verify_fixture_citations` | `Ran 24 tests in … OK` | exit 0, `OK` в выводе | Изменения в validator без обновления тестов |
| 5.3 | `node --check services/web/app.js` | (пустой вывод), exit 0 | exit 0 | Синтаксическая ошибка |

## 6. Hard-stop (если планируется demo)

| # | Действие | Ожидаемый результат | PASS-критерий | Типичные причины FAIL |
|---|---|---|---|---|
| 6.1 | `.\scripts\e2e_hardstop.ps1` | `OK: all three hard-stop scenarios behave as specified.` | exit 0, последняя строка = `OK: …` | Требует `e2e_hardstop_prep.sql` / `e2e_review_prep.sql` / `e2e_clean_prep.sql` в `.tmp/` |

**Перед запуском 6.1:** убедиться, что `.tmp/` содержит три SQL-файла с пред-подготовленными `requests`. Скрипт `e2e_hardstop.ps1` не создаёт их сам — это **ручная подготовка** (Backlog §13.4 описывает содержимое этих файлов).

## 7. UI (если планируется demo)

| # | Действие | Ожидаемый результат | PASS-критерий | Типичные причины FAIL |
|---|---|---|---|---|
| 7.1 | `curl http://localhost:8050/` | 200 + HTML с разметкой Lustre | status 200, длина > 1000 байт | web-контейнер не стартовал |
| 7.2 | `node scripts/check-login-ui.cjs` (если Playwright установлен) | `OK: the sign-in works, the cabinet opens and the session survives a reload.` | exit 0, последняя строка = `OK: …` | Playwright не установлен в `C:/tmp/shots-runner/` |

## 8. Известные ограничения

Перед demo обязательно проговорить с комиссией:

- **Реальная LLM не подключена.** Consumer использует heuristic fallback; метрики качества (accuracy / extraction) недоступны для реального провайдера.
- **Цитаты ПП № 501 в production-fixture заменены на TODO.** Validator их отвергнет, если fixture переключить на production. Сейчас демо работает с `business_trip_fixture.json`, в котором validator показывает `Warnings: 1` (`raw_text_source is empty`).
- **CSRF в API — no-op** (`services/api/src/effectivnost_360/router.gleam:283-293`). Это **production-блокер** для публичного развёртывания, не для локального demo.
- **Backlog.md содержит mojibake-текст** (Backlog §CURRENT STEP явно упоминает восстановление от 2026-10-21). Текст читаем, но кириллица местами выглядит как латиница. На работу кода не влияет.

## 9. Аварийная остановка

Если что-то идёт не так:

- `.\scripts\down.ps1` — корректная остановка с сохранением volumes.
- `.\scripts\down.ps1 -Clean` — удаляет volumes (PostgreSQL, NATS). **Необратимо.**
- Если стек в странном состоянии: `docker compose -p effectivnost-360 down --remove-orphans --volumes` (аналог `-Clean`).

## 10. Полный автоматический прогон

Если нужно выполнить **все** PASS-проверки из этой среды одной командой:

```powershell
cd C:\home\Agents\effectivnost-360

# Smoke
Invoke-WebRequest http://localhost:8000/health -UseBasicParsing
Invoke-WebRequest http://localhost:8000/ready -UseBasicParsing

# Auth + idempotency
$t = (Invoke-WebRequest http://localhost:8000/api/v1/session -Method POST -ContentType "application/json" -Body '{"email":"demo.applicant@example.invalid","password":"demo"}' -UseBasicParsing).Content | ConvertFrom-Json
$k = [guid]::NewGuid().ToString()
$b = @{text="Регрессионный запрос $k"; idempotency_key=$k} | ConvertTo-Json -Compress
$r1 = Invoke-WebRequest http://localhost:8000/api/v1/requests -Method POST -ContentType "application/json" -Headers @{Authorization="Bearer $t.token"} -Body $b -UseBasicParsing
$r2 = Invoke-WebRequest http://localhost:8000/api/v1/requests -Method POST -ContentType "application/json" -Headers @{Authorization="Bearer $t.token"} -Body $b -UseBasicParsing
"First:  $($r1.StatusCode)  $($r1.Content)"
"Replay: $($r2.StatusCode)  $($r2.Content)"

# Citation validator
python scripts/verify_fixture_citations.py --fixture database/seeds/business_trip_fixture.json
python -m unittest scripts.test_verify_fixture_citations

# JS syntax
node --check services/web/app.js

# Logs
docker logs --tail 10 effectivnost-360-outbox-relay-1
docker logs --tail 10 effectivnost-360-consumer-1
```

**PASS-критерий для всего блока:** все 8 команд завершаются без исключений; `First` = 202 с `created:true`; `Replay` = 200 с `created:false` и тем же `request_id`; validator/unit-tests = exit 0; `outbox events published` и `job succeeded` появляются в логах.
