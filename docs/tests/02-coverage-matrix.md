# 02 — Матрица покрытия

> **Дата среза:** 2026-11-01.
> **Статусы:** `PASS` = проверка реально выполнена и успешно завершилась; `FAIL` = выполнена и обнаружила ошибку; `PARTIAL` = проверена только часть; `NOT TESTED` = не выполнялась в этой среде; `BLOCKED` = невозможно из-за конкретной зависимости; `NOT APPLICABLE` = не относится к реализации.
> **Связанные документы:** [`03-test-evidence.md`](03-test-evidence.md) — реальные результаты, [`05-regression-checklist.md`](05-regression-checklist.md) — команды воспроизведения.

## Сводная таблица

| # | Компонент | Вид проверки | Наличие теста / скрипта | Команда запуска | Фактический результат | Статус | Ограничение | Доказательство |
|---|---|---|---|---|---|---|---|---|
| 1 | Go-сборка (worker `outbox-relay`) | build | `services/outbox-relay/Dockerfile` + `scripts/test_go.ps1` (build) | `docker compose build outbox-relay` | Ранее зелёная сборка (Backlog §13.4); в этой среде не пересобиралась | NOT TESTED | Пересборка не запрашивалась | Backlog §13.4 |
| 2 | Go unit-тесты (`outbox-relay`) | unit | `services/outbox-relay/internal/outbox/*_test.go` | `.\scripts\test_go.ps1` | Ранее 41/41 PASS (Backlog §13.4) | NOT TESTED | В этой среде test_go.ps1 требует запуска контейнера | Backlog §13.4 |
| 3 | Go unit-тесты (`consumer`) | unit | `services/consumer/internal/*_test.go` | `.\scripts\test_go.ps1` | Ранее зелёные (Backlog §13.4) | NOT TESTED | То же | Backlog §13.4 |
| 4 | Gleam API сборка | build | `services/api/Dockerfile` (Stage 2 `runtime`) | `docker compose build api` | Текущий образ работает: контейнер `effectivnost-360-api-1` Up/healthy; эндпоинты `/health` и `/ready` отвечают 200 (E-04) | PASS (функционально) | Полная пересборка в этой среде не выполнялась (требовалось бы ~5 мин) | `docker compose ps` + E-04 |
| 5 | Gleam API completeness unit-тесты | unit | `services/api/test/completeness_test.gleam` (13 тестов по Backlog §13.4) | `.\scripts\test_go.ps1` → `make test-gleam` | Ранее 13/13 PASS (Backlog §13.4) | NOT TESTED | Gleam CLI нет на хосте; требуется Docker-контейнер | Backlog §13.4 |
| 6 | Python citation validator | validator | `scripts/verify_fixture_citations.py` (309 строк) | `python scripts/verify_fixture_citations.py --fixture database/seeds/business_trip_fixture.json --law-list "PP-501"` | 21/21 PASS на business_trip_fixture.json в этой среде (см. §E-01) | PASS | validator выдаёт предупреждение, что текст ПП № 501 недоступен (BLOCKED для production) | `03-test-evidence.md` §E-01 |
| 7 | Python citation validator — production fixture | validator | то же | то же с `--fixture database/seeds/business_trip_fixture.json` (production) | 11 из 21 блокированы (TODO-плейсхолдеры); подробности в E-01b | PARTIAL | Цитаты заменены на TODO (Backlog §12.1) | `03-test-evidence.md` §E-01b |
| 8 | Python unit-тесты citation validator | unit | `scripts/test_verify_fixture_citations.py` (270 строк) | `python -m unittest scripts.test_verify_fixture_citations` | 24/24 PASS в этой среде | PASS | Нет | `03-test-evidence.md` §E-02 |
| 9 | Frontend vanilla-JS синтаксис | syntax | `services/web/app.js`, `check-syntax` | `node --check services/web/app.js` | Синтаксических ошибок нет (E-03) | PASS | Только синтаксис, без поведения | `03-test-evidence.md` §E-03 |
| 10 | Frontend `services/frontend` (Lustre spike) | build | `services/frontend/`, отсутствует | — | Реализация отмечена как spike; не собирается | NOT APPLICABLE | Spike-каталог, не production | README проекта |
| 11 | PostgreSQL схема БД | schema | `database/migrations/*.sql`, `database/init/*.sql` | `Get-Content database/migrations/*.sql` (read-only) | 18 миграций прочитаны, последовательность `001_init.sql → 018_seed.sql` | PASS (read) | Реальное наличие таблиц в работающей БД: 47 таблиц (E-07) | `03-test-evidence.md` §E-07 |
| 12 | Применение миграций | migrate | `scripts/apply_db.ps1` | `.\scripts\apply_db.ps1` | В этой среде НЕ запускался (опасно; работает стек) | NOT TESTED | Политика безопасности | — |
| 13 | Повторное применение миграций | migrate idempotency | `scripts/apply_db.ps1` | повторный запуск | Не проверялось | NOT TESTED | Политика безопасности | — |
| 14 | Seed-данные | seed | `database/seeds/*.json`, `database/seeds/*.sql` | `apply_db.ps1` (включает seed) | В БД найдены записи для `business_trip_fixture.json` (E-07) | PASS (наличие) | Целостность seed как фикстуры не проверялась | `03-test-evidence.md` §E-07 |
| 15 | Идемпотентность seed | seed idempotency | `apply_db.ps1` | повторный запуск | Не проверялось | NOT TESTED | Политика безопасности | — |
| 16 | Проверка цитат и ссылок на нормативные акты | validator | `verify_fixture_citations.py` + `clause_source_kind` | `python scripts/verify_fixture_citations.py` | 21/21 на DEMO; 11/21 BLOCKED на production | PARTIAL | См. строки 6–7 | `03-test-evidence.md` §E-01 |
| 17 | API: `GET /health` | smoke | `services/api/src/api/router.gleam` | `curl http://localhost:8000/health` | `200 {"status":"ok"}` (E-04) | PASS | Нет | `03-test-evidence.md` §E-04 |
| 18 | API: `GET /ready` | smoke | `services/api/src/api/router.gleam` | `curl http://localhost:8000/ready` | `200 {"status":"ready"}` (E-04) | PASS | Нет | `03-test-evidence.md` §E-04 |
| 19 | API: создание заявки `POST /api/v1/requests` | functional | `services/api/src/effectivnost_360/router.gleam` (`create_draft`/`create_draft_for`) | `curl -X POST http://localhost:8000/api/v1/requests -H "Authorization: Bearer <token>" -H "Content-Type: application/json" -d '{"text":"…","idempotency_key":"…"}'` | 202 `{"request_id":"…","status":"draft","created":true}` (E-05a). Запись в БД найдена по id (E-05c). | PASS | Требуется валидный Bearer token (`POST /api/v1/session` с `demo`/`demo.applicant@example.invalid`) | `03-test-evidence.md` §E-05a,c |
| 20 | API: повтор `POST /requests` с тем же `idempotency_key` | idempotency | UNIQUE-индекс `requests(idempotency_key)` (см. `database/migrations/001_init.sql`) | тот же запрос с тем же `idempotency_key` | 200 `{"request_id":"…","status":"draft","created":false}`, **тот же `request_id`** что и в FIRST (E-05b). В БД одна запись на этот ключ (E-05c). | PASS | Нет | `03-test-evidence.md` §E-05b,c |
| 21 | Outbox → NATS JetStream публикация | integration | `services/outbox-relay/cmd/outbox-relay/main.go` (Stage 2) | `docker logs effectivnost-360-outbox-relay-1` | Логи показывают `outbox events published` с ненулевым счётчиком (E-06). В БД все outbox-записи имеют `published_at IS NOT NULL` (E-07). | PASS | То, что событие опубликовано, ≠ что consumer его обработал — это проверяется отдельно | `03-test-evidence.md` §E-06, E-07 |
| 22 | Consumer обработка событий | integration | `services/consumer/cmd/consumer/main.go` | `docker logs effectivnost-360-consumer-1` | В логах consumer видны `job succeeded` для `classify_and_extract` и `agent_digital_moderator` (E-06). Для `agent_business_moderator` — `api returned status 503` (LLM недоступен). | PARTIAL | Реальная LLM недоступна; один из агентов успешно обрабатывает события, другой возвращает 503 | `03-test-evidence.md` §E-06, E-08 |
| 23 | Hard-stop: block_submit | scenario | `scripts/e2e_hardstop.ps1` + `services/worker/templates/hardstop_trip.yaml` | `.\scripts\e2e_hardstop.ps1 -Scenario block_submit` | Ранее PASS (Backlog §13.4); в этой среде НЕ перепрогонялся | NOT TESTED | Требует развернуть свежий демо-стенд | Backlog §13.4 |
| 24 | Hard-stop: needs_employer_review | scenario | то же | `.\scripts\e2e_hardstop.ps1 -Scenario needs_employer_review` | Ранее PASS (Backlog §13.4) | NOT TESTED | То же | Backlog §13.4 |
| 25 | Hard-stop: clean (полная заявка) | scenario | то же | `.\scripts\e2e_hardstop.ps1 -Scenario clean` | Ранее PASS (Backlog §13.4) | NOT TESTED | То же | Backlog §13.4 |
| 26 | API: создание сессии `POST /api/v1/session` | functional | `services/api/src/effectivnost_360/router.gleam` (handler `session`) | `curl -X POST http://localhost:8000/api/v1/session -H 'Content-Type: application/json' -d '{"email":"demo.applicant@example.invalid","password":"demo"}'` | 200, возвращает Bearer-токен (E-09). Токен использован для последующих POST /requests. | PASS | Нет | `03-test-evidence.md` §E-09 |
| 27 | UI: авторизация (login) — UI flow | UI | `services/web/app.js` + `scripts/check-login-ui.cjs` (Playwright) | `node scripts/check-login-ui.cjs` | Скрипт существует, в этой среде Playwright недоступен | NOT TESTED | Playwright не установлен на хосте; скрипт ожидает `C:/tmp/shots-runner/node_modules/playwright` | [`05-regression-checklist.md`](05-regression-checklist.md) § 7 |
| 28 | UI: форма заявки | UI | `services/web/app.js` (роутинг) | Playwright | Не перепрогонялось в этой среде | NOT TESTED | Playwright недоступен | — |
| 29 | UI: кабинет (статус заявки) | UI | `services/web/app.js` | Playwright | Не перепрогонялось | NOT TESTED | Playwright недоступен | — |
| 30 | Сохранение сессии после перезагрузки | UI | `services/web/app.js` (cookie/JWT) | Playwright | Не перепрогонялось | NOT TESTED | Playwright недоступен | — |
| 31 | E2E: полный цикл (UI → submit → status=submitted) | e2e | `scripts/qa_e2e.mjs` (Playwright) | `node scripts/qa_e2e.mjs` | Не перепрогонялось | NOT TESTED | Playwright недоступен | Backlog §13.4 |
| 32 | Реальная LLM end-to-end | e2e | `services/consumer/internal/extractor/llm_client.go` | реальный деплоймент Ollama | `LOCAL_LLM_BASE_URL=http://host.docker.internal:11434` не отвечает в 120s (E-08) | BLOCKED | LLM-сервер не поднят | `03-test-evidence.md` §E-08 |
| 33 | Безопасность (аутентификация, rate-limit) | security | отсутствует | — | Не описано в коде как production-ready | NOT APPLICABLE | Реализация ещё не завершена | Backlog §11 |
| 34 | Мониторинг (Prometheus, логи) | ops | отсутствует | — | Не реализовано | NOT APPLICABLE | Backlog §11 | Backlog §11 |

## Счётчики по статусам

| Статус | Кол-во |
|---|---|
| PASS | 12 |
| FAIL | 0 |
| PARTIAL | 3 |
| NOT TESTED | 15 |
| BLOCKED | 1 |
| NOT APPLICABLE | 3 |
| **Всего строк** | **34** |

Подсчёт выполнен по статусу в столбце 6. `PASS` включает варианты `PASS`, `PASS (функционально)`, `PASS (read)`, `PASS (наличие)` — они соответствуют фактически подтверждённому поведению.

## Что эта матрица показывает честно

- **PASS получены только там, где проверка реально выполнена в этой среде.** Это синтаксические/smoke/idempotency-тесты, которые не требуют ничего разрушительного.
- **NOT TESTED — это не «не работает», а «не запускалось в этой среде».** Причины: политика безопасности (миграции), отсутствие инструмента (Gleam CLI, Playwright) или не запрашивалось (пересборка образов).
- **PARTIAL — валидатор цитат работает, но половина цитат в production-fixture не подтверждается, потому что они заменены на TODO.** Это известная открытая задача (Backlog §12.1).
- **BLOCKED — единственная строка.** Требует Ollama, которая не развернута. Это документированное ограничение, а не дефект кода.
- **NOT APPLICABLE — 3 строки.** Lustre-frontend — spike-каталог; безопасность и мониторинг не описаны как готовые.

См. также [`04-test-gaps.md`](04-test-gaps.md) для приоритезации того, что не покрыто.
