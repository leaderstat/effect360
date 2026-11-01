import common_sql as sql
import effectivnost_360/automation
import effectivnost_360/automation_repo
import effectivnost_360/auth.{type Actor}
import effectivnost_360/completeness
import effectivnost_360/database
import effectivnost_360/moderation_router as mr
import effectivnost_360/automation_router as ar
import effectivnost_360/agent_api as aa
import effectivnost_360/submit as sub
import envoy
import gleam/dict
import gleam/http.{Get, Options, Post, Put}
import gleam/json
import gleam/dynamic
import gleam/dynamic/decode
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/string
import wisp

pub type Context(conn) {
  Context(driver: sql.Driver(conn), database_url: String)
}

type DraftInput {
  DraftInput(idempotency_key: String, text: String)
}

fn draft_input_decoder() -> decode.Decoder(DraftInput) {
  use idempotency_key <- decode.field("idempotency_key", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(DraftInput(idempotency_key:, text:))
}

pub fn handle_request(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  // CORS preflight (OPTIONS) — for the local dev-стенда: allow the
  // static UIs on different ports to call us. Production must NOT
  // reach this branch — it should be same-origin behind a reverse
  // proxy and DEV_ALLOWED_ORIGINS must be empty.
  let allowed_origins = dev_allowed_origins()
  case req.method {
    Options ->
      wisp.response(204)
      |> apply_cors_headers(req, allowed_origins)
      |> wisp.set_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> wisp.set_header("access-control-allow-headers", "content-type, x-csrf-token, authorization")
      |> wisp.set_header("access-control-max-age", "600")
    _ ->
      case wisp.path_segments(req) {
    ["health"] -> health(req)
    ["ready"] -> ready(req, context)
    ["api", "v1", "requests"] -> csrf_protect(requests(req, context))
    ["api", "v1", "requests", request_id] -> get_request_endpoint(req, context, request_id)
    ["api", "v1", "requests", request_id, "submit"] ->
      csrf_protect(submit_endpoint(req, context, request_id))
    // ---- Phase 7: сессия, кабинет заявителя, модерация ----
    ["api", "v1", "session"] ->
      case req.method {
        Post -> csrf_protect(mr.create_session(req, mr.Context(driver: context.driver, database_url: context.database_url)))
        Get -> mr.current_session(req, mr.Context(driver: context.driver, database_url: context.database_url))
        _ -> wisp.method_not_allowed([Post, Get])
      }
    ["api", "v1", "my", "requests"] ->
      mr.my_requests(req, mr.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "notifications"] ->
      mr.my_notifications(req, mr.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "notifications", notification_id, "read"] ->
      csrf_protect(
        mr.read_notification(
          req,
          mr.Context(driver: context.driver, database_url: context.database_url),
          notification_id,
        ),
      )
    ["api", "v1", "requests", request_id, "detail"] ->
      mr.request_detail(
        req,
        mr.Context(driver: context.driver, database_url: context.database_url),
        request_id,
      )
    ["api", "v1", "requests", request_id, "transition"] ->
      csrf_protect(
        mr.transition(
          req,
          mr.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    ["api", "v1", "requests", request_id, "answer"] ->
      csrf_protect(
        mr.answer_clarification(
          req,
          mr.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    ["api", "v1", "requests", request_id, "response"] ->
      csrf_protect(
        mr.save_response(
          req,
          mr.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    ["api", "v1", "requests", request_id, "response", "approve"] ->
      csrf_protect(
        mr.approve_response_endpoint(
          req,
          mr.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    ["api", "v1", "requests", request_id, "feedback"] ->
      csrf_protect(
        mr.submit_feedback(
          req,
          mr.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    ["api", "v1", "moderation", "queue"] ->
      mr.moderation_queue(req, mr.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "moderation", "metrics"] ->
      mr.metrics(req, mr.Context(driver: context.driver, database_url: context.database_url))
    // ---- Phase 8: режим автоматизации и ИИ-агенты ----
    ["api", "v1", "automation", "settings"] ->
      case req.method {
        Get -> ar.get_settings(req, ar.Context(driver: context.driver, database_url: context.database_url))
        Put -> csrf_protect(ar.put_settings(req, ar.Context(driver: context.driver, database_url: context.database_url)))
        _ -> wisp.method_not_allowed([Get, Put])
      }
    ["api", "v1", "automation", "panel"] ->
      ar.panel(req, ar.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "automation", "exceptions"] ->
      ar.exceptions(req, ar.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "automation", "exceptions", exception_id, "resolve"] ->
      csrf_protect(
        ar.resolve_exception(
          req,
          ar.Context(driver: context.driver, database_url: context.database_url),
          exception_id,
        ),
      )
    ["api", "v1", "automation", "tasks", task_id, "done"] ->
      csrf_protect(
        ar.complete_task(
          req,
          ar.Context(driver: context.driver, database_url: context.database_url),
          task_id,
        ),
      )
    ["api", "v1", "automation", "requests", request_id] ->
      ar.request_automation(
        req,
        ar.Context(driver: context.driver, database_url: context.database_url),
        request_id,
      )
    ["api", "v1", "automation", "requests", request_id, "recheck"] ->
      csrf_protect(
        ar.recheck(
          req,
          ar.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    ["api", "v1", "automation", "requests", request_id, "confirm"] ->
      csrf_protect(
        ar.confirm(
          req,
          ar.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    ["api", "v1", "automation", "requests", request_id, "reject"] ->
      csrf_protect(
        ar.reject(
          req,
          ar.Context(driver: context.driver, database_url: context.database_url),
          request_id,
        ),
      )
    // ---- Phase 8: машинный слой для ИИ-агентов ----
    //
    // Эти endpoint'ы вызывает Go-worker. Доступ — по сервисному токену
    // (AGENT_SERVICE_TOKEN). Агент не может менять режим автоматизации и
    // не может изменить статус в обход доменного сервиса.
    ["api", "v1", "automation", "agent", "mode"] ->
      aa.mode(req, aa.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "automation", "agent", "checks"] ->
      aa.save_check(req, aa.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "automation", "agent", "proposals"] ->
      aa.propose(req, aa.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "automation", "agent", "exceptions"] ->
      aa.raise_exception(
        req,
        aa.Context(driver: context.driver, database_url: context.database_url),
      )
    ["api", "v1", "automation", "agent", "drafts"] ->
      aa.create_draft(
        req,
        aa.Context(driver: context.driver, database_url: context.database_url),
      )
    ["api", "v1", "automation", "agent", "notifications"] ->
      aa.create_notification(
        req,
        aa.Context(driver: context.driver, database_url: context.database_url),
      )
    ["api", "v1", "automation", "agent", "tasks"] ->
      aa.create_task(req, aa.Context(driver: context.driver, database_url: context.database_url))
    ["api", "v1", "automation", "agent", "metrics"] ->
      case req.method {
        Get -> aa.metrics(req, aa.Context(driver: context.driver, database_url: context.database_url))
        Post ->
          aa.record_metric(
            req,
            aa.Context(driver: context.driver, database_url: context.database_url),
          )
        _ -> wisp.method_not_allowed([Get, Post])
      }
    ["api", "v1", "automation", "agent", "events", event_id, "status"] ->
      aa.event_status(
        req,
        aa.Context(driver: context.driver, database_url: context.database_url),
        event_id,
      )
    ["api", "v1", "automation", "agent", "requests", request_id, "snapshot"] ->
      aa.snapshot(
        req,
        aa.Context(driver: context.driver, database_url: context.database_url),
        request_id,
      )
    ["api", "v1", "automation", "agent", "requests", request_id, "transition"] ->
      aa.apply_transition(
        req,
        aa.Context(driver: context.driver, database_url: context.database_url),
        request_id,
      )
    _ -> wisp.not_found()
  }
  }
  |> apply_cors_headers(req, allowed_origins)
}

// dev_allowed_origins reads the DEV_ALLOWED_ORIGINS env var. If
// unset/empty, CORS is effectively closed (no origin is reflected).
// For production this MUST be empty.
fn dev_allowed_origins() -> List(String) {
  case envoy.get("DEV_ALLOWED_ORIGINS") {
    Ok(raw) ->
      raw
      |> string.split(on: ",")
      |> list.map(string.trim)
      |> list.filter(fn(s) { s != "" })
    Error(_) -> []
  }
}

fn origin_allowed(origin: String, allowed: List(String)) -> Bool {
  list.contains(allowed, origin)
}

fn apply_cors_headers(resp: wisp.Response, req: wisp.Request, allowed: List(String)) -> wisp.Response {
  case req.headers |> list.find(fn(h) { h.0 == "origin" }) {
    Ok(origin) ->
      case origin_allowed(origin.1, allowed) {
        True ->
          resp
          |> wisp.set_header("access-control-allow-origin", origin.1)
          |> wisp.set_header("vary", "origin")
        False -> resp
      }
    Error(_) -> resp
  }
}

fn csrf_protect(resp: wisp.Response) -> wisp.Response {
  // PRODUCTION BLOCKER: настоящая CSRF-проверка не реализована.
  // Сейчас функция — no-op, чтобы CORS preflight не отваливался.
  // Production должна проверять:
  //   - для POST — обязательный заголовок X-CSRF-Token, сверяемый
  //     с SECRET_KEY_BASE (или HMAC по сессии);
  //   - для OPTIONS — pass-through;
  //   - для GET — pass-through.
  // Пока только отмечаем требование в комментарии.
  resp
}

fn health(req: wisp.Request) -> wisp.Response {
  use <- wisp.require_method(req, Get)
  json_response(json.object([#("status", json.string("ok"))]), 200)
}

fn ready(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, Get)
  case database.ready(context.driver, context.database_url) {
    Ok(Nil) -> json_response(json.object([#("status", json.string("ready"))]), 200)
    Error(error) -> {
      io.println("database readiness failed: " <> string.inspect(error))
      error_response("database_unavailable", 503)
    }
  }
}

fn requests(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  case req.method {
    Post -> create_draft(req, context)
    _ -> wisp.method_not_allowed([Post])
  }
}

fn create_draft(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use body <- wisp.require_json(req)

  // The request must belong to the authenticated applicant: `requester_id`
  // is what the object-level authorization rules use to decide whether this
  // user may see the request later. An anonymous draft would be invisible
  // to its own author.
  case mr.optional_actor(req, mr.Context(driver: context.driver, database_url: context.database_url)) {
    Error(response) -> response
    Ok(actor) -> create_draft_for(body, actor, context)
  }
}

fn create_draft_for(
  body: dynamic.Dynamic,
  actor: Actor,
  context: Context(conn),
) -> wisp.Response {
  case decode.run(body, draft_input_decoder()) {
    Error(_) -> error_response("invalid_request", 422)
    Ok(input) -> {
      let text = string.trim(input.text)
      let key = string.trim(input.idempotency_key)
      case text == "" || string.length(text) > 10000 || key == "" || string.length(key) > 128 {
        True -> error_response("invalid_request", 422)
        False ->
          case database.create_request(
            context.driver,
            context.database_url,
            actor.user_id,
            key,
            text,
          ) {
            Ok(request) ->
              json_response(
                json.object([
                  #("request_id", json.string(request.id)),
                  #("status", json.string("draft")),
                  #("created", json.bool(request.created)),
                ]),
                case request.created { True -> 202 False -> 200 },
              )
            Error(error) -> {
              io.println("request persistence failed: " <> string.inspect(error))
              error_response("request_persistence_failed", 503)
            }
          }
      }
    }
  }
}

fn json_response(body: json.Json, status: Int) -> wisp.Response {
  wisp.json_response(json.to_string(body), status)
}

fn error_response(code: String, status: Int) -> wisp.Response {
  json_response(json.object([#("error", json.string(code))]), status)
}

// --------------------------------------------------------------------
// GET /api/v1/requests/{id}
//
// Returns the request as the caller is allowed to see it: id, status,
// request_type, fields, timestamps. Never includes raw_text or other
// users' data. 404 if not found.

fn get_request_endpoint(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, Get)
  case sub.get_request(context.driver, context.database_url, request_id) {
    Ok(r) ->
      json_response(
        json.object([
          #("id", json.string(r.id)),
          #("status", json.string(sub.status_to_string(r.status))),
          #(
            "request_type",
            case r.request_type_name {
              option.Some(name) -> json.string(name)
              option.None -> json.null()
            },
          ),
          #("fields", fields_to_json(r.fields)),
          #(
            "submitted_at",
            case r.submitted_at {
              option.Some(t) -> json.string(t)
              option.None -> json.null()
            },
          ),
          #("created_at", json.string(r.created_at)),
        ]),
        200,
      )
    Error(sql.QueryError("Request not found")) ->
      error_response("request_not_found", 404)
    Error(e) -> {
      io.println("get_request failed: " <> string.inspect(e))
      error_response("request_lookup_failed", 503)
    }
  }
}

fn fields_to_json(fields: dict.Dict(String, String)) -> json.Json {
  json.object(
    fields
    |> dict.to_list
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
  )
}

// --------------------------------------------------------------------
// POST /api/v1/requests/{id}/submit
//
// 1. Load the request (404 if not found).
// 2. Verify status is "draft" (409 if not, with current status).
// 3. Load the requirements for the request's type.
// 4. Load the blocking rules (`requirement_hard_stops`).
// 5. Call completeness.check_with_hard_stops (pure, no LLM).
// 6. If a `block_submit` rule triggered -> 422 with hard_stops[].
// 7. If complete -> submit_if_complete (atomic transition).
// 8. If incomplete -> 422 with the structured missing[] payload.
// 9. Returns 200 + JSON body on success.

fn submit_endpoint(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, Post)

  // Step 1: load the request.
  case sub.get_request(context.driver, context.database_url, request_id) {
    Error(sql.QueryError("Request not found")) ->
      error_response("request_not_found", 404)
    Error(e) -> {
      io.println("get_request failed: " <> string.inspect(e))
      error_response("request_lookup_failed", 503)
    }
    Ok(request) -> {
      // Step 2: status check.
      case sub.status_can_submit(request.status) {
        False ->
          json_response(
            json.object([
              #("error", json.string("invalid_status")),
              #("message", json.string("only draft requests can be submitted")),
              #(
                "current_status",
                json.string(sub.status_to_string(request.status)),
              ),
            ]),
            409,
          )
        True -> {
          // Step 3: load requirements + blocking rules for the request's type.
          case
            sub.get_requirements_for_request(
              context.driver,
              context.database_url,
              request_id,
            )
          {
            Error(e) -> {
              io.println("get_requirements failed: " <> string.inspect(e))
              error_response("requirements_lookup_failed", 503)
            }
            Ok(req_rows) -> {
              case
                sub.get_hard_stops_for_request(
                  context.driver,
                  context.database_url,
                  request_id,
                )
              {
                Error(e) -> {
                  io.println(
                    "get_hard_stops failed: " <> string.inspect(e),
                  )
                  error_response("hard_stops_lookup_failed", 503)
                }
                Ok(hard_stop_rows) -> {
                  let requirements =
                    list.map(req_rows, fn(r) {
                      completeness.Requirement(
                        id: 0,
                        field_name: r.field_name,
                        required: r.required,
                        condition: r.condition,
                        clause_id: r.clause_id,
                        clause_ref: r.clause_ref,
                        quote: r.quote,
                      )
                    })
                  let hard_stop_rules =
                    list.map(hard_stop_rows, fn(r) {
                      completeness.HardStopRule(
                        field_name: r.field_name,
                        trigger_expr: r.trigger_expr,
                        action: parse_hard_stop_action(r.action),
                        reason: r.reason,
                        clause_id: r.clause_id,
                        clause_ref: r.clause_ref,
                        quote: r.quote,
                        regulatory_ref_id: r.regulatory_ref_id,
                      )
                    })
                  let outcome =
                    completeness.check_with_hard_stops(
                      requirements,
                      request.fields,
                      hard_stop_rules,
                    )

                  // Step 5: a triggered `block_submit` rule forbids the
                  // submission regardless of completeness. This is a
                  // regulatory veto, not a missing field.
                  let blocking = case outcome.hard_stops {
                    [] -> False
                    hits -> {
                      list.any(hits, fn(h) {
                        case h.action {
                          completeness.BlockSubmit -> True
                          completeness.NeedsEmployerReview -> False
                        }
                      })
                    }
                  }
                  case blocking {
                    True ->
                      json_response(
                        json.object([
                          #("error", json.string("hard_stop")),
                          #(
                            "message",
                            json.string(
                              "submission is blocked by a regulatory rule",
                            ),
                          ),
                          #("complete", json.bool(False)),
                          #(
                            "missing",
                            json.array(
                              from: outcome.missing,
                              of: completeness.missing_to_json,
                            ),
                          ),
                          #(
                            "hard_stops",
                            json.array(
                              from: outcome.hard_stops,
                              of: completeness.hard_stop_to_json,
                            ),
                          ),
                        ]),
                        422,
                      )
                    False ->
                      case outcome.complete {
                        False ->
                          case automation_mode_allows_incomplete(context) {
                            False ->
                              json_response(
                                json.object([
                                  #("complete", json.bool(False)),
                                  #(
                                    "missing",
                                    missing_to_json_array(outcome.missing),
                                  ),
                                  #(
                                    "hard_stops",
                                    json.array(
                                      from: outcome.hard_stops,
                                      of: completeness.hard_stop_to_json,
                                    ),
                                  ),
                                ]),
                                422,
                              )
                            True ->
                              submit_draft(
                                context,
                                request_id,
                                outcome.missing,
                                outcome.hard_stops,
                                first_regulatory_ref(outcome.hard_stops),
                              )
                          }
                        True ->
                          submit_draft(
                            context,
                            request_id,
                            outcome.missing,
                            outcome.hard_stops,
                            first_regulatory_ref(outcome.hard_stops),
                          )
                      }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Map the wire value of `requirement_hard_stops.action` onto the typed
/// action. The database CHECK constraint guarantees one of the two known
/// values; an unknown value is treated as the stricter `block_submit` so
/// a corrupted rule can never silently allow a prohibited submission.
fn parse_hard_stop_action(raw: String) -> completeness.HardStopAction {
  case raw {
    "needs_employer_review" -> completeness.NeedsEmployerReview
    _ -> completeness.BlockSubmit
  }
}

/// The first regulatory reference id carried by the triggered rules.
///
/// Used to stamp `request_events.regulatory_ref_id` so the audit journal
/// can point at the norm the decision was based on.
fn first_regulatory_ref(hits: List(completeness.HardStopHit)) -> Option(String) {
  list.fold(hits, option.None, fn(acc, h) {
    case acc {
      option.Some(_) -> acc
      option.None -> h.regulatory_ref_id
    }
  })
}

/// Move a draft into the `submitted` status.
///
/// The answer always carries the list of the missing fields, so the
/// applicant knows what the digital moderator will ask for.
///
/// `regulatory_ref_id` is the first external act id we encountered in
/// the workflow (a `needs_employer_review` rule confirmed by the
/// employer, or a regulatory override). It is written into the
/// resulting `request_events.regulatory_ref_id` row so the journal can
/// show "переход выполнен на основании ПП РФ № 501 п. 2".
fn submit_draft(
  context: Context(conn),
  request_id: String,
  missing: List(completeness.Missing),
  hard_stops: List(completeness.HardStopHit),
  regulatory_ref_id: Option(String),
) -> wisp.Response {
  case
    sub.submit_if_complete(
      context.driver,
      context.database_url,
      request_id,
      regulatory_ref_id,
    )
  {
    sub.SubmitSucceeded(_id, ts) ->
      json_response(
        json.object([
          #("status", json.string("submitted")),
          #("submitted_at", json.string(ts)),
          #("complete", json.bool(list.is_empty(missing))),
          #("missing", missing_to_json_array(missing)),
          // A `needs_employer_review` rule does not block the submission,
          // but the applicant (and the employer) must see that the case
          // needs a confirmation.
          #(
            "hard_stops",
            json.array(from: hard_stops, of: completeness.hard_stop_to_json),
          ),
        ]),
        200,
      )
    sub.AlreadySubmitted(_) ->
      json_response(
        json.object([
          #("status", json.string("submitted")),
          #("note", json.string("already_submitted")),
          #("missing", missing_to_json_array(missing)),
          #(
            "hard_stops",
            json.array(from: hard_stops, of: completeness.hard_stop_to_json),
          ),
        ]),
        200,
      )
    sub.UnknownStatusTransition(_, current) ->
      json_response(
        json.object([
          #("error", json.string("invalid_status")),
          #("current_status", json.string(current)),
        ]),
        409,
      )
    sub.NotFound -> error_response("request_not_found", 404)
    sub.DbErr(e) -> {
      io.println("submit_if_complete failed: " <> string.inspect(e))
      error_response("submit_failed", 503)
    }
  }
}

/// Whether the digital moderator is allowed to handle an incomplete
/// submission.
///
/// The mode is data: it is stored in PostgreSQL and read through the
/// repository, so the backend — not the browser — decides. In the `manual`
/// mode the agent only analyses, so the applicant is asked to complete the
/// form before sending.
fn automation_mode_allows_incomplete(context: Context(conn)) -> Bool {
  case
    automation_repo.load_settings(context.driver, context.database_url)
  {
    Ok(settings) ->
      case settings.mode {
        automation.Manual -> False
        _ -> True
      }
    Error(_) -> False
  }
}

fn missing_to_json_array(missing: List(completeness.Missing)) -> json.Json {
  json.array(
    from: missing,
    of: fn(m) {
      json.object([
        #("field_name", json.string(m.field_name)),
        #("required", json.bool(m.required)),
        #("conditional", json.bool(m.conditional)),
        #("reason", json.string(m.reason)),
        #("clause_id", json.string(m.clause_id)),
        #("quote", json.string(m.quote)),
      ])
    },
  )
}
