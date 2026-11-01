# DEV_DOCKER.md — Docker-only dev стенд «Эффективность 360»

> Документ фиксирует правило: **все** языковые toolchain'ы проекта (Gleam,
> Erlang/OTP, rebar3, Go, Node.js, Python, Playwright) запускаются
> **внутри Docker-контейнеров**. На Windows-хост не устанавливается ничего,
> кроме Docker Desktop.

---

## 1. Prerequisites

| Компонент | Назначение | Где взять |
|---|---|---|
| Docker Desktop (Windows, WSL 2 backend) | контейнерный рантайм | https://www.docker.com/products/docker-desktop/ |
| Git for Windows | клонирование репозитория | https://git-scm.com/download/win |
| PowerShell 5.1+ | запуск `.ps1` скриптов | встроен в Windows 10/11 |

**Не требуется** (и запрещено ставить для целей проекта): Gleam, Erlang/OTP,
rebar3, Go, Node.js, npm, Python, PostgreSQL client, Ollama. Если эти
программы уже стоят на хосте — они **не должны** вызываться скриптами
проекта; для проекта используются их контейнерные аналоги.

WSL 2 backend в Docker Desktop обязателен: bind mounts на Windows работают
надёжнее через WSL, чем через legacy Hyper-V backend.

---

## 2. Архитектура стенда

Один канонический файл `compose.yaml` в корне репозитория. Все сервисы:

```
┌────────────┐  ┌────────────┐  ┌──────────────┐  ┌─────────────┐
│  postgres  │  │    nats    │  │     api      │  │     web     │
│ 16-alpine  │  │ 2.11-js    │  │ (Gleam+OTP)  │  │  nginx 1.27 │
│ :5432      │  │  :4222     │  │  :8000       │  │   :8050     │
└────────────┘  └────────────┘  └──────────────┘  └─────────────┘
                                        ▲
                                        │ NATS
                                        ▼
                                ┌─────────────────┐
                                │ outbox-relay    │ ── публикует в NATS
                                │ consumer        │ ── обрабатывает
                                │ (Go 1.26)       │
                                └─────────────────┘

Profiles:
  dev       → tooling      (Python+Node+Playwright shell)
  build-only → frontend-builder   (Lustre build → JS bundle)
  spike     → frontend     (Lustre spike на :8051)
  qa        → qa           (validator + Playwright headless run)
```

**Healthchecks:** postgres (`pg_isready`), nats (`/healthz`), api (`/ready`).
Сервисы стартуют в правильном порядке благодаря `depends_on:
condition: service_healthy`.

**Volumes:**
- `postgres_data` — данные PostgreSQL переживают рестарт.
- `nats_data` — JetStream state переживает рестарт.
- `frontend_dist` — собранный Lustre-bundle (создаётся `frontend-builder`).

---

## 3. Команды

Все команды выполняются из корня репозитория в PowerShell.

### 3.1. Стек жизненного цикла

```powershell
make help                  # список всех доступных команд
make up                    # поднять dev-стенд (api, web, workers, db)
make up-build              # пересобрать образы и поднять
make up-fresh              # удалить volumes и поднять с нуля
make down                  # остановить стенд (данные сохраняются)
make down-clean            # остановить и удалить volumes
make status                # статус сервисов и healthchecks
make logs                  # логи api (по умолчанию)
make logs-postgres         # логи postgres
make logs-nats             # логи nats
make logs-relay            # логи outbox-relay
make logs-consumer         # логи consumer
make logs-web              # логи web
```

Прямые эквиваленты через `docker compose`:

```powershell
docker compose -p effectivnost360 up -d
docker compose -p effectivnost360 ps
docker compose -p effectivnost360 logs --tail=100 api
docker compose -p effectivnost360 down --remove-orphans
```

### 3.2. Сборка

```powershell
make build                 # api, outbox-relay, consumer, tooling
make build-frontend        # Lustre spike bundle (services/frontend)
make up-frontend           # поднять Lustre-spike на :8051 (profile=spike)
```

### 3.3. Тесты (все в контейнерах)

```powershell
make test                  # все тесты подряд: gleam + go + fixture + js
make test-gleam            # gleam test внутри builder-образа api
make test-go               # go test в golang:1.26-alpine
make test-fixture          # citation validator на DEMO fixture
make test-js               # node --check на app.js и qa_e2e.mjs
make eval                  # Python eval harness на heuristic
```

Целевой fixture переопределяется:

```powershell
make test-fixture FIXTURE=database/seeds/business_trip_fixture.json
```

### 3.4. Smoke & E2E

```powershell
make smoke                 # curl/smoke проверки API (GET /health, /ready, POST /api/v1/requests, idempotency)
make e2e                   # Playwright E2E через tooling контейнер
```

`make e2e` автоматически подключается к сети `effectivnost360_default` и
вызывает scripts/qa_e2e.mjs с `WEB_BASE_URL=http://web:8050`.

### 3.5. Cleanup

```powershell
make clean-data            # удалить все dev-данные (PostgreSQL, NATS, frontend_dist)
```

**`clean-data` необратим.** Подтверждение запрашивается только через явный
запуск цели — никаких неявных авто-cleanup'ов.

### 3.6. Переменные окружения

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `PROJECT` | имя Compose-проекта | `effectivnost360` |
| `API_URL` | URL API для smoke | `http://localhost:8000` |
| `FIXTURE` | путь к fixture для validator | `database/seeds/demo_synthetic_fixture.json` |
| `DEV_ALLOWED_ORIGINS` | CORS allow-list (через `.env`) | `http://localhost:8050,http://localhost:8000` |

Все эти значения редактируются и в `.env` (для сервисов) и в командной
строке (для скриптов).

---

## 4. Локальные URL'ы

| URL | Сервис | Описание |
|---|---|---|
| http://localhost:8000/health | api | health probe |
| http://localhost:8000/ready | api | readiness (БД доступна) |
| http://localhost:8000/api/v1/requests | api | POST/GET черновик |
| http://localhost:8000/api/v1/requests/{id} | api | GET детали заявки |
| http://localhost:8000/api/v1/requests/{id}/submit | api | POST отправка |
| http://localhost:8050 | web (vanilla JS UI) | текущий интерфейс заявителя |
| http://localhost:8051 | frontend (Lustre spike, profile=spike) | spike-интерфейс |
| http://localhost:5432 | postgres | БД (только dev!) |
| http://localhost:8222 | nats | NATS monitoring (внутри сети) |

---

## 5. Диагностика

### 5.1. Сервис не становится healthy

```powershell
make status
make logs-api           # или logs-postgres / logs-nats
```

Типичные причины:
- postgres не запустился: проверить `POSTGRES_PASSWORD` в `.env`.
- api не проходит `/ready`: БД ещё не мигрировала; подождать 10–20 c.
- consumer падает: проверить `LOCAL_LLM_BASE_URL` (если пусто — это OK,
  consumer работает в heuristic-режиме).

### 5.2. Тесты не запускаются в контейнере

```powershell
docker images | findstr effectivnost360
```

Если образа нет — выполнить `make build`. Если ошибка сборки — выполнить
`docker compose -p effectivnost360 build --no-cache <service>` и прочитать
stderr.

### 5.3. Очистить зависший стенд

```powershell
make down-clean
docker system prune --volumes -f    # !!! удаляет ВСЕ неиспользуемые volumes
```

### 5.4. Пересобрать только один сервис

```powershell
docker compose -p effectivnost360 build --no-cache api
docker compose -p effectivnost360 up -d --force-recreate api
```

### 5.5. Подключиться к БД из контейнера

```powershell
docker compose -p effectivnost360 exec postgres psql -U effectivnost360 -d effectivnost360
```

### 5.6. Подключиться к NATS

```powershell
docker compose -p effectivnost360 exec nats nats sub 'requests.*'
```

---

## 6. Особенности Windows

### 6.1. Bind mounts на Windows

Docker Desktop с WSL 2 backend монтирует файлы через 9P — это медленнее,
чем нативная FS Linux. Не используйте `services/web/` bind mount для
production-нагрузки, но для разработки это нормально.

### 6.2. Проброс Ollama с хоста

`consumer` обращается к Ollama через `http://host.docker.internal:11434`.
Docker Desktop на Windows автоматически резолвит `host.docker.internal`
в хост. Если это не работает — выполните:

```powershell
docker run --rm --add-host=host.docker.internal:host-gateway alpine wget -q -O- http://host.docker.internal:11434/api/tags
```

### 6.3. Volume-персистенция между запусками

Именованные volumes (`postgres_data`, `nats_data`, `frontend_dist`) живут
в Docker Desktop VM. Они сохраняются между `make down` и `make up`, но
**удаляются** через `make down-clean` или `make clean-data`.

### 6.4. CRLF vs LF

PowerShell пишет файлы в CRLF. Скрипты `.ps1` совместимы с обоими
окончаниями; внутри compose-контейнеров используется LF — это не влияет
на работу, но коммит-хуки могут ругаться. Проверьте `.gitattributes`:

```
*.sh   text eol=lf
*.ps1  text eol=crlf
*.gleam text eol=lf
```

### 6.5. Тайм-ауты healthcheck

Windows-хост может быть медленным при первом старте контейнеров. Если
`depends_on: condition: service_healthy` отваливается по тайм-ауту —
увеличьте `retries` в healthcheck (по умолчанию 10, можно поднять до 30).

---

## 7. Что НЕ сделано

- **Production HTTPS / Caddy** — задача вне P0. См. docs/Backlog §12.5.
- **Production secrets management** — Vault / SOPS — out of scope.
- **Horizontal scaling** — single-replica; multi-replica — задача v0.2+.
- **Multi-stage build для worker** — `go test` не выполняется внутри
  build-стадии; см. Этап 6 отчёта.
- **Lustre spike вне profile=spike** — для spike-режима нужно явно
  поднять через `make up-frontend`.

---

## 8. Известные ограничения

1. **`apt-key` и `gnupg` отсутствуют** в `mcr.microsoft.com/playwright`
   image — для подписи apt-репозиториев это не нужно, но если потребуется
   apt-add-repository, добавьте шаг установки.
2. **`host.docker.internal`** на Linux требует
   `--add-host=host.docker.internal:host-gateway`; на Windows работает
   «из коробки».
3. **`tools.gleam-lang.org`** скачивается через HTTPS внутри build-стадии;
   если хост за файрволом — нужно предварительно положить tarball в
   локальный registry/proxy.

---

## 9. Аварийный rollback

Если что-то пошло совсем не так и compose не поднимается:

```powershell
make down-clean
docker system prune -f
docker volume prune -f
git checkout compose.yaml scripts/ services/api/Dockerfile services/worker/Dockerfile tooling/
make up-build
```

Восстановление займёт 5–10 минут на холодный build всех образов.
