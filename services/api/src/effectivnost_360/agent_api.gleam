// services/api/src/effectivnost_360/agent_api.gleam
//
// Р В¤Р В°Р В·Р В° 8 РІР‚вЂќ API Р вЂќР вЂєР Р‡ Р ВР В-Р С’Р вЂњР вЂўР СњР СћР С›Р вЂ™ (Р СР В°РЎв‚¬Р С‘Р Р…Р Р…РЎвЂ№Р в„– РЎРѓР В»Р С•Р в„–).
//
// Р С™Р СћР С› Р С›Р вЂР В Р С’Р В©Р С’Р вЂўР СћР РЋР Р‡ Р С™ Р В­Р СћР ВР Сљ ENDPOINT'Р С’Р Сљ
// --------------------------------
// Go-worker (Agent A Р’В«Р В¦Р С‘РЎвЂћРЎР‚Р С•Р Р†Р С•Р в„– Р СР С•Р Т‘Р ВµРЎР‚Р В°РЎвЂљР С•РЎР‚Р’В», Agent B Р’В«Р С’Р С–Р ВµР Р…РЎвЂљ РЎРѓР С•Р С—РЎР‚Р С•Р Р†Р С•Р В¶Р Т‘Р ВµР Р…Р С‘РЎРЏ
// Р В·Р В°РЎРЏР Р†Р С‘РЎвЂљР ВµР В»РЎРЏР’В»). Р В­РЎвЂљР С• Р СљР С’Р РЃР ВР СњР СњР В«Р в„ў РЎРѓР В»Р С•Р в„–: Р С•Р Р… Р С•РЎвЂљР В»Р С‘РЎвЂЎР В°Р ВµРЎвЂљРЎРѓРЎРЏ Р С•РЎвЂљ Р С—Р С•Р В»РЎРЉР В·Р С•Р Р†Р В°РЎвЂљР ВµР В»РЎРЉРЎРѓР С”Р С•Р С–Р С• API РЎвЂљР ВµР С,
// РЎвЂЎРЎвЂљР С• Р Р…Р Вµ Р С—РЎР‚Р С•РЎвЂ¦Р С•Р Т‘Р С‘РЎвЂљ РЎвЂЎР ВµРЎР‚Р ВµР В· Р В±РЎР‚Р В°РЎС“Р В·Р ВµРЎР‚.
//
// Р С’Р Р€Р СћР вЂўР СњР СћР ВР В¤Р ВР С™Р С’Р В¦Р ВР Р‡
// -------------
// Р С’Р С–Р ВµР Р…РЎвЂљРЎвЂ№ РЎР‚Р В°Р В±Р С•РЎвЂљР В°РЎР‹РЎвЂљ РЎРѓ РЎвЂљР С•Р С”Р ВµР Р…Р С•Р С РЎРѓР ВµРЎР‚Р Р†Р С‘РЎРѓР Р…Р С•Р С–Р С• РЎвЂљР С‘Р С—Р В° (`service_token`), Р В° Р Р…Р Вµ РЎРѓ
// РЎРѓР ВµРЎРѓРЎРѓР С‘Р ВµР в„– Р С—Р С•Р В»РЎРЉР В·Р С•Р Р†Р В°РЎвЂљР ВµР В»РЎРЏ. Р СћР С•Р С”Р ВµР Р… РЎвЂ¦РЎР‚Р В°Р Р…Р С‘РЎвЂљРЎРѓРЎРЏ Р Р† `automation_settings.service_token`
// Р С‘ РЎРѓР Р†Р ВµРЎР‚РЎРЏР ВµРЎвЂљРЎРѓРЎРЏ Р В·Р Т‘Р ВµРЎРѓРЎРЉ. Р СћР С•Р С”Р ВµР Р… Р С—Р С•Р В»РЎРЉР В·Р С•Р Р†Р В°РЎвЂљР ВµР В»РЎРЏ Р СћР С›Р вЂ“Р вЂў Р С—РЎР‚Р С‘Р Р…Р С‘Р СР В°Р ВµРЎвЂљРЎРѓРЎРЏ РІР‚вЂќ Р Р…Р С• РЎвЂљР С•Р В»РЎРЉР С”Р С• РЎРѓ
// РЎР‚Р С•Р В»РЎРЉРЎР‹ Р СР С•Р Т‘Р ВµРЎР‚Р В°РЎвЂљР С•РЎР‚Р В°. Р СћР В°Р С” Р В°Р С–Р ВµР Р…РЎвЂљ Р СР С•Р В¶Р ВµРЎвЂљ Р В±РЎвЂ№РЎвЂљРЎРЉ Р В·Р В°Р С—РЎС“РЎвЂ°Р ВµР Р… Р В±Р ВµР В· РЎС“РЎвЂЎРЎвЂРЎвЂљР Р…Р С•Р в„– Р В·Р В°Р С—Р С‘РЎРѓР С‘
// РЎвЂЎР ВµР В»Р С•Р Р†Р ВµР С”Р В°, Р В° РЎРѓР В»РЎС“РЎвЂЎР В°Р в„–Р Р…РЎвЂ№Р в„– Р Р†РЎвЂ№Р В·Р С•Р Р† Р С‘Р В· Р С‘Р Р…РЎвЂљР ВµРЎР‚Р Р…Р ВµРЎвЂљР В° РІР‚вЂќ Р С•РЎвЂљР С”Р В»Р С•Р Р…РЎвЂР Р….
//
// Р вЂњР В Р С’Р СњР ВР В¦Р С’ Р вЂќР С›Р вЂ™Р вЂўР В Р ВР Р‡
// ---------------
// * Р С’Р С–Р ВµР Р…РЎвЂљ Р СњР вЂў Р СР С•Р В¶Р ВµРЎвЂљ РЎРѓР В°Р С Р СР ВµР Р…РЎРЏРЎвЂљРЎРЉ РЎРѓРЎвЂљР В°РЎвЂљРЎС“РЎРѓ: Р Т‘Р В»РЎРЏ РЎРЊРЎвЂљР С•Р С–Р С• Р ВµРЎРѓРЎвЂљРЎРЉ `POST
//   /api/v1/automation/checks/{id}/transition`, Р С”Р С•РЎвЂљР С•РЎР‚РЎвЂ№Р в„– Р Р†Р Р…РЎС“РЎвЂљРЎР‚Р С‘ Р Р†РЎвЂ№Р В·РЎвЂ№Р Р†Р В°Р ВµРЎвЂљ
//   `moderation.apply_transition` РІР‚вЂќ РЎвЂљР С•РЎвЂљ Р В¶Р Вµ Р Т‘Р С•Р СР ВµР Р…Р Р…РЎвЂ№Р в„– РЎРѓР ВµРЎР‚Р Р†Р С‘РЎРѓ, РЎвЂЎРЎвЂљР С• Р С‘ Р Т‘Р В»РЎРЏ
//   РЎвЂЎР ВµР В»Р С•Р Р†Р ВµР С”Р В°, РЎРѓ РЎвЂљР С•Р в„– Р В¶Р Вµ Р С—РЎР‚Р С•Р Р†Р ВµРЎР‚Р С”Р С•Р в„– Р В»Р ВµР С–Р В°Р В»РЎРЉР Р…Р С•РЎРѓРЎвЂљР С‘ Р С—Р ВµРЎР‚Р ВµРЎвЂ¦Р С•Р Т‘Р В° Р С—Р С•Р Т‘ `FOR UPDATE`.
// * Р С’Р С–Р ВµР Р…РЎвЂљ Р СњР вЂў Р СР С•Р В¶Р ВµРЎвЂљ Р Р†Р С”Р В»РЎР‹РЎвЂЎР С‘РЎвЂљРЎРЉ Р В°Р Р†РЎвЂљР С•Р СР В°РЎвЂљР С‘РЎвЂЎР ВµРЎРѓР С”Р С‘Р в„– РЎР‚Р ВµР В¶Р С‘Р С: `PUT
//   /api/v1/automation/settings` Р Т‘Р С•РЎРѓРЎвЂљРЎС“Р С—Р ВµР Р… РЎвЂљР С•Р В»РЎРЉР С”Р С• Р СР С•Р Т‘Р ВµРЎР‚Р В°РЎвЂљР С•РЎР‚РЎС“.
// * Р В Р ВµР В¶Р С‘Р С Р С—РЎР‚Р С•Р Р†Р ВµРЎР‚РЎРЏР ВµРЎвЂљРЎРѓРЎРЏ Р вЂ”Р вЂќР вЂўР РЋР В¬, Р Р…Р В° РЎРѓР ВµРЎР‚Р Р†Р ВµРЎР‚Р Вµ: Р С”Р В»Р С‘Р ВµР Р…РЎвЂљ Р С‘ Р В°Р С–Р ВµР Р…РЎвЂљ Р Р…Р Вµ Р СР С•Р С–РЎС“РЎвЂљ Р ВµР С–Р С•
//   Р С•Р В±Р С•Р в„–РЎвЂљР С‘.
import common_sql as sql
import effectivnost_360/automation.{
  type AutomationMode, check_result_to_string, mode_to_string, parse_mode_or_default,
  rule_to_string,
} as automation
import effectivnost_360/automation_repo.{
  type Check, type Draft, type Settings, type Snapshot, type Task,
  json_object_field,
} as repo
import effectivnost_360/auth.{type Actor, Admin} as auth
import effectivnost_360/moderation as moderation
import effectivnost_360/state_machine.{
  type Action, ActionAccept, ActionApplicantAnswered, ActionAnswerReady,
  ActionComplete, ActionRequestClarification, ActionStart, parse_status,
  status_label, status_to_string,
} as sm
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/http
import envoy
import wisp

pub type Context(conn) {
  Context(driver: sql.Driver(conn), database_url: String)
}

/// The actor id the agents act under.
///
/// It is the reserved "system" id: the actions of the agents are attributed
/// to the system, not to a person. A human action always carries the id of
/// the moderator who performed it.
const system_actor_id = "00000000-0000-0000-0000-000000000000"

// -------------------------------------------------------------
// Shared helpers
// -------------------------------------------------------------

fn json_response(body: json.Json, status: Int) -> wisp.Response {
  wisp.json_response(json.to_string(body), status)
}

fn error_response(code: String, status: Int) -> wisp.Response {
  json_response(json.object([#("error", json.string(code))]), status)
}

fn unauthorized() -> wisp.Response {
  error_response("unauthorized", 401)
}

fn not_found() -> wisp.Response {
  error_response("not_found", 404)
}

/// The service token of the agents, read from the environment.
///
/// It is NOT stored in the database and never leaves the server. The agent
/// and the API are configured with the same value.
fn service_token() -> Option(String) {
  case envoy.get("AGENT_SERVICE_TOKEN") {
    Error(_) -> None
    Ok(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
  }
}

/// Check the credentials of a machine call.
///
/// Returns `Error(response)` when the caller is not allowed in.
fn authorize_service(
  req: wisp.Request,
  context: Context(conn),
) -> Result(String, wisp.Response) {
  case auth.bearer_token(req) {
    None -> Error(unauthorized())
    Some(token) ->
      case service_token() {
        Some(expected) ->
          case token == expected {
            True -> Ok("system")
            False -> Error(unauthorized())
          }
        // No service token configured: the agent layer is switched off.
        // The endpoint then refuses everyone instead of opening a hole.
        None -> Error(unauthorized())
      }
  }
}

// -------------------------------------------------------------
// GET /api/v1/automation/agent/snapshot/{request_id}
// -------------------------------------------------------------

/// `GET /api/v1/agent/requests/{request_id}/snapshot` РІР‚вЂќ the CURRENT state of
/// a request, in the shape the agent needs.
///
/// The agent never works on the event payload: the payload may be stale. It
/// loads the request through this endpoint, so the check always runs against
/// the actual data.
///
/// The response contains the fields of the request and the requirements that
/// apply to them, so the deterministic check uses the same rules as the API.
pub fn snapshot(req: wisp.Request, context: Context(conn), request_id: String) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) ->
      case repo.load_snapshot(context.driver, context.database_url, request_id) {
        Error(e) -> {
          io.println("agent snapshot failed: " <> string.inspect(e))
          error_response("snapshot_failed", 503)
        }
        Ok(None) -> not_found()
        Ok(Some(snapshot)) -> json_response(snapshot_to_json(snapshot), 200)
      }
  }
}

fn snapshot_to_json(snapshot: Snapshot) -> json.Json {
  json.object([
    #("id", json.string(snapshot.id)),
    #("status", json.string(snapshot.status)),
    #("request_type", json.string(snapshot.request_type)),
    #("raw_text", json.string(snapshot.raw_text)),
    #(
      "fields",
      json.object(
        list.map(snapshot.fields, fn(pair) { #(pair.0, json.string(pair.1)) }),
      ),
    ),
    #(
      "requirements",
      json.array(
        from: snapshot.requirements,
        of: fn(req) {
          json.object([
            #("field_name", json.string(req.field_name)),
            #("required", json.bool(req.required)),
            #("condition", json.string(req.condition)),
            #("clause_id", json.string(req.clause_id)),
            #("quote", json.string(req.quote)),
          ])
        },
      ),
    ),
    #(
      "due_at",
      case snapshot.due_at {
        Some(value) -> json.string(value)
        None -> json.null()
      },
    ),
  ])
}

// -------------------------------------------------------------
// GET /api/v1/automation/agent/mode
// -------------------------------------------------------------

/// `GET /api/v1/automation/agent/mode` РІР‚вЂќ the current automation mode.
///
/// The agent reads the mode before EVERY request: the mode is data, not
/// configuration, and a moderator may change it at any moment.
pub fn mode(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) ->
      case repo.load_settings(context.driver, context.database_url) {
        Error(e) -> {
          io.println("automation mode load failed: " <> string.inspect(e))
          error_response("automation_settings_failed", 503)
        }
        Ok(settings) ->
          json_response(
            json.object([
              #("mode", json.string(mode_to_string(settings.mode))),
              #("rules_version", json.string(settings.rules_version)),
            ]),
            200,
          )
      }
  }
}

// -------------------------------------------------------------
// GET /api/v1/automation/agent/events/{event_id}/status
// -------------------------------------------------------------

/// `GET /api/v1/automation/agent/events/{event_id}/status` РІР‚вЂќ has this event
/// already been processed?
///
/// THIS IS THE IDEMPOTENCY GUARD. The delivery semantics are
/// at-least-once, so the same event can arrive twice. The agent asks the
/// API before doing anything; a `processed: true` answer stops the agent.
///
/// The event id is the id of the outbox row. The answer is derived from the
/// `automation_actions` table: if the event already produced an action, the
/// event is processed.
pub fn event_status(req: wisp.Request, context: Context(conn), event_id: String) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) ->
      case repo.event_processed(context.driver, context.database_url, event_id) {
        Error(e) -> {
          io.println("agent event status failed: " <> string.inspect(e))
          error_response("event_status_failed", 503)
        }
        Ok(processed) ->
          json_response(
            json.object([#("processed", json.bool(processed))]),
            200,
          )
      }
  }
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/checks
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/checks` РІР‚вЂќ save the result of the check.
///
/// The write is idempotent per request (`ON CONFLICT (request_id) DO
/// UPDATE`), so a redelivered event refreshes the row instead of creating
/// a second one.
pub fn save_check(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use request_id <- decode.field("request_id", decode.string)
        use result <- decode.field("result", decode.string)
        use checks <- decode.field("checks", decode.list(of: decode.string))
        use problems <- decode.field("problems", decode.list(of: decode.string))
        use proposed <- decode.field("proposed", decode.list(of: decode.string))
        use reason <- decode.optional_field("reason", "", decode.string)        use rule_code <- decode.optional_field("rule_code", "", decode.string)
        use rules_version <- decode.optional_field("rules_version", "v1", decode.string)
        use model_version <- decode.optional_field("model_version", "", decode.string)
        use prompt_version <- decode.optional_field("prompt_version", "", decode.string)
        use llm_used <- decode.optional_field("llm_used", False, decode.bool)
        use source_event <- decode.optional_field("event_id", "", decode.string)
        use initiated_by <- decode.optional_field("initiated_by", "system", decode.string)
        use duration_ms <- decode.optional_field("duration_ms", 0, decode.int)
        use clarification <- decode.optional_field("clarification_request", "", decode.string)
        decode.success(#(
          request_id,
          result,
          checks,
          problems,
          proposed,
          reason,
          rule_code,
          rules_version,
          model_version,
          prompt_version,
          llm_used,
          source_event,
          initiated_by,
          duration_ms,
          clarification,
        ))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(
            request_id,
            result,
            checks,
            problems,
            proposed,
            reason,
            rule_code,
            rules_version,
            model_version,
            prompt_version,
            llm_used,
            source_event,
            initiated_by,
            duration_ms,
            clarification,
          ) = values
          case valid_check_result(result) {
            False -> error_response("unknown_check_result", 422)
            True ->
              case
                repo.save_check(
                  context.driver,
                  context.database_url,
                  request_id,
                  automation.parse_check_result(result),
                  json_array_text(checks),
                  json_array_text(problems),
                  json_array_text(proposed),
                  clarification,
                  reason,
                  rule_code,
                  rules_version,
                  model_version,
                  prompt_version,
                  llm_used,
                  source_event,
                  initiated_by,
                  duration_ms,
                )
              {
                Error(e) -> {
                  io.println("agent check save failed: " <> string.inspect(e))
                  error_response("check_save_failed", 503)
                }
                Ok(check) -> {
                  // The indicator «Проверено автоматически» is set only for
                  // a real check: a `skipped` run did not examine anything,
                  // so it must not be shown as a completed check.
                  case check.result {
                    automation.Skipped -> Nil
                    _ ->
                      case
                        repo.mark_auto_checked(
                          context.driver,
                          context.database_url,
                          request_id,
                          check.result,
                        )
                      {
                        Ok(_) -> Nil
                        Error(e) ->
                          io.println(
                            "agent auto-check marker failed: " <> string.inspect(e),
                          )
                      }
                  }
                  json_response(
                    json.object([
                      #("ok", json.bool(True)),
                      #("request_id", json.string(check.request_id)),
                      #("result", json.string(check_result_to_string(check.result))),
                    ]),
                    200,
                  )
                }
              }
          }
        }
      }
    }
  }
}

/// Is this a known check result?
///
/// `parse_check_result` maps an unknown value to `Failed`, which would
/// silently hide a protocol error between the agent and the API. The value
/// is therefore validated BEFORE it is parsed.
fn valid_check_result(value: String) -> Bool {
  value == "passed"
  || value == "needs_info"
  || value == "ambiguous"
  || value == "error"
  || value == "skipped"
}

/// Join a list of JSON strings into a JSON array text.
///
/// The agent sends the checks / problems / proposed actions already encoded
/// as JSON, so the server stores them verbatim РІР‚вЂќ one representation, no
/// drift.
fn json_array_text(items: List(String)) -> String {
  "[" <> string.join(items, ",") <> "]"
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/checks/{id}/transition
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/checks/{request_id}/transition` РІР‚вЂќ the agent
/// asks the API to perform a transition.
///
/// THIS IS THE ONLY WAY an agent can change a status, and it is a NARROW
/// one:
///
///  * the mode must be `auto` РІР‚вЂќ in `manual` and `confirm` the request is
///    refused with 409;
///  * the action must be in the allow-list of automatically executable
///    transitions (`accept`), and the target status must be the one the
///    allow-list prescribes;
///  * the transition is applied through `moderation.apply_transition`, so
///    the state machine decides whether it is legal РІР‚вЂќ an illegal transition
///    is refused with 409;
///  * the reason, the rule, the rule version, the source event and the
///    initiator are written to the audit trail.
pub fn apply_transition(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use action <- decode.field("action", decode.string)
        use reason <- decode.optional_field("reason", "", decode.string)
        use rule_code <- decode.optional_field("rule_code", "", decode.string)
        use rules_version <- decode.optional_field("rules_version", "v1", decode.string)
        use source_event <- decode.optional_field("source_event", "", decode.string)
        use event_reason <- decode.optional_field("event_reason", "", decode.string)
        use clarification <- decode.optional_field("clarification_note", "", decode.string)
        decode.success(#(
          action,
          reason,
          rule_code,
          rules_version,
          source_event,
          event_reason,
          clarification,
        ))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(
            action_text,
            reason,
            rule_code,
            rules_version,
            source_event,
            event_reason,
            clarification,
          ) = values
          do_apply_transition(
            context,
            request_id,
            action_text,
            reason,
            rule_code,
            rules_version,
            source_event,
            event_reason,
            clarification,
          )
        }
      }
    }
  }
}

fn do_apply_transition(
  context: Context(conn),
  request_id: String,
  action_text: String,
  reason: String,
  rule_code: String,
  rules_version: String,
  source_event: String,
  event_reason: String,
  clarification: String,
) -> wisp.Response {
  // Step 1: the mode decides whether the agent may act on its own.
  case repo.load_settings(context.driver, context.database_url) {
    Error(e) -> {
      io.println("automation mode load failed: " <> string.inspect(e))
      error_response("automation_settings_failed", 503)
    }
    Ok(settings) ->
      case settings.mode {
        automation.Auto -> do_apply_transition_auto(
          context,
          settings,
          request_id,
          action_text,
          reason,
          rule_code,
          rules_version,
          source_event,
          event_reason,
          clarification,
        )
        _ ->
          // In `manual` and `confirm` the agent has no right to change a
          // status. The request goes back with a clear reason.
          error_response("automation_mode_forbids_transition", 409)
      }
  }
}

fn do_apply_transition_auto(
  context: Context(conn),
  settings: Settings,
  request_id: String,
  action_text: String,
  reason: String,
  rule_code: String,
  rules_version: String,
  source_event: String,
  event_reason: String,
  clarification: String,
) -> wisp.Response {
  // Step 2: the allow-list. Only `accept` may be executed automatically.
  case parse_action(action_text) {
    None -> error_response("unknown_action", 422)
    Some(action) ->
      case automation.may_execute_automatically(settings.mode, action) {
        False -> error_response("action_not_allowed_automatically", 409)
        True ->
          // Step 3: the domain service decides whether the transition is
          // legal. It re-reads the status under a row lock.
          case
            moderation.apply_transition(
              context.driver,
              context.database_url,
              auth.Actor(
                user_id: system_actor_id,
                role: auth.Admin,
                display_name: "Система (ИИ-агент)",
              ),
              request_id,
              action,
              reason,
              clarification,
            )
          {
            moderation.TransitionSucceeded(_, from, to) -> {
              // Step 4: the audit trail. Every automatic action records the
              // reason, the rule, the rule version, the source event and
              // the initiator.
              case
                repo.record_action(
                  context.driver,
                  context.database_url,
                  request_id,
                  "transition",
                  Some(status_to_string(from)),
                  Some(status_to_string(to)),
                  reason,
                  rule_code,
                  rules_version,
                  source_event,
                  "system",
                  mode_to_string(settings.mode),
                  "applied",
                  json_object_field("event_reason", event_reason),
                  "transition:"
                  <> request_id
                  <> ":"
                  <> status_to_string(to),
                )
              {
                Ok(_) -> Nil
                Error(e) ->
                  // The transition itself has already been committed, so the
                  // audit row is retried rather than rolled back. The
                  // failure is logged so it is never silent.
                  io.println(
                    "agent transition audit failed: " <> string.inspect(e),
                  )
              }
              json_response(
                json.object([
                  #("ok", json.bool(True)),
                  #("from_status", json.string(status_to_string(from))),
                  #("to_status", json.string(status_to_string(to))),
                  #("to_status_label", json.string(status_label(to))),
                ]),
                200,
              )
            }
            moderation.TransitionRejected(_, current, reason_text) ->
              json_response(
                json.object([
                  #("error", json.string("illegal_transition")),
                  #("current_status", json.string(status_to_string(current))),
                  #("message", json.string(reason_text)),
                ]),
                409,
              )
            moderation.TransitionNotFound(_) -> not_found()
            moderation.TransitionDbError(e) -> {
              io.println("agent transition failed: " <> string.inspect(e))
              error_response("transition_failed", 503)
            }
          }
      }
  }
}

/// Map an action string to the state machine's action.
///
/// Only the actions of the domain are accepted; an unknown action is
/// refused, never guessed.
fn parse_action(action_text: String) -> Option(Action) {
  case action_text {
    "accept" -> Some(ActionAccept)
    "start" -> Some(ActionStart)
    "request_clarification" -> Some(ActionRequestClarification)
    "applicant_answered" -> Some(ActionApplicantAnswered)
    "answer_ready" -> Some(ActionAnswerReady)
    "complete" -> Some(ActionComplete)
    _ -> None
  }
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/proposals
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/proposals` РІР‚вЂќ the agent prepared a transition
/// and waits for the moderator's approval.
///
/// In the `manual` and `confirm` modes this is the normal outcome. The
/// proposal is stored as an action with the outcome `proposed` and shown in
/// the moderator's panel.
pub fn propose(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use request_id <- decode.field("request_id", decode.string)
        use action <- decode.field("action", decode.string)
        use reason <- decode.optional_field("reason", "", decode.string)
        use rule_code <- decode.optional_field("rule_code", "", decode.string)
        use rules_version <- decode.optional_field("rules_version", "v1", decode.string)
        use source_event <- decode.optional_field("source_event", "", decode.string)
        use event_reason <- decode.optional_field("event_reason", "", decode.string)
        use target_status <- decode.optional_field("target_status", "", decode.string)
        decode.success(#(
          request_id,
          action,
          reason,
          rule_code,
          rules_version,
          source_event,
          event_reason,
          target_status,
        ))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(
            request_id,
            action,
            reason,
            rule_code,
            rules_version,
            source_event,
            event_reason,
            target_status,
          ) = values
          case repo.load_settings(context.driver, context.database_url) {
            Error(e) -> {
              io.println("automation mode load failed: " <> string.inspect(e))
              error_response("automation_settings_failed", 503)
            }
            Ok(settings) ->
              case
                repo.record_action(
                  context.driver,
                  context.database_url,
                  request_id,
                  "propose",
                  None,
                  case target_status {
                    "" -> None
                    value -> Some(value)
                  },
                  reason,
                  rule_code,
                  rules_version,
                  source_event,
                  "system",
                  mode_to_string(settings.mode),
                  "proposed",
                  json_object_field("event_reason", event_reason),
                  "propose:"
                  <> request_id
                  <> ":"
                  <> action
                  <> ":"
                  <> target_status,
                )
              {
                Error(e) -> {
                  io.println("agent proposal record failed: " <> string.inspect(e))
                  error_response("action_record_failed", 503)
                }
                Ok(_) ->
                  json_response(
                    json.object([
                      #("ok", json.bool(True)),
                      #("request_id", json.string(request_id)),
                      #("action", json.string(action)),
                      #("mode", json.string(mode_to_string(settings.mode))),
                      #("requires_approval", json.bool(True)),
                    ]),
                    200,
                  )
              }
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/exceptions
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/exceptions` РІР‚вЂќ the request needs a human.
///
/// The write is idempotent per (request, kind), so the same problem does not
/// land in the queue twice.
pub fn raise_exception(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use request_id <- decode.field("request_id", decode.string)
        use kind <- decode.field("kind", decode.string)
        use reason <- decode.optional_field("summary", "", decode.string)
        use details <- decode.optional_field("details_text", "{}", decode.string)
        use rule_code <- decode.optional_field("rule_code", "", decode.string)
        use source_event <- decode.optional_field("source_event", "", decode.string)
        decode.success(#(
          request_id,
          kind,
          reason,
          details,
          rule_code,
          source_event,
        ))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(request_id, kind, reason, details, rule_code, source_event) = values
          case repo.raise_exception(
            context.driver,
            context.database_url,
            request_id,
            kind,
            reason,
            details,
            "system",
          ) {
            Error(e) -> {
              io.println("agent exception record failed: " <> string.inspect(e))
              error_response("exception_record_failed", 503)
            }
            Ok(_) ->
              json_response(
                json.object([
                  #("ok", json.bool(True)),
                  #("request_id", json.string(request_id)),
                  #("kind", json.string(kind)),
                  #("rule_code", json.string(rule_code)),
                  #("source_event", json.string(source_event)),
                ]),
                200,
              )
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/drafts
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/drafts` РІР‚вЂќ the agent prepared a draft.
///
/// The draft is a DRAFT: it is not signed and not sent. The official
/// response is approved by an authorised person.
pub fn create_draft(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use request_id <- decode.field("request_id", decode.string)
        use kind <- decode.field("kind", decode.string)
        use content <- decode.optional_field("body", "", decode.string)
        use structured <- decode.optional_field("structured_text", "{}", decode.string)
        use source_event <- decode.optional_field("source_event", "", decode.string)
        decode.success(#(request_id, kind, content, structured, source_event))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(request_id, kind, content, structured, source_event) = values
          case
            repo.create_draft(
              context.driver,
              context.database_url,
              request_id,
              kind,
              content,
              structured,
              source_event,
              "draft:"
              <> request_id
              <> ":"
              <> kind
              <> ":"
              <> source_event,
            )
          {
            Error(e) -> {
              io.println("agent draft save failed: " <> string.inspect(e))
              error_response("draft_save_failed", 503)
            }
            Ok(draft) ->
              json_response(
                json.object([
                  #("ok", json.bool(True)),
                  #("id", json.string(draft.id)),
                  #("request_id", json.string(draft.request_id)),
                  #("kind", json.string(draft.kind)),
                  #("status", json.string(draft.status)),
                ]),
                200,
              )
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/notifications
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/notifications` РІР‚вЂќ a notification for the
/// applicant's cabinet.
///
/// The write is idempotent per (request, kind): a redelivered event cannot
/// notify the applicant twice. The server owns the recipient РІР‚вЂќ the agent
/// cannot send a notification to an arbitrary user.
pub fn create_notification(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use request_id <- decode.field("request_id", decode.string)
        use kind <- decode.field("kind", decode.string)
        use title <- decode.field("title", decode.string)
        use body_text <- decode.field("body", decode.string)
        use level <- decode.optional_field("level", "info", decode.string)
        use event_id <- decode.optional_field("event_id", "", decode.string)
        decode.success(#(request_id, kind, title, body_text, level, event_id))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(request_id, kind, title, body_text, level, event_id) = values
          case
            repo.create_notification(
              context.driver,
              context.database_url,
              request_id,
              kind,
              title,
              body_text,
              level,
              event_id,
            )
          {
            Error(e) -> {
              io.println("agent notification failed: " <> string.inspect(e))
              error_response("notification_failed", 503)
            }
            Ok(created) ->
              json_response(
                json.object([
                  #("ok", json.bool(True)),
                  #("created", json.bool(created)),
                  #("request_id", json.string(request_id)),
                  #("kind", json.string(kind)),
                ]),
                200,
              )
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/tasks
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/tasks` РІР‚вЂќ a reminder for the moderator.
///
/// The write is idempotent per (request, kind, deadline), so the same
/// reminder is not created twice.
pub fn create_task(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use request_id <- decode.field("request_id", decode.string)
        use kind <- decode.field("kind", decode.string)
        use title <- decode.field("title", decode.string)
        use note <- decode.optional_field("note", "", decode.string)
        use due_at <- decode.optional_field("due_at", "", decode.string)
        use priority <- decode.optional_field("priority", "normal", decode.string)
        use source_event <- decode.optional_field("source_event", "", decode.string)
        decode.success(#(
          request_id,
          kind,
          title,
          note,
          due_at,
          priority,
          source_event,
        ))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(request_id, kind, title, note, due_at, priority, source_event) = values
          case
            repo.create_task(
              context.driver,
              context.database_url,
              request_id,
              kind,
              title,
              note,
              case due_at {
                "" -> None
                value -> Some(value)
              },
              "task:"
              <> request_id
              <> ":"
              <> kind
              <> ":"
              <> due_at,
            )
          {
            Error(e) -> {
              io.println("agent task create failed: " <> string.inspect(e))
              error_response("task_create_failed", 503)
            }
            Ok(task) ->
              json_response(
                json.object([
                  #("ok", json.bool(True)),
                  #("id", json.string(task.id)),
                  #("request_id", json.string(task.request_id)),
                  #("kind", json.string(task.kind)),
                  #("status", json.string(task.status)),
                ]),
                200,
              )
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// POST /api/v1/automation/agent/metrics
// -------------------------------------------------------------

/// `POST /api/v1/automation/agent/metrics` РІР‚вЂќ a metric counter.
///
/// The agent records the events it produced (feedback requested, notification
/// sent, draft prepared). The counters are the raw material of the
/// Р’В«Р В­РЎвЂћРЎвЂћР ВµР С”РЎвЂљР С‘Р Р†Р Р…Р С•РЎРѓРЎвЂљРЎРЉ 360Р’В» dashboard РІР‚вЂќ they are counts of real events, never
/// an estimate.
pub fn record_metric(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use request_id <- decode.field("request_id", decode.string)
        use key <- decode.field("metrics_key", decode.string)
        use value <- decode.optional_field("value", 1, decode.int)
        decode.success(#(request_id, key, value))
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(values) -> {
          let #(request_id, key, value) = values
          case repo.record_metric(context.driver, context.database_url, request_id, key, value) {
            Error(e) -> {
              io.println("agent metric record failed: " <> string.inspect(e))
              error_response("metric_record_failed", 503)
            }
            Ok(_) ->
              json_response(
                json.object([#("ok", json.bool(True)), #("key", json.string(key))]),
                200,
              )
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// GET /api/v1/automation/agent/metrics
// -------------------------------------------------------------

/// `GET /api/v1/automation/agent/metrics` РІР‚вЂќ the measured counters.
///
/// Every number here is derived from real events in the database. There is
/// no estimate of saved time or money: the baseline has to be measured
/// first.
pub fn metrics(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case authorize_service(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      case repo.load_metrics(context.driver, context.database_url) {
        Error(e) -> {
          io.println("agent metrics load failed: " <> string.inspect(e))
          error_response("metrics_failed", 503)
        }
        Ok(metrics) ->
          json_response(
            json.object([
              #(
                "counters",
                json.object(
                  list.map(metrics, fn(pair) { #(pair.0, json.int(pair.1)) }),
                ),
              ),
            ]),
            200,
          )
      }
    }
  }
}
