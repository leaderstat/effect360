// services/frontend/src/effectivnost_360_lustre/api_client.gleam
//
// Thin HTTP client for the Effectivnost 360 API.
//
// Transport contract
// ------------------
// The browser is the only client of this module, and the API is reached
// through the nginx reverse proxy under the SAME origin. That means every
// request uses a RELATIVE path ("/api/v1/requests"), never an absolute
// "http://api:8000" — a Docker-internal hostname is not resolvable from
// the browser.
//
// Lustre's `Effect` is an opaque record
// (`{synchronous, before_paint, after_paint}`), so we cannot build one by
// hand from JavaScript. Instead this module exposes *plain callbacks* and
// the effect layer in `app.gleam` wraps them with `lustre/effect.from`,
// which accepts `fn(fn(message) -> Nil) -> Nil`. That is the only supported
// way to write a custom effect in Lustre 5.x.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option}

// -------------------------------------------------------------
// Domain types
// -------------------------------------------------------------

/// The lifecycle of a request, as reported by the API.
pub type RequestStatus {
  Draft
  Submitted
  InProgress
  Returned
  Completed
  OtherStatus(String)
}

/// A request as returned by `GET /api/v1/requests/{id}`.
pub type Request {
  Request(
    id: String,
    status: RequestStatus,
    request_type: Option(String),
    fields: Dict(String, String),
    submitted_at: Option(String),
    created_at: String,
  )
}

/// One requirement the server says is still missing. The `clause_id` and
/// `quote` are populated by the server from the approved regulation — the
/// client never invents them.
pub type MissingField {
  MissingField(
    field_name: String,
    required: Bool,
    conditional: Bool,
    reason: String,
    clause_id: String,
    /// Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ".
    /// The server sends it since migration 010; `None` on an older server.
    clause_ref: Option(String),
    quote: String,
  )
}

/// One blocking rule the server says forbids the submission.
///
/// Unlike `MissingField`, the field IS filled in — its value is the one
/// the regulation prohibits. The `action` is either "block_submit" (the
/// submission is forbidden) or "needs_employer_review" (the employer
/// has to confirm the case first).
pub type HardStopField {
  HardStopField(
    field_name: String,
    action: String,
    reason: String,
    clause_id: String,
    /// Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ".
    /// The server sends it since migration 010; `None` on an older server,
    /// in which case the UI falls back to the raw clause id.
    clause_ref: Option(String),
    quote: String,
    regulatory_ref_id: Option(String),
  )
}

/// The result of `POST /api/v1/requests/{id}/submit`.
pub type SubmitOutcome {
  SubmitSucceeded(String)
  SubmitIncomplete(List(MissingField))
  /// The submission is forbidden by a regulation. The list carries the
  /// blocking rules with their norm quotes.
  SubmitBlocked(List(HardStopField))
  SubmitAlreadyDone
  SubmitNotFound
  SubmitConflict(String)
  SubmitServerError(Int, String)
  SubmitInvalid(String)
}

// -------------------------------------------------------------
// HTTP plumbing (FFI)
// -------------------------------------------------------------

/// Perform an HTTP request and hand the raw response to the callback.
///
/// `method` is "GET" or "POST". `body` is "" for GET. The success callback
/// receives `(status, text)` where `text` is the raw response body; the
/// failure callback receives a reason string (network error).
///
/// The JS side resolves relative URLs against the current origin, which is
/// exactly what we want: the nginx image proxies `/api/` to the Gleam API.
@external(javascript, "./http.mjs", "request")
pub fn request(
  method: String,
  path: String,
  body: String,
  on_success: fn(Int, String) -> Nil,
  on_failure: fn(String) -> Nil,
) -> Nil

/// The idempotency key generator. Kept in JS because `crypto.randomUUID`
/// is a browser API that Gleam's stdlib does not wrap for the JS target.
@external(javascript, "./random_key.mjs", "random_key")
pub fn random_key() -> String

// -------------------------------------------------------------
// Endpoint wrappers
// -------------------------------------------------------------

/// `POST /api/v1/requests` — create (or reuse) a draft.
///
/// The callback receives `Ok(request_id)` or `Error(message)`.
pub fn create_draft(
  text: String,
  idempotency_key: String,
  on_result: fn(Result(String, String)) -> Nil,
) -> Nil {
  let body =
    json.object([
      #("idempotency_key", json.string(idempotency_key)),
      #("text", json.string(text)),
    ])
    |> json.to_string
  request(
    "POST",
    "/api/v1/requests",
    body,
    fn(status, response_body) {
      case status {
        200 | 201 | 202 ->
          case json.parse(response_body, draft_decoder()) {
            Ok(#(request_id, _)) -> on_result(Ok(request_id))
            Error(_) -> on_result(Error("Не удалось разобрать ответ сервера"))
          }
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `GET /api/v1/requests/{id}` — load a request with its current status.
pub fn load_request(
  request_id: String,
  on_result: fn(Result(Request, String)) -> Nil,
) -> Nil {
  request(
    "GET",
    "/api/v1/requests/" <> request_id,
    "",
    fn(status, body) {
      case status {
        200 ->
          case json.parse(body, request_decoder()) {
            Ok(req) -> on_result(Ok(req))
            Error(_) -> on_result(Error("Не удалось разобрать данные заявки"))
          }
        404 -> on_result(Error("Заявка не найдена"))
        _ -> on_result(Error(server_error_message(status, body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `POST /api/v1/requests/{id}/submit` — run the deterministic completeness
/// gate and, if it passes, transition the request to `submitted`.
pub fn submit_request(
  request_id: String,
  on_result: fn(Result(SubmitOutcome, String)) -> Nil,
) -> Nil {
  request(
    "POST",
    "/api/v1/requests/" <> request_id <> "/submit",
    "",
    fn(status, body) { on_result(Ok(classify_submit(status, body))) },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Response classification
// -------------------------------------------------------------

/// Classify a submit response into a structured outcome.
///
/// This is pure and is unit-tested directly: the browser must never show a
/// fake success, so the mapping from HTTP status to outcome is part of the
/// contract.
pub fn classify_submit(status: Int, body: String) -> SubmitOutcome {
  case status {
    200 ->
      case json.parse(body, submitted_decoder()) {
        Ok(submitted_at) -> SubmitSucceeded(submitted_at)
        // A 200 without a timestamp is still a success (the API always
        // sends one, but we do not fail the UI over a missing field).
        Error(_) -> SubmitSucceeded("")
      }
    409 ->
      case json.parse(body, conflict_decoder()) {
        Ok(current_status) -> SubmitConflict(current_status)
        Error(_) -> SubmitConflict("submitted")
      }
    404 -> SubmitNotFound
    422 ->
      case json.parse(body, blocked_decoder()) {
        // A hard stop is more specific than a missing field: the server
        // answers 422 with `error: "hard_stop"` and the list of the
        // blocking rules.
        Ok(#(True, hits)) -> SubmitBlocked(hits)
        Ok(#(False, _)) ->
          case json.parse(body, missing_decoder()) {
            Ok(items) -> SubmitIncomplete(items)
            Error(_) ->
              SubmitInvalid("Ответ 422 не содержит списка missing")
          }
        Error(_) ->
          case json.parse(body, missing_decoder()) {
            Ok(items) -> SubmitIncomplete(items)
            Error(_) ->
              SubmitInvalid("Ответ 422 не содержит списка missing")
          }
      }
    _ -> SubmitServerError(status, body)
  }
}

// -------------------------------------------------------------
// Decoders
// -------------------------------------------------------------

pub fn draft_decoder() -> decode.Decoder(#(String, Bool)) {
  use request_id <- decode.field("request_id", decode.string)
  use created <- decode.optional_field("created", False, decode.bool)
  decode.success(#(request_id, created))
}

fn submitted_decoder() -> decode.Decoder(String) {
  use submitted_at <- decode.field("submitted_at", decode.string)
  decode.success(submitted_at)
}

fn conflict_decoder() -> decode.Decoder(String) {
  use current_status <- decode.optional_field(
    "current_status",
    "submitted",
    decode.string,
  )
  decode.success(current_status)
}

fn missing_decoder() -> decode.Decoder(List(MissingField)) {
  use items <- decode.field("missing", decode.list(missing_field_decoder()))
  decode.success(items)
}

/// Decode a 422 answer that may be a hard stop or a plain incomplete
/// request. The first element of the tuple tells the two apart.
fn blocked_decoder() -> decode.Decoder(#(Bool, List(HardStopField))) {
  use error_code <- decode.optional_field("error", "", decode.string)
  use items <- decode.optional_field(
    "hard_stops",
    [],
    decode.list(hard_stop_field_decoder()),
  )
  decode.success(#(error_code == "hard_stop", items))
}

pub fn hard_stop_field_decoder() -> decode.Decoder(HardStopField) {
  use field_name <- decode.field("field_name", decode.string)
  use action <- decode.optional_field("action", "block_submit", decode.string)
  use reason <- decode.optional_field("reason", "", decode.string)
  use clause_id <- decode.optional_field("clause_id", "", decode.string)
  use clause_ref <- decode.optional_field(
    "clause_ref",
    option.None,
    decode.optional(decode.string),
  )
  use quote <- decode.optional_field("quote", "", decode.string)
  use regulatory_ref_id <- decode.optional_field(
    "regulatory_ref_id",
    option.None,
    decode.optional(decode.string),
  )
  decode.success(HardStopField(
    field_name: field_name,
    action: action,
    reason: reason,
    clause_id: clause_id,
    clause_ref: clause_ref,
    quote: quote,
    regulatory_ref_id: regulatory_ref_id,
  ))
}

pub fn missing_field_decoder() -> decode.Decoder(MissingField) {
  use field_name <- decode.field("field_name", decode.string)
  use required <- decode.optional_field("required", True, decode.bool)
  use conditional <- decode.optional_field("conditional", False, decode.bool)
  use reason <- decode.optional_field("reason", "", decode.string)
  use clause_id <- decode.optional_field("clause_id", "", decode.string)
  use clause_ref <- decode.optional_field(
    "clause_ref",
    option.None,
    decode.optional(decode.string),
  )
  use quote <- decode.optional_field("quote", "", decode.string)
  decode.success(MissingField(
    field_name: field_name,
    required: required,
    conditional: conditional,
    reason: reason,
    clause_id: clause_id,
    clause_ref: clause_ref,
    quote: quote,
  ))
}

fn request_decoder() -> decode.Decoder(Request) {
  use id <- decode.field("id", decode.string)
  use status_str <- decode.field("status", decode.string)
  // NOTE: the API answers `null` for a request that is not attached to a
  // request type yet, and `null` for `submitted_at` while the request is
  // still a draft. `decode.optional_field/3` only substitutes the default
  // when the KEY IS MISSING — a present `null` is decoded by the inner
  // decoder and fails there. The inner decoder therefore has to be
  // `decode.optional(decode.string)` so that `null` becomes `None`.
  // Before this fix the whole request failed to decode, `model.request`
  // stayed `None`, and pressing "Отправить заявку" silently did nothing.
  use request_type <- decode.optional_field(
    "request_type",
    option.None,
    decode.optional(decode.string),
  )
  use fields <- decode.field("fields", decode.dict(decode.string, decode.string))
  use submitted_at <- decode.optional_field(
    "submitted_at",
    option.None,
    decode.optional(decode.string),
  )
  use created_at <- decode.field("created_at", decode.string)
  decode.success(Request(
    id: id,
    status: parse_status(status_str),
    request_type: request_type,
    fields: fields,
    submitted_at: submitted_at,
    created_at: created_at,
  ))
}

pub fn parse_status(s: String) -> RequestStatus {
  case s {
    "draft" -> Draft
    "submitted" -> Submitted
    "in_progress" -> InProgress
    "returned" -> Returned
    "completed" -> Completed
    other -> OtherStatus(other)
  }
}

pub fn status_to_string(status: RequestStatus) -> String {
  case status {
    Draft -> "draft"
    Submitted -> "submitted"
    InProgress -> "in_progress"
    Returned -> "returned"
    Completed -> "completed"
    OtherStatus(other) -> other
  }
}

pub fn non_empty(s: String) -> Option(String) {
  case s {
    "" -> option.None
    other -> option.Some(other)
  }
}

/// Turn a server error body into a human-readable message.
pub fn server_error_message(status: Int, body: String) -> String {
  case json.parse(body, error_decoder()) {
    Ok(code) -> "Ошибка сервера (" <> status_string(status) <> "): " <> code
    Error(_) -> "Ошибка сервера (" <> status_string(status) <> ")"
  }
}

fn error_decoder() -> decode.Decoder(String) {
  use code <- decode.field("error", decode.string)
  decode.success(code)
}

fn status_string(status: Int) -> String {
  case status {
    400 -> "400"
    401 -> "401"
    403 -> "403"
    404 -> "404"
    409 -> "409"
    422 -> "422"
    500 -> "500"
    502 -> "502"
    503 -> "503"
    _ -> "HTTP " <> int.to_string(status)
  }
}
