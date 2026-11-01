# Local LLM Migration (Ollama-first)

**Статус:** принято 2026-10-23.
**Заменяет:** `docs/Architecture-Questions.md` §7 (Mellum 2.1 binding) — отмечено как SUPERSEDED.
**Автор:** autonomous implementation, reviewed по Backlog §12.2 slot 24-25.

## 1. Почему убрали Mellum-specific coupling

Изначальный план фиксировал Mellum 2.1 как конкретного провайдера. Это создавало три проблемы:

1. **Vendor coupling.** Любая правка контракта (формат ответа, заголовки, поведение при ошибках) требовала кода. Подключить альтернативный локальный LLM без правки кода было нельзя.
2. **Несовместимость с on-prem инфраструктурой организаторов.** В этой среде `MELLUM_URL` не настроен и реальных измерений нет. Любые цифры про «Mellum показывает X%» были бы выдуманными.
3. **Невозможность A/B-тестирования.** Сравнить эвристику и модель можно было только переписывая код.

Новая абстракция (`internal/localllm/Provider`) отделяет **транспорт** от **бизнес-логики**: handler не знает, какой именно бэкенд за провайдером. Это позволяет:

- Запускать тот же код с Ollama, llama.cpp server, vLLM, LocalAI или облачным провайдером;
- Подменять провайдера через одну env-переменную (`LOCAL_LLM_PROVIDER`);
- Тестировать обработчик через `httptest`-mock без настоящего LLM.

## 2. Архитектура

```
events/requests.created ──► consumer
                              │
                              ▼
                  ClassifyAndExtractHandler
                  ┌──────────────┴──────────────┐
                  ▼ primary                      ▼ fallback (только при transient)
           LLMClassifier                  HeuristicClassifier
                  │                              │
                  ▼ pii.Redact(text)             │
           localllm.Provider (Ollama | OpenAI-compat)
                  │
                  ▼ /api/chat  /v1/chat/completions
                  Ollama / llama.cpp / vLLM
```

### Provider abstraction (`internal/localllm`)

- `Provider` interface: `Name()`, `Chat(ctx, ChatRequest) (ChatResponse, error)`, `ConfigSchema()`.
- `ChatRequest`: `Model`, `Messages`, `Schema *Schema`, `Temperature`, `MaxTokens`, `KeepAlive`.
- `ChatResponse`: `Content`, `Model`, `PromptTokens`, `CompletionTokens`, `TotalTokens`, `DoneReason`.
- `Schema`: минимальный JSON Schema subset для structured output.

### Sentinel errors

| Error | Семантика | Поведение consumer |
|---|---|---|
| `ErrUnavailable` | 5xx, connection refused, network unreachable | **transient** → fallback к heuristic |
| `ErrTimeout` | request превысил `Timeout` | **transient** → fallback |
| `ErrContextCanceled` | ctx отменён вызывающим | **transient** (conservatively) |
| `ErrInvalidResponse` | 2xx, но пустой/мусорный ответ | **permanent** → manual_review |
| `ErrInvalidSchema` | 2xx, но JSON не матчит schema (400/422 или decode fail) | **permanent** → manual_review |
| `ErrModelNotFound` | 404 (модель не загружена) | **permanent** → manual_review |
| `ErrProviderFailure` | provider вернул структурный error | **permanent** → manual_review |

Consumer переключает transient/permanent через `isTransientProviderError()`. Это **сохраняет контракт** confidence-floor 0.7 из Backlog §12.2 slot 24-25.

### PII-redaction boundary (`internal/pii`)

Перед отправкой в LLM `LLMClassifier` вызывает `pii.Redact(text)`. Регексп-замены для email / phone / passport / ИНН. **Это минимальная граница**, не замена полноценной системе обезличивания. Для v0.2+ планируется выделенный PII-сервис.

Тест `TestLLMClassifier_RedactsPII` гарантирует, что email и телефон не попадают в payload провайдера.

## 3. Конфигурация

| Env | Default | Назначение |
|---|---|---|
| `LOCAL_LLM_PROVIDER` | `ollama` | `ollama` или `openai-compatible` |
| `LOCAL_LLM_BASE_URL` | (пусто) | корень HTTP API. Пусто → heuristic only |
| `LOCAL_LLM_API_KEY` | (пусто) | Bearer token (для прокси перед Ollama) |
| `LOCAL_LLM_MODEL` | `devstral-small-2:latest` | model name (передаётся в `model`) |
| `LOCAL_LLM_TIMEOUT` | `30s` | per-request timeout |
| `LOCAL_LLM_TEMPERATURE` | `0.1` | sampling temperature (рекомендуется ≤0.2 для extraction) |

Пустой `LOCAL_LLM_BASE_URL` → primary и fallback = heuristic. Это **безопасная деградация** без правки кода.

## 4. Настройка Ollama

### 4.1. Установка на хосте

```bash
# Linux/macOS: см. https://ollama.com/download
curl -fsSL https://ollama.com/install.sh | sh
# Windows: установщик с ollama.com/download
```

### 4.2. Загрузка модели (вручную, не автоматически)

> **Модель НЕ скачивается автоматически** — оператор выбирает сам. Это сознательное решение, чтобы избежать загрузки ~5–20 GB без подтверждения.

```bash
ollama pull devstral-small-2:latest
```

`devstral-small-2:latest` — это рекомендованная стартовая модель; **фактическая совместимость не проверена в этой среде** (Ollama недоступен). Если модель не отвечает на structured output — попробуйте другую (например, `qwen2.5:7b-instruct`, `mistral:7b-instruct`).

### 4.3. Запуск сервера

```bash
ollama serve  # default: http://127.0.0.1:11434
```

### 4.4. Проверка доступности

```bash
curl http://127.0.0.1:11434/api/tags
# {"models":[{"name":"devstral-small-2:latest",...}]}
```

```bash
curl http://127.0.0.1:11434/api/chat -d '{
  "model": "devstral-small-2:latest",
  "messages": [{"role":"user","content":"ping"}],
  "stream": false
}'
```

## 5. Подключение Ollama к consumer

### 5.1. Ollama на хосте (Docker Desktop / WSL2)

```env
LOCAL_LLM_BASE_URL=http://host.docker.internal:11434
LOCAL_LLM_MODEL=devstral-small-2:latest
```

### 5.2. Ollama на хосте (Linux без Docker Desktop)

Linux по умолчанию не знает `host.docker.internal`. Варианты:

```bash
# Вариант A: добавить host-gateway при запуске контейнера
docker compose run --rm -p 8000:8000 \
  --add-host=host.docker.internal:host-gateway consumer

# Вариант B: использовать host-gateway в compose.yaml
# services:
#   consumer:
#     extra_hosts:
#       - "host.docker.internal:host-gateway"
```

Затем `LOCAL_LLM_BASE_URL=http://host.docker.internal:11434`.

### 5.3. Ollama как отдельный контейнер

```yaml
# compose.yaml
services:
  ollama:
    image: ollama/ollama:latest
    volumes:
      - ollama_data:/root/.ollama
    # БЕЗ автоматической загрузки модели — оператор делает это вручную:
    #   docker compose exec ollama ollama pull devstral-small-2:latest
    restart: unless-stopped

  consumer:
    environment:
      LOCAL_LLM_BASE_URL: http://ollama:11434
    depends_on:
      ollama:
        condition: service_started

volumes:
  ollama_data:
```

### 5.4. Другая модель

Поменять только env:

```env
LOCAL_LLM_MODEL=qwen2.5:7b-instruct
```

Если модель не поддерживает `format` (JSON Schema) — Ollama вернёт 400, consumer запишет `manual_review` с `ErrInvalidSchema`. Это **не** прозрачно заменяется эвристикой — намеренно, чтобы оператор видел проблему.

## 6. Fallback

- **Primary failed transient** (5xx, connection refused, timeout) → fallback to heuristic. `Outcome.primary = "heuristic"`, `Outcome.status = "succeeded"` (если confidence ≥ 0.7) или `manual_review`.
- **Primary failed permanent** (invalid schema, model not found) → НЕ fallback. `Outcome.status = manual_review`, `Outcome.primary_error` записан.
- **Both failed** → `ErrTransient` → consumer NAK → JetStream redelivery.

Бизнес-правило `confidence < 0.7 → manual_review` (Backlog §12.2 slot 24-25) **неизменно**.

## 7. Eval

```bash
# Eval на demo-fixture, эвристика как baseline
python scripts/eval_harness.py \
  --fixture database/seeds/demo_synthetic_fixture.json \
  --dataset scripts/eval_dataset.json \
  --classifier heuristic --json

# Eval с реальным Ollama (после настройки)
python scripts/eval_harness.py \
  --fixture database/seeds/demo_synthetic_fixture.json \
  --dataset scripts/eval_dataset.json \
  --classifier live-llm --json
```

> Пока `--classifier live-llm` не реализован (требует HTTP-вызов из Python к Ollama); TODO на v0.2. Сегодня используйте `--classifier heuristic` для baseline.

## 8. Диагностика

| Симптом | Возможная причина | Что делать |
|---|---|---|
| `primary=ollama, primary_error="... model not found"` | модель не загружена | `ollama pull <model>` |
| `primary=ollama, primary_error="... timeout"` | сервер не отвечает 30s | проверить `ollama serve`, ресурсы |
| `primary=ollama, primary_error="... invalid schema"` | модель не поддерживает structured output | сменить модель или убрать `Schema` |
| `primary=heuristic, reason=...` | Ollama недоступен, сработал fallback | восстановить Ollama |
| `status=manual_review, confidence=0.4` | эвристика не уверена | проверить текст заявителя, добавить тренировочные данные |
| `ErrUnavailable: connection refused` | неверный `LOCAL_LLM_BASE_URL` | исправить URL |

## 9. Rollback

Если миграция ломает что-то — `LOCAL_LLM_BASE_URL=` (пусто) полностью отключает LLM-путь. Consumer переходит в режим эвристики без правки кода. Никакого отката коммитов не требуется.

## 10. Ресурсы и ограничения

- **VRAM/RAM**: зависит от модели. `devstral-small-2` ~7B → ~5–8 GB VRAM. Проверьте перед загрузкой.
- **Latency**: первый запрос после простоя может занять 5–30s (cold-start загрузки модели). Дальше — 0.5–5s на запрос.
- **Structured output**: не все модели поддерживают `format: <schema>`. Если модель не поддерживает — получите 400 + `ErrInvalidSchema`.
- **PII-redaction — это минимальная граница**. Настоящая система обезличивания (NER, MRZ, адреса) — отдельная задача v0.2+.

## 11. Что НЕ покрыто

- Streaming responses.
- Function calling / tool use.
- Multi-modal (vision) inputs.
- Token-budgeting и авто-failover при высокой latency.
- A/B testing framework (нужен второй `--classifier`).
- Метрики качества LLM (accuracy/recall) на реальном провайдере — сегодня есть только baseline эвристики.
