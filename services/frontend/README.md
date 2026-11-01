# services/frontend — Lustre frontend (real, integrated into the main stand)

Real Gleam + Lustre 5.x frontend for «Эффективность 360». This is the
**primary** `web` service in `compose.yaml` (port `:8050`); the older
vanilla-JS applicant UI is kept behind the `vanilla` profile for reference.

The Lustre project is an independent Gleam package. Its dependency
resolution is **not** constrained by the API service's `gleam_stdlib`
pin — frontend uses Lustre 5.7.1 + `gleam_stdlib 1.0.5`, API uses
`pog` + `gleam_stdlib 1.x`. They have different `gleam.toml` files.

## What is implemented

- `effectivnost_360_lustre` Gleam package, `target = "javascript"`.
- `app.gleam` — Model / Update / View with **four CJM screens**:
  - `S0 /`            Start
  - `S1 /describe`    Describe
  - `S2 /request/{id}` Clarify
  - `S4 /request/{id}` Result (status == submitted, same route)
- `api_client.gleam` — thin HTTP client. **Relative** `/api/...` paths,
  never Docker-internal hostnames. Effect layer uses `effect.from` to
  wrap FFI callbacks (Lustre 5.x `Effect` is opaque).
- `screen.gleam` — server-side route parsing from `window.location`.
- `fields.gleam` — presentational field specs (local hint only; the
  server's `missing[]` is authoritative).
- `nav.mjs`, `http.mjs`, `random_key.mjs` — the FFI shims for browser
  APIs (`location.assign`, `fetch`, `crypto.randomUUID`).
- 32 unit tests covering pure logic (init, classify_submit, route
  parsing, field hint, missing-field decoder, status roundtrip).
- `nginx.conf` — reverse-proxies `/api/` to the `api` container, sets
  `application/javascript` MIME for `.mjs`, SPA fallback for unknown
  routes. Uses `resolver 127.0.0.11` so it survives a cold compose-up
  when the API is not yet resolvable.
- `Dockerfile` — multi-stage: `erlang:28-alpine` + Gleam 1.19.2 builds
  the Lustre bundle and runs `gleam test` in-container. Runtime stage is
  plain `nginx:1.27-alpine` serving the bundle.

## User journey

1. Page load on `/` — Lustre app parses the route, renders S0.
2. Click «Описать запрос» → navigate to `/describe` (full page load).
3. Type free text → submit → `POST /api/v1/requests` → server returns
   `request_id` → full-page navigate to `/request/{id}`.
4. Page loads `/request/{id}` → `GET /api/v1/requests/{id}` →
   server returns the request + status. If `status == "submitted"`,
   render S4; otherwise render S2 with editable fields.
5. Edit fields locally → click «Отправить заявку» → `POST /api/v1/
   requests/{id}/submit`.
6. On `200` → render S4 (submitted). On `422` → render the server's
   `missing[]` with `clause_id` + `quote`. On `409` → "already
   submitted" message. On `404` → "request not found". On `500/503` →
   "server error: HTTP …".
7. F5 on any `/request/{id}` URL restores the request from the server.
   No client-side routing, no in-memory state across reloads.

## Why the Lustre 5.x / API stdlib split works

The frontend uses a separate `services/frontend/gleam.toml` that pins
Lustre 5.7.1. Lustre 5.x resolves to `gleam_stdlib 1.0.5`, `gleam_json
3.1.0`, `gleam_erlang 1.3.0`, `gleam_otp 1.3.0`, `houdini 1.2.1` —
all of which compile cleanly under Gleam 1.19.2. The earlier attempt
that asserted "Lustre 5.x needs stdlib 2.0" was based on guessing, not
on the actual repository's resolver output.

## How to run

```bash
# One-time: build the image (Gleam + Erlang in-container, ~3 min).
docker build -t effectivnost360/frontend:latest services/frontend

# Bring the whole stack up — web (Lustre) and api live in the same
# compose network.
docker compose up -d postgres nats api web

# Open the application.
open http://localhost:8050/
```

## How to run the unit tests

```bash
# Single container, no compose stack required.
docker build --target builder -t effectivnost360/frontend-builder:test services/frontend
# Output ends with "32 passed, no failures".
```

## What is NOT yet implemented (production blockers)

- Production CSRF/auth — the global CSRF protection was disabled for
  the dev stand so that browser CORS preflight passes. The `csrf_known_
  header_protection` is now applied only to `POST /api/v1/requests/{id}/
  submit`. Production needs a real authentication boundary.
- `ПП РФ № 501` (the production regulation) is **not** the source of
  requirements in the seeded demo data. The current default fixture is
  the synthetic `demo_synthetic_fixture.json`. Until the citation
  validator passes against an authoritative text of `ПП № 501`, the
  production fixture must stay in `pass` status: false.
- nginx serves `Access-Control-Allow-Origin: *` on `/api/`. Same-origin
  browsers don't need it; cross-origin callers should be locked down.
