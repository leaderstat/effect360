# scripts/Makefile — единая точка входа для Docker-only стенда.
#
# Все команды здесь — обёртки над `docker compose …`. Никакие `gleam`,
# `go`, `python`, `node`, `npm`, `rebar3` или `psql` не должны вызываться
# напрямую из PowerShell — только через эти цели.
#
# Соглашения:
#   make help           — список доступных команд.
#   make up             — поднять dev-стенд.
#   make test-*         — запустить проверки внутри контейнеров.
#   make e2e            — прогнать Playwright E2E.
#   make clean-data     — удалить данные PostgreSQL/NATS (ТОЛЬКО dev).
#
# Переменные окружения (можно переопределить):
#   PROJECT   имя Compose-проекта (по умолчанию effectivnost360).
#   API_URL   URL API для smoke-checks (по умолчанию http://localhost:8000).

.DEFAULT_GOAL := help
PROJECT ?= effectivnost360
API_URL ?= http://localhost:8000
FIXTURE ?= database/seeds/demo_synthetic_fixture.json

POWERSHELL := powershell -NoProfile -ExecutionPolicy Bypass

help:
	@echo "=== Docker-only стенд 'Эффективность 360' ==="
	@echo ""
	@echo "  make up                 — поднять dev-стенд (api, web, workers, db)"
	@echo "  make up-build           — пересобрать образы и поднять"
	@echo "  make up-fresh           — удалить volumes и поднять с нуля"
	@echo "  make down               — остановить стенд (данные сохраняются)"
	@echo "  make down-clean         — остановить и удалить volumes"
	@echo "  make status             — статус сервисов и healthchecks"
	@echo "  make logs               — логи api (по умолчанию)"
	@echo "  make logs-<svc>         — логи конкретного сервиса (api,postgres,nats,outbox-relay,consumer,web)"
	@echo ""
	@echo "  make build              — собрать все образы (api, workers, tooling)"
	@echo "  make build-frontend     — собрать Lustre-фронтенд (spike)"
	@echo "  make up-frontend        — поднять Lustre-фронтенд на :8051 (profile=spike)"
	@echo ""
	@echo "  make test               — все тесты подряд (gleam+go+python+js+citation)"
	@echo "  make test-gleam         — gleam test внутри api builder"
	@echo "  make test-go            — go test внутри worker build"
	@echo "  make test-fixture       — citation validator на DEMO fixture"
	@echo "  make test-js            — node --check на app.js и qa_e2e.mjs"
	@echo "  make eval               — Python eval harness на heuristic"
	@echo ""
	@echo "  make smoke              — curl/smoke-проверки API"
	@echo "  make e2e                — Playwright E2E через tooling образ"
	@echo ""
	@echo "  make clean-data         — удалить dev-данные (POSTGRES, NATS, frontend_dist)"
	@echo ""
	@echo "Переменные: PROJECT=$(PROJECT)  API_URL=$(API_URL)  FIXTURE=$(FIXTURE)"

# ---- Stack lifecycle ----
up:
	$(POWERSHELL) -File scripts\up.ps1 -Project $(PROJECT)

up-build:
	$(POWERSHELL) -File scripts\up.ps1 -Project $(PROJECT) -Build

up-fresh:
	$(POWERSHELL) -File scripts\up.ps1 -Project $(PROJECT) -Fresh

down:
	$(POWERSHELL) -File scripts\down.ps1 -Project $(PROJECT)

down-clean:
	$(POWERSHELL) -File scripts\down.ps1 -Project $(PROJECT) -Clean

status:
	docker compose -p $(PROJECT) ps
	@echo ""
	@echo "--- healthchecks ---"
	@docker compose -p $(PROJECT) ps --format json 2>nul | findstr /i "Health" || echo "(no healthchecks reported)"

logs:
	$(POWERSHELL) -File scripts\logs.ps1 -Service api -Tail 100 -Project $(PROJECT)

logs-api:
	$(POWERSHELL) -File scripts\logs.ps1 -Service api -Project $(PROJECT)

logs-postgres:
	$(POWERSHELL) -File scripts\logs.ps1 -Service postgres -Project $(PROJECT)

logs-nats:
	$(POWERSHELL) -File scripts\logs.ps1 -Service nats -Project $(PROJECT)

logs-relay:
	$(POWERSHELL) -File scripts\logs.ps1 -Service outbox-relay -Project $(PROJECT)

logs-consumer:
	$(POWERSHELL) -File scripts\logs.ps1 -Service consumer -Project $(PROJECT)

logs-web:
	$(POWERSHELL) -File scripts\logs.ps1 -Service web -Project $(PROJECT)

# ---- Builds ----
build:
	docker compose -p $(PROJECT) build api outbox-relay consumer tooling

build-frontend:
	docker compose -p $(PROJECT) build frontend-builder
	@echo "[make] frontend bundle available in volume '$(PROJECT)_frontend_dist'"

up-frontend:
	docker compose -p $(PROJECT) --profile spike up -d frontend frontend-builder

# ---- Tests (all run inside containers) ----
test: test-gleam test-go test-fixture test-js
	@echo "[make] all tests OK"

test-gleam:
	@echo "[make] >>> gleam test (Stage 1 of services/api/Dockerfile)"
	@docker build --target build --quiet services/api -t effectivnost360/api-builder:test >nul
	docker run --rm effectivnost360/api-builder:test gleam test

test-go:
	@echo "[make] >>> go test (services/worker)"
	$(POWERSHELL) -File scripts\test_go.ps1

test-fixture:
	@echo "[make] >>> citation validator"
	$(POWERSHELL) -File scripts\test_fixture.ps1 -Fixture $(FIXTURE)

test-js:
	@echo "[make] >>> JS syntax check"
	$(POWERSHELL) -File scripts\test_js.ps1

eval:
	@echo "[make] >>> eval harness (heuristic)"
	$(POWERSHELL) -File scripts\eval.ps1

# ---- Smoke & E2E ----
smoke:
	$(POWERSHELL) -File scripts\smoke_checks.ps1 -ApiUrl $(API_URL)

e2e:
	@echo "[make] >>> Playwright E2E via tooling image"
	$(POWERSHELL) -File scripts\e2e.ps1

# ---- Cleanup ----
clean-data:
	@echo "[make] !!! removing dev data (PostgreSQL/NATS/frontend_dist volumes)"
	@docker compose -p $(PROJECT) down --remove-orphans --volumes
	@if exist .compose-project del .compose-project

.PHONY: help up up-build up-fresh down down-clean status logs logs-api logs-postgres logs-nats logs-relay logs-consumer logs-web \
        build build-frontend up-frontend \
        test test-gleam test-go test-fixture test-js eval \
        smoke e2e clean-data
