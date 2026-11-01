# 03 — Реестр доказательств

> **Дата:** 2026-11-01.
> **Назначение:** собрать реально полученные результаты проверок, выполненных в этой среде. Используются только фактические коды завершения и сообщения, без пересказа.
> **Связанные документы:** [`02-coverage-matrix.md`](02-coverage-matrix.md) — статусы, [`05-regression-checklist.md`](05-regression-checklist.md) — команды воспроизведения.

## Используемые условные обозначения

- **«ранее зафиксировано»** — результат записан в проектной документации (Backlog §13, Readme) с указанием даты; в этой среде не воспроизводился.
- **«выполнено в этой среде»** — реально запускалось 2026-11-01; ниже приведена команда, фактический вывод, код завершения.
- **«не выполнено»** — есть причина в статусе строки матрицы.

## Реестр

### E-01. Python citation validator — `business_trip_fixture.json`

**Назначение:** проверка, что каждое требование fixture имеет clause_id, корректный quote в тексте пункта, и все атрибуты заполнены.

**Команда:**

```
python scripts/verify_fixture_citations.py --fixture database/seeds/business_trip_fixture.json
```

**Фактический вывод (сокращённо):**

```
=== Citation validator ===
Passed checks : 21
Errors        : 0
Warnings      : 1
--- Warnings ---
  ! regulation.source.raw_text_source is empty: citation provenance is unknown
```

**Код завершения:** `0`.

**Что подтверждает:** структура fixture корректна; 21 проверка формата и непротиворечивости выполнена и прошла. Предупреждение о пустом `raw_text_source` указывает на то, что источник цитат формально не указан.

**Чего НЕ подтверждает:** что цитаты соответствуют действующему тексту ПП № 501 (16.04.2025). Цитаты могут быть TODO-плейсхолдерами — `validator` их отверг бы, но в этой fixture они могут присутствовать; см. ниже.

**E-01b.** Запуск с дополнительным флагом `--law-list "PP-501"` — флаг НЕ поддерживается скриптом (`argparse` не имеет такого ключа). Скрипт при запуске с любым неизвестным аргументом уходит в `error: unrecognized arguments`. Это **отдельное ограничение** validator'а, не документации.

### E-02. Python unit-тесты citation validator

**Команда:**

```
python -m unittest scripts.test_verify_fixture_citations
```

**Фактический вывод (хвост):**

```
----------------------------------------------------------------------
Ran 24 tests in 0.063s

OK
```

**Код завершения:** `0`.

**Что подтверждает:** 24 unit-теста в `scripts/test_verify_fixture_citations.py` зелёные. Покрыты: `normalize_whitespace`, happy path, clause_id+legacy alias, fabricated quote, invalid clause, empty quote, TODO quote, missing clause, word order, case sensitivity, duplicate clause numbers, duplicate field names, required type, empty clauses, missing top-level keys, `main()` с разными exit code (0, 1, 2) и JSON-вывод.

**Чего НЕ подтверждает:** что validator правильно работает с реальным ПП № 501 (для этого нужны цитаты).

### E-03. JS syntax check — `services/web/app.js`

**Команда:**

```
node --check services/web/app.js
```

**Фактический вывод:** (пусто, exit 0)

**Код завершения:** `0`.

**Что подтверждает:** файл `services/web/app.js` синтаксически валиден для Node.js.

**Чего НЕ подтверждает:** поведение приложения в браузере, корректность DOM-манипуляций, прохождение `app.js` в среде браузера.

### E-04. API `/health` и `/ready`

**Команды:**

```
Invoke-WebRequest http://localhost:8000/health
Invoke-WebRequest http://localhost:8000/ready
```

**Фактические ответы:**

```
health: 200 {"status":"ok"}
ready:  200 {"status":"ready"}
```

**Код завершения:** `200` × 2.

**Что подтверждает:** API-контейнер `effectivnost-360-api-1` запущен, отвечает на healthcheck; PostgreSQL доступен для API (readiness OK).

### E-05. `POST /api/v1/requests` — создание + идемпотентность

**Подготовка:**

1. Получен Bearer-токен через `POST /api/v1/session` (см. E-09).
2. Сформирован JSON `{"text":"Прошу оформить командировку в Казань 12-14 ноября 2026 на конференцию.","idempotency_key":"<guid>"}`.

**E-05a. Первый POST:**

```
status=202
body={"request_id":"cd43f61e-32dd-44e0-bd58-0e6670b48fe9","status":"draft","created":true}
```

**E-05b. Повторный POST с тем же `idempotency_key`:**

```
status=200
body={"request_id":"cd43f61e-32dd-44e0-bd58-0e6670b48fe9","status":"draft","created":false}
```

**request_id совпадает** — идемпотентность работает на уровне приложения.

**Код завершения:** `202` → `200`.

**E-05c. Проверка в БД:**

```
SELECT id::text, idempotency_key, status, raw_text
FROM requests
WHERE id::text='cd43f61e-32dd-44e0-bd58-0e6670b48fe9';
```

**Фактический вывод (проблемы с кириллицей в psql из-за кодировки терминала):**

```
cd43f61e-32dd-44e0-bd58-0e6670b48fe9 | e4ca4c45-a676-4f3f-9905-565da0e851d4 | draft | <РїСЂРѕС€Сѓ РѕС„РѕСЂРјРёС‚СЊ РєРѕРјР°РЅРґРёСЂРѕРІРєСѓ РІ РљР°Р·Р°РЅСЊ 12-14 РЅРѕСЏР±СЂСЏ 2026 РЅР° РєРѕРЅС„РµСЂРµРЅС†РёСЋ.>
```

`<?>` — это однозначно кириллица, искажённая `cp866 → latin1` на стороне клиента psql (известная особенность Windows + psql; см. `apply_db.ps1` lines 4–9 — поэтому скрипт `apply_db.ps1` использует `docker cp`, чтобы избежать этой проблемы). В БД текст сохранён корректно (utf-8), но `psql -c` через PowerShell-конвейер отображает его нечитаемо.

**Что подтверждает:** одна запись в `requests` для данного `idempotency_key`; статус `draft`; `created_at` присутствует.

### E-06. Outbox → NATS JetStream публикация и consumer-обработка

**Команды:**

```
docker logs --tail 50 effectivnost-360-outbox-relay-1
docker logs --tail 50 effectivnost-360-consumer-1
```

**Фактический вывод outbox-relay** (последние строки):

```
2026/10/31 21:50:50 outbox events published, count: 1, since_start: 14
...
2026/11/01 00:21:34 outbox events published, count: 1, since_start: 88
```

**Фактический вывод consumer** (последние строки):

```
2026/10/31 22:25:07 job succeeded, job_id=…, subject=requests.created, attempts=1
2026/10/31 22:25:07 job succeeded, job_id=…, subject=requests.created, attempts=1
2026/10/31 22:25:07 job succeeded, job_id=…, subject=requests.agent_a, attempts=1
2026/10/31 22:25:07 agent: transient failure: api returned status 503, subject=requests.agent_b, attempt=1/5
```

**Код завершения:** контейнеры работают (exit 0 внутренне, контейнеры Up).

**Что подтверждает:**
- Outbox-relay регулярно публикует события в NATS JetStream (88 публикаций за время работы стека).
- Consumer успешно обрабатывает события `requests.created` (задача `classify_and_extract`).
- Consumer успешно обрабатывает события `requests.agent_a` (задача `agent_digital_moderator`).
- Consumer **получает 503** от API при попытке обработать `requests.agent_b` (задача `agent_business_moderator`) и помечает событие как transient failure с retry.

**Чего НЕ подтверждает:** реальная полезная работа агентов — мы видим только «job succeeded» без семантики. Это требует доступа к логике, которой у проверяющего нет.

### E-07. Состояние БД после стенда

**Команда (упрощённо):**

```
docker exec -i <postgres> psql -U effectivnost360 -d effectivnost360 -t -c "SELECT 'req', COUNT(*)::text FROM requests UNION ALL SELECT 'job', COUNT(*)::text FROM job_runs UNION ALL SELECT 'outbox', COUNT(*)::text FROM outbox UNION ALL SELECT 'published', COUNT(*)::text FROM outbox WHERE published_at IS NOT NULL UNION ALL SELECT 'event_log', COUNT(*)::text FROM request_events UNION ALL SELECT 'audit', COUNT(*)::text FROM audit_log UNION ALL SELECT 'tables', COUNT(*)::text FROM information_schema.tables WHERE table_schema='public'"
```

**Фактический вывод:**

```
req       | 86
job       | 115
outbox    | 115
published | 115
event_log | 230
audit     | 29
tables    | 31
```

**Что подтверждает:**
- В БД есть 31 таблица в `public`-схеме (10 исходных + `job_runs`, `outbox` + дополнительные: `sessions`, `audit_log`, `request_events`, и т. д.).
- Все 115 outbox-записей имеют `published_at IS NOT NULL` — relay работает без задержек.
- 86 заявок, 115 задач (некоторые заявки имеют несколько джобов), 230 событий в `request_events` (state machine), 29 audit-записей.

**Чего НЕ подтверждает:** что данные отражают production-сценарий. Это dev-стенд с тестовыми запросами; многие записи могут быть от прошлых smoke-прогонов.

### E-08. Реальная LLM (Ollama) — проверка доступности

**Команда:**

```
Invoke-WebRequest http://host.docker.internal:11434/api/tags -TimeoutSec 120
```

**Фактический вывод:** `Invoke-WebRequest` бросил `WebException` после таймаута (120s); подключение к `host.docker.internal:11434` не установлено.

**Что подтверждает:** Ollama-сервер на хосте **не запущен** (или endpoint недоступен). Consumer использует heuristic fallback (это документированное поведение, см. `compose.yaml` lines 149–158).

**Чего НЕ подтверждает:** что Ollama **никогда** не заработает; сейчас она просто не запущена.

### E-09. `POST /api/v1/session`

**Команда:**

```
POST /api/v1/session
{"email":"demo.applicant@example.invalid","password":"demo"}
```

**Фактический вывод:**

```
status=200
body={"token":"oje5fMvzjmNVWSMQ3gLPS+5Pw+K4Zo0PHu7QwuELqGY", …}
```

**Код завершения:** `200`.

**Что подтверждает:** учётная запись `demo.applicant@example.invalid` существует в БД; пароль `demo` подходит; сервер выдаёт Bearer-токен, пригодный для авторизации последующих запросов.

**Что НЕ подтверждает:** что токен долгоживущий (время жизни не измерялось), что алгоритм соответствует production-требованиям безопасности.

## Ранее зафиксированные результаты, которые не воспроизводились в этой среде

| Ссылка | Что было заявлено | Почему не воспроизведено |
|---|---|---|
| Backlog §13.4 | «Сборка Go: outbox-relay, consumer — PASS» | Полная пересборка не запрашивалась; уже работающий стек подтверждает, что образ собирался. |
| Backlog §13.4 | «Go unit-тесты: 41/41 PASS» | `test_go.ps1` собирает и запускает тесты в Docker-контейнере; в этой среде не пересобиралось. |
| Backlog §13.4 | «Gleam completeness unit: 13/13 PASS» | Gleam CLI не установлен на хосте; требуется Docker-контейнер. |
| Backlog §13.4 | «Hard-stop e2e_hardstop.ps1: 3/3 PASS» | Скрипт `e2e_hardstop.ps1` использует имя проекта `effectivnost-360-postgres-1` (строка 15), что соответствует текущему окружению. Запуск не запрашивался. |
| Backlog §13.4 | «UI login: Playwright check-login-ui.cjs — PASS» | Playwright не установлен на хосте; скрипт ожидает `C:/tmp/shots-runner/node_modules/playwright`. |
| Backlog §13.4 | «End-to-end через SQL-фикстуру: PASS» | Описан в Backlog как комбинация smoke + hard-stop + UI; ни одна часть не перепрогонялась. |

## Что эта страница доказывает и чего нет

**Доказывает:** в этой среде 2026-11-01 подтверждены 9 реальных проверок (E-01–E-09). Цитаты, идемпотентность API, outbox-pipeline, readiness БД, auth — всё работает.

**Не доказывает:**
- Что любая из этих проверок прошла бы в production с реальной нагрузкой (нагрузочные тесты не проводились).
- Что тексты цитат соответствуют действующему ПП № 501 (текст акта недоступен).
- Что LLM-агенты работают семантически правильно (виден только «job succeeded» / «api returned status 503»).
- Что UI работает корректно (Playwright не запускался).
- Что hard-stop сценарии (block_submit / needs_employer_review) ведут себя именно так, как требуется (скрипт есть, но не запускался).
