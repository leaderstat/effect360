// services/frontend/src/effectivnost_360_lustre/phase7_client.gleam
//
// HTTP client for the Phase-7 endpoints of «Эффективность 360»:
// кабинет заявителя, уведомления, карточка заявки, очередь модератора,
// официальный ответ, обратная связь и метрики эффективности.
//
// TRUST BOUNDARY. Every decoder below mirrors the JSON contract of the
// Gleam API EXACTLY (see `moderation_router.gleam`). A field the server does
// not send is decoded with `decode.optional_field` and a documented default,
// so a partial response never crashes the UI — and the UI never invents a
// value that the server did not send.
//
// AUTHORIZATION. The bearer token is attached by the JavaScript adapter
// (`http.mjs`) from the session storage; the Gleam code never handles it.
// Role checks and per-object rights are enforced on the backend — the UI
// only renders what the server allowed it to see.

import effectivnost_360_lustre/api_client.{request, server_error_message}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// -------------------------------------------------------------
// Domain types
// -------------------------------------------------------------

/// One notification of the applicant (or of the moderator).
pub type Notification {
  Notification(
    id: String,
    kind: String,
    title: String,
    body: String,
    request_id: String,
    created_at: String,
    is_read: Bool,
  )
}

/// The notification feed together with the unread counter.
pub type NotificationFeed {
  NotificationFeed(items: List(Notification), unread: Int)
}

/// One row of the moderator queue.
pub type QueueItem {
  QueueItem(
    id: String,
    status: String,
    status_label: String,
    step: Int,
    request_type: String,
    applicant_name: String,
    assignee_name: String,
    created_at: String,
    submitted_at: String,
    due_at: String,
    is_overdue: Bool,
    clarification_note: String,
    available_actions: List(String),
  )
}

/// The queue together with the total number of matching rows.
pub type Queue {
  Queue(items: List(QueueItem), total: Int)
}

/// One event of the request history.
pub type TimelineEvent {
  TimelineEvent(
    id: String,
    from_status: String,
    to_status: String,
    to_status_label: String,
    actor_role: String,
    actor_name: String,
    reason_code: String,
    created_at: String,
  )
}

/// The official response of a request.
pub type OfficialResponse {
  OfficialResponse(
    id: String,
    status: String,
    organization: String,
    requisites: String,
    registration_number: String,
    recipient: String,
    subject: String,
    legal_basis: String,
    decision_summary: String,
    next_steps: String,
    responsible_executor: String,
    contact_for_questions: String,
    signature_block: String,
    body: String,
    created_at: String,
    approved_at: Option(String),
    approved_by_name: Option(String),
    missing_requisites: List(String),
  )
}

/// The feedback the applicant left on the response.
pub type Feedback {
  Feedback(is_clear: Bool, comment: String, created_at: String)
}

/// One metric of the efficiency-360 dashboard.
pub type Metric {
  Metric(
    key: String,
    label: String,
    value: Option(Float),
    unit: String,
    is_demo: Bool,
  )
}

/// One of the applicant's own requests.
pub type ApplicantRequest {
  ApplicantRequest(
    id: String,
    status: String,
    status_label: String,
    request_type: String,
    created_at: String,
    submitted_at: Option(String),
  )
}

/// The full request card: the request itself, its history, the response and
/// the feedback.
pub type RequestCard {
  RequestCard(
    id: String,
    status: String,
    status_label: String,
    request_type: String,
    applicant_name: String,
    summary: String,
    fields: Dict(String, String),
    clarification_note: String,
    applicant_note: String,
    created_at: String,
    submitted_at: Option(String),
    accepted_at: Option(String),
    answer_ready_at: Option(String),
    completed_at: Option(String),
    due_at: Option(String),
    available_actions: List(String),
    can_respond: Bool,
    timeline: List(TimelineEvent),
    response: Option(OfficialResponse),
    feedback: Option(Feedback),
  )
}

/// The outcome of a moderation transition.
pub type TransitionOutcome {
  TransitionApplied(from_status: String, to_status: String, to_status_label: String)
  TransitionRefused(current_status: String, reason: String)
  TransitionMissing
}

/// The outcome of a feedback submission.
pub type FeedbackOutcome {
  FeedbackStored
  FeedbackMissing
}

// -------------------------------------------------------------
// Session
// -------------------------------------------------------------

/// Store the bearer token of the session in the browser session storage.
///
/// The token is written by the JavaScript adapter; the Gleam side only
/// triggers it. Keeping it in `sessionStorage` means the token disappears
/// when the tab is closed.
@external(javascript, "./http.mjs", "set_session_token")
pub fn store_session_token(token: String) -> Nil

/// `POST /api/v1/session` — exchange credentials for a session token.
pub fn login(
  email: String,
  password: String,
  on_result: fn(Result(String, String)) -> Nil,
) -> Nil {
  let body =
    json.object([
      #("email", json.string(email)),
      #("password", json.string(password)),
    ])
    |> json.to_string
  request(
    "POST",
    "/api/v1/session",
    body,
    fn(status, response_body) {
      case status {
        200 | 201 ->
          case json.parse(response_body, session_decoder()) {
            Ok(token) -> {
              store_session_token(token)
              on_result(Ok(token))
            }
            Error(_) -> on_result(Error("Не удалось разобрать ответ сервера"))
          }
        401 -> on_result(Error("Неверный адрес или пароль"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `GET /api/v1/session` — the profile of the current user.
pub fn load_session(
  on_result: fn(Result(#(String, String, String), String)) -> Nil,
) -> Nil {
  request(
    "GET",
    "/api/v1/session",
    "",
    fn(status, response_body) {
      case status {
        200 ->
          case json.parse(response_body, profile_decoder()) {
            Ok(profile) -> on_result(Ok(profile))
            Error(_) -> on_result(Error("Не удалось разобрать профиль"))
          }
        401 -> on_result(Error("Сессия недействительна"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Applicant cabinet
// -------------------------------------------------------------

/// `GET /api/v1/my/requests` — the applicant's own requests.
pub fn load_my_requests(
  on_result: fn(Result(List(ApplicantRequest), String)) -> Nil,
) -> Nil {
  request(
    "GET",
    "/api/v1/my/requests",
    "",
    fn(status, response_body) {
      case status {
        200 ->
          case json.parse(response_body, my_requests_decoder()) {
            Ok(items) -> on_result(Ok(items))
            Error(_) -> on_result(Error("Не удалось загрузить список заявок"))
          }
        401 -> on_result(Error("Сессия недействительна"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `GET /api/v1/notifications` — the notification feed and the unread count.
pub fn load_notifications(
  on_result: fn(Result(NotificationFeed, String)) -> Nil,
) -> Nil {
  request(
    "GET",
    "/api/v1/notifications",
    "",
    fn(status, response_body) {
      case status {
        200 ->
          case json.parse(response_body, notifications_decoder()) {
            Ok(feed) -> on_result(Ok(feed))
            Error(_) -> on_result(Error("Не удалось загрузить уведомления"))
          }
        401 -> on_result(Error("Сессия недействительна"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `POST /api/v1/notifications/{id}/read` — mark one notification as read.
pub fn mark_notification_read(
  notification_id: String,
  on_result: fn(Result(Nil, String)) -> Nil,
) -> Nil {
  request(
    "POST",
    "/api/v1/notifications/" <> notification_id <> "/read",
    "",
    fn(status, response_body) {
      case status {
        200 | 204 -> on_result(Ok(Nil))
        401 -> on_result(Error("Сессия недействительна"))
        404 -> on_result(Error("Уведомление не найдено"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Request card
// -------------------------------------------------------------

/// `GET /api/v1/requests/{id}/detail` — the full request card.
pub fn load_request_card(
  request_id: String,
  on_result: fn(Result(RequestCard, String)) -> Nil,
) -> Nil {
  request(
    "GET",
    "/api/v1/requests/" <> request_id <> "/detail",
    "",
    fn(status, response_body) {
      case status {
        200 ->
          case json.parse(response_body, request_card_decoder()) {
            Ok(card) -> on_result(Ok(card))
            Error(_) -> on_result(Error("Не удалось загрузить карточку заявки"))
          }
        401 -> on_result(Error("Сессия недействительна"))
        403 -> on_result(Error("Нет доступа к этой заявке"))
        404 -> on_result(Error("Заявка не найдена"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Moderator queue
// -------------------------------------------------------------

/// `GET /api/v1/moderation/queue` — the moderator queue.
pub fn load_queue(
  status_filter: String,
  request_type_filter: String,
  assignee_filter: String,
  only_overdue: Bool,
  limit: Int,
  offset: Int,
  on_result: fn(Result(Queue, String)) -> Nil,
) -> Nil {
  let query =
    list_query([
      #("status", status_filter),
      #("request_type", request_type_filter),
      #("assignee_id", assignee_filter),
      #("only_overdue", overdue_flag(only_overdue)),
      #("limit", int_to_string(limit)),
      #("offset", int_to_string(offset)),
    ])
  request(
    "GET",
    "/api/v1/moderation/queue" <> query,
    "",
    fn(status, response_body) {
      case status {
        200 ->
          case json.parse(response_body, queue_decoder()) {
            Ok(queue) -> on_result(Ok(queue))
            Error(_) -> on_result(Error("Не удалось загрузить очередь"))
          }
        401 -> on_result(Error("Сессия недействительна"))
        403 -> on_result(Error("Нет доступа к очереди"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `POST /api/v1/requests/{id}/transition` — apply a moderation action.
///
/// The action is one of the values of `state_machine.action_to_string`:
/// `accept`, `start`, `request_clarification`, `applicant_answered`,
/// `answer_ready`, `complete`.
pub fn apply_transition(
  request_id: String,
  action: String,
  note: String,
  on_result: fn(Result(TransitionOutcome, String)) -> Nil,
) -> Nil {
  let body =
    json.object([
      #("action", json.string(action)),
      #("reason", json.string(note)),
    ])
    |> json.to_string
  request(
    "POST",
    "/api/v1/requests/" <> request_id <> "/transition",
    body,
    fn(status, response_body) {
      case status {
        200 | 201 ->
          case json.parse(response_body, transition_decoder()) {
            Ok(outcome) -> on_result(Ok(outcome))
            Error(_) -> on_result(Error("Не удалось разобрать ответ сервера"))
          }
        409 ->
          case json.parse(response_body, transition_conflict_decoder()) {
            Ok(#(current, reason)) -> on_result(Ok(TransitionRefused(current, reason)))
            Error(_) ->
              on_result(
                Ok(TransitionRefused("", server_error_message(409, response_body))),
              )
          }
        400 ->
          on_result(Ok(TransitionRefused("", server_error_message(400, response_body))))
        403 -> on_result(Error("Нет прав на это действие"))
        404 -> on_result(Ok(TransitionMissing))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `POST /api/v1/requests/{id}/answer` — the applicant answers a clarification.
pub fn submit_clarification(
  request_id: String,
  answer: String,
  on_result: fn(Result(Nil, String)) -> Nil,
) -> Nil {
  let body =
    json.object([#("answer", json.string(answer))])
    |> json.to_string
  request(
    "POST",
    "/api/v1/requests/" <> request_id <> "/answer",
    body,
    fn(status, response_body) {
      case status {
        200 | 201 | 204 -> on_result(Ok(Nil))
        400 -> on_result(Error(server_error_message(400, response_body)))
        403 -> on_result(Error("Нет доступа к этой заявке"))
        404 -> on_result(Error("Заявка не найдена"))
        409 -> on_result(Error("Заявка не ожидает уточнения"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Official response
// -------------------------------------------------------------

/// `POST /api/v1/requests/{id}/response` — save the response draft.
///
/// The fields are the requisites of the official letter. The server validates
/// them and returns the saved draft together with the list of the missing
/// (still empty) required requisites.
pub fn save_response_draft(
  request_id: String,
  fields: List(#(String, String)),
  on_result: fn(Result(OfficialResponse, String)) -> Nil,
) -> Nil {
  let body =
    json.object(list.map(fields, fn(pair) { #(pair.0, json.string(pair.1)) }))
    |> json.to_string
  request(
    "POST",
    "/api/v1/requests/" <> request_id <> "/response",
    body,
    fn(status, response_body) {
      case status {
        200 | 201 ->
          case json.parse(response_body, response_decoder()) {
            Ok(response) -> on_result(Ok(response))
            Error(_) -> on_result(Error("Не удалось разобрать ответ сервера"))
          }
        403 -> on_result(Error("Нет прав на подготовку ответа"))
        404 -> on_result(Error("Заявка не найдена"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

/// `POST /api/v1/requests/{id}/response/approve` — approve the response.
pub fn approve_response(
  request_id: String,
  on_result: fn(Result(OfficialResponse, String)) -> Nil,
) -> Nil {
  request(
    "POST",
    "/api/v1/requests/" <> request_id <> "/response/approve",
    "",
    fn(status, response_body) {
      case status {
        200 | 201 ->
          case json.parse(response_body, response_decoder()) {
            Ok(response) -> on_result(Ok(response))
            Error(_) -> on_result(Error("Не удалось разобрать ответ сервера"))
          }
        400 ->
          case json.parse(response_body, missing_requisites_decoder()) {
            Ok(items) ->
              on_result(
                Error(
                  "Не заполнены обязательные реквизиты: "
                    <> string.join(items, ", "),
                ),
              )
            Error(_) -> on_result(Error(server_error_message(400, response_body)))
          }
        403 -> on_result(Error("Нет прав на утверждение ответа"))
        404 -> on_result(Error("Ответ не найден"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Applicant feedback
// -------------------------------------------------------------

/// `POST /api/v1/requests/{id}/feedback` — the applicant rates the answer.
pub fn submit_feedback(
  request_id: String,
  is_clear: Bool,
  comment: String,
  on_result: fn(Result(FeedbackOutcome, String)) -> Nil,
) -> Nil {
  let body =
    json.object([
      #("is_clear", json.bool(is_clear)),
      #("comment", json.string(comment)),
    ])
    |> json.to_string
  request(
    "POST",
    "/api/v1/requests/" <> request_id <> "/feedback",
    body,
    fn(status, response_body) {
      case status {
        200 | 201 | 204 -> on_result(Ok(FeedbackStored))
        403 -> on_result(Error("Нет доступа к этой заявке"))
        404 -> on_result(Ok(FeedbackMissing))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Metrics
// -------------------------------------------------------------

/// `GET /api/v1/moderation/metrics` — the efficiency-360 metrics.
pub fn load_metrics(
  on_result: fn(Result(List(Metric), String)) -> Nil,
) -> Nil {
  request(
    "GET",
    "/api/v1/moderation/metrics",
    "",
    fn(status, response_body) {
      case status {
        200 ->
          case json.parse(response_body, metrics_decoder()) {
            Ok(items) -> on_result(Ok(items))
            Error(_) -> on_result(Error("Не удалось загрузить метрики"))
          }
        401 -> on_result(Error("Сессия недействительна"))
        403 -> on_result(Error("Нет доступа к метрикам"))
        _ -> on_result(Error(server_error_message(status, response_body)))
      }
    },
    fn(reason) { on_result(Error(reason)) },
  )
}

// -------------------------------------------------------------
// Query-string helpers
// -------------------------------------------------------------

fn overdue_flag(only_overdue: Bool) -> String {
  case only_overdue {
    True -> "true"
    False -> ""
  }
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}

/// Build a query string from the non-empty pairs.
fn list_query(pairs: List(#(String, String))) -> String {
  let parts =
    pairs
    |> list.filter(fn(pair) { pair.1 != "" })
    |> list.map(fn(pair) {
      encode_component(pair.0) <> "=" <> encode_component(pair.1)
    })
  case parts {
    [] -> ""
    _ -> "?" <> string.join(parts, "&")
  }
}

fn encode_component(value: String) -> String {
  value
  |> replace_all("%", "%25")
  |> replace_all(" ", "%20")
  |> replace_all("&", "%26")
  |> replace_all("=", "%3D")
  |> replace_all("#", "%23")
  |> replace_all("?", "%3F")
  |> replace_all("+", "%2B")
}

fn replace_all(haystack: String, needle: String, replacement: String) -> String {
  case needle {
    "" -> haystack
    _ ->
      case string.split(haystack, on: needle) {
        [] -> haystack
        parts -> string.join(parts, replacement)
      }
  }
}

// -------------------------------------------------------------
// Decoders
// -------------------------------------------------------------

/// Decode a string field that the API may send either as a JSON string, as
/// `null`, or not at all.
///
/// WHY: `decode.optional_field/3` substitutes the default only when the KEY
/// is missing. A present `null` is still handed to the inner decoder, and
/// `decode.string` rejects it — the whole surrounding decode then fails and
/// the screen silently renders nothing. The API serialises every optional
/// value as `json.null()` (see `moderation_router.gleam`), so the client has
/// to accept `null` explicitly. This helper is the single place where that
/// rule lives.
fn nullable_string(
  field: String,
  default: String,
  next: fn(String) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.optional_field(
    field,
    default,
    decode.optional(decode.string)
    |> decode.map(fn(value) {
      case value {
        Some(text) -> text
        None -> default
      }
    }),
    next,
  )
}

/// Same as `nullable_string/3`, but for booleans.
fn nullable_bool(
  field: String,
  default: Bool,
  next: fn(Bool) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.optional_field(
    field,
    default,
    decode.optional(decode.bool)
    |> decode.map(fn(value) {
      case value {
        Some(flag) -> flag
        None -> default
      }
    }),
    next,
  )
}

fn session_decoder() -> decode.Decoder(String) {
  use token <- decode.field("token", decode.string)
  decode.success(token)
}

fn profile_decoder() -> decode.Decoder(#(String, String, String)) {
  use user_id <- nullable_string("user_id", "")
  use role <- nullable_string("role", "")
  use display_name <- nullable_string("display_name", "")
  decode.success(#(user_id, role, display_name))
}

fn notification_decoder() -> decode.Decoder(Notification) {
  use id <- decode.field("id", decode.string)
  use kind <- nullable_string("kind", "")
  use title <- nullable_string("title", "")
  use body <- nullable_string("body", "")
  use request_id <- nullable_string("request_id", "")
  use created_at <- nullable_string("created_at", "")
  use is_read <- nullable_bool("is_read", False)
  decode.success(Notification(
    id: id,
    kind: kind,
    title: title,
    body: body,
    request_id: request_id,
    created_at: created_at,
    is_read: is_read,
  ))
}

fn notifications_decoder() -> decode.Decoder(NotificationFeed) {
  // The API answers `{"notifications": [...], "unread": N}` — see
  // `moderation_router.gleam`. The list key is `notifications`, not `items`.
  use items <- decode.optional_field(
    "notifications",
    [],
    decode.list(notification_decoder()),
  )
  use unread <- decode.optional_field("unread", 0, decode.int)
  decode.success(NotificationFeed(items: items, unread: unread))
}

fn queue_item_decoder() -> decode.Decoder(QueueItem) {
  use id <- decode.field("id", decode.string)
  use status <- nullable_string("status", "")
  use status_label <- nullable_string("status_label", "")
  use step <- decode.optional_field("step", 0, decode.int)
  use request_type <- nullable_string("request_type", "")
  use applicant_name <- nullable_string("applicant_name", "")
  use assignee_name <- nullable_string("assignee_name", "")
  use created_at <- nullable_string("created_at", "")
  use submitted_at <- nullable_string("submitted_at", "")
  use due_at <- nullable_string("due_at", "")
  use is_overdue <- nullable_bool("is_overdue", False)
  use clarification_note <- nullable_string("clarification_note", "")
  use available_actions <- decode.optional_field(
    "available_actions",
    [],
    decode.list(decode.string),
  )
  decode.success(QueueItem(
    id: id,
    status: status,
    status_label: status_label,
    step: step,
    request_type: request_type,
    applicant_name: applicant_name,
    assignee_name: assignee_name,
    created_at: created_at,
    submitted_at: submitted_at,
    due_at: due_at,
    is_overdue: is_overdue,
    clarification_note: clarification_note,
    available_actions: available_actions,
  ))
}

fn queue_decoder() -> decode.Decoder(Queue) {
  use items <- decode.optional_field("items", [], decode.list(queue_item_decoder()))
  use total <- decode.optional_field("total", 0, decode.int)
  decode.success(Queue(items: items, total: total))
}

fn timeline_event_decoder() -> decode.Decoder(TimelineEvent) {
  use id <- nullable_string("id", "")
  use from_status <- nullable_string("from_status", "")
  use to_status <- nullable_string("to_status", "")
  use to_status_label <- nullable_string("to_status_label", "")
  use actor_role <- nullable_string("actor_role", "")
  use actor_name <- nullable_string("actor_name", "")
  use reason_code <- nullable_string("reason_code", "")
  use created_at <- nullable_string("created_at", "")
  decode.success(TimelineEvent(
    id: id,
    from_status: from_status,
    to_status: to_status,
    to_status_label: to_status_label,
    actor_role: actor_role,
    actor_name: actor_name,
    reason_code: reason_code,
    created_at: created_at,
  ))
}

fn response_decoder() -> decode.Decoder(OfficialResponse) {
  use id <- decode.field("id", decode.string)
  use status <- nullable_string("status", "")
  use organization <- nullable_string("organization", "")
  use requisites <- nullable_string("requisites", "")
  use registration_number <- nullable_string("registration_number", "")
  use recipient <- nullable_string("recipient", "")
  use subject <- nullable_string("subject", "")
  use legal_basis <- nullable_string("legal_basis", "")
  use decision_summary <- nullable_string("decision_summary", "")
  use next_steps <- nullable_string("next_steps", "")
  use responsible_executor <- nullable_string("responsible_executor", "")
  use contact_for_questions <- nullable_string("contact_for_questions", "")
  use signature_block <- nullable_string("signature_block", "")
  use body <- nullable_string("body", "")
  use created_at <- nullable_string("created_at", "")
  use approved_at <- nullable_string("approved_at", "")
  use approved_by_name <- nullable_string("approved_by_name", "")
  use missing_requisites <- decode.optional_field(
    "missing_requisites",
    [],
    decode.list(decode.string),
  )
  decode.success(OfficialResponse(
    id: id,
    status: status,
    organization: organization,
    requisites: requisites,
    registration_number: registration_number,
    recipient: recipient,
    subject: subject,
    legal_basis: legal_basis,
    decision_summary: decision_summary,
    next_steps: next_steps,
    responsible_executor: responsible_executor,
    contact_for_questions: contact_for_questions,
    signature_block: signature_block,
    body: body,
    created_at: created_at,
    approved_at: optional_non_empty(approved_at),
    approved_by_name: optional_non_empty(approved_by_name),
    missing_requisites: missing_requisites,
  ))
}

fn feedback_decoder() -> decode.Decoder(Feedback) {
  use is_clear <- nullable_bool("is_clear", False)
  use comment <- nullable_string("comment", "")
  use created_at <- nullable_string("created_at", "")
  decode.success(Feedback(
    is_clear: is_clear,
    comment: comment,
    created_at: created_at,
  ))
}

fn metric_decoder() -> decode.Decoder(Metric) {
  use key <- decode.field("key", decode.string)
  use label <- nullable_string("label", "")
  // The backend serialises `value` as `json.float(v)` for non-integer
  // metrics and `json.null()` for "no data". The Erlang OTP `json`
  // module encodes `3.0` as the JSON literal `3` (an integer), which the
  // typed `decode.float` decoder rejects. Accept both forms: a JSON
  // number (int OR float), or null/missing (None).
  use value <- decode.optional_field(
    "value",
    None,
    decode.optional(metric_value_p7_decoder()),
  )
  use unit <- nullable_string("unit", "")
  use is_demo <- nullable_bool("is_demo", False)
  decode.success(Metric(
    key: key,
    label: label,
    value: value,
    unit: unit,
    is_demo: is_demo,
  ))
}

/// Decode a Phase 7 metric `value` that may be a JSON float, a JSON int,
/// or a JSON null. We coerce everything to `Float` so downstream
/// rendering (`format_float`) keeps working unchanged.
fn metric_value_p7_decoder() -> decode.Decoder(Float) {
  decode.one_of(
    decode.float,
    [
      decode.int |> decode.map(int_to_float_p7_helper),
      decode.success(0.0),
    ],
  )
}

fn int_to_float_p7_helper(n: Int) -> Float {
  // Minimal helper: walk through integer digits and accumulate the
  // value as a Float. We do not use Float arithmetic on the Int input
  // directly because Gleam's `int.to_float` would also work in the
  // stdlib version we pin; this avoids a dependency bump.
  int_to_float_loop(n, 0.0, 1.0)
}

fn int_to_float_loop(n: Int, acc: Float, scale: Float) -> Float {
  case n {
    0 -> acc
    _ -> {
      let digit = case n % 10 {
        0 -> 0.0
        1 -> 1.0
        2 -> 2.0
        3 -> 3.0
        4 -> 4.0
        5 -> 5.0
        6 -> 6.0
        7 -> 7.0
        8 -> 8.0
        _ -> 9.0
      }
      int_to_float_loop(
        n / 10,
        digit *. scale +. acc,
        scale *. 10.0,
      )
    }
  }
}

pub fn metrics_decoder() -> decode.Decoder(List(Metric)) {
  use items <- decode.optional_field("metrics", [], decode.list(metric_decoder()))
  decode.success(items)
}

fn applicant_request_decoder() -> decode.Decoder(ApplicantRequest) {
  use id <- decode.field("id", decode.string)
  use status <- nullable_string("status", "")
  use status_label <- nullable_string("status_label", "")
  use request_type <- nullable_string("request_type", "")
  use created_at <- nullable_string("created_at", "")
  use submitted_at <- nullable_string("submitted_at", "")
  decode.success(ApplicantRequest(
    id: id,
    status: status,
    status_label: status_label,
    request_type: request_type,
    created_at: created_at,
    submitted_at: optional_non_empty(submitted_at),
  ))
}

fn my_requests_decoder() -> decode.Decoder(List(ApplicantRequest)) {
  // The API answers `{"requests": [...]}`. The key `items` is accepted as a
  // fallback for older builds — decoding must not silently yield an empty
  // list when the server uses a different envelope.
  use requests <- decode.optional_field(
    "requests",
    [],
    decode.list(applicant_request_decoder()),
  )
  use items <- decode.optional_field(
    "items",
    [],
    decode.list(applicant_request_decoder()),
  )
  decode.success(case requests {
    [] -> items
    _ -> requests
  })
}

fn request_card_decoder() -> decode.Decoder(RequestCard) {
  use id <- decode.field("id", decode.string)
  use status <- nullable_string("status", "")
  use status_label <- nullable_string("status_label", "")
  use request_type <- nullable_string("request_type", "")
  use applicant_name <- nullable_string("applicant_name", "")
  use summary <- nullable_string("summary", "")
  use fields <- decode.optional_field(
    "fields",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use clarification_note <- nullable_string("clarification_note", "")
  use applicant_note <- nullable_string("applicant_note", "")
  use created_at <- nullable_string("created_at", "")
  use submitted_at <- nullable_string("submitted_at", "")
  use accepted_at <- nullable_string("accepted_at", "")
  use answer_ready_at <- nullable_string("answer_ready_at", "")
  use completed_at <- nullable_string("completed_at", "")
  use due_at <- nullable_string("due_at", "")
  use available_actions <- decode.optional_field(
    "available_actions",
    [],
    decode.list(decode.string),
  )
  use can_respond <- nullable_bool("can_respond", False)
  use timeline <- decode.optional_field(
    "timeline",
    [],
    decode.list(timeline_event_decoder()),
  )
  use response <- decode.optional_field(
    "response",
    None,
    decode.optional(response_decoder()),
  )
  use feedback <- decode.optional_field(
    "feedback",
    None,
    decode.optional(feedback_decoder()),
  )
  decode.success(RequestCard(
    id: id,
    status: status,
    status_label: status_label,
    request_type: request_type,
    applicant_name: applicant_name,
    summary: summary,
    fields: fields,
    clarification_note: clarification_note,
    applicant_note: applicant_note,
    created_at: created_at,
    submitted_at: optional_non_empty(submitted_at),
    accepted_at: optional_non_empty(accepted_at),
    answer_ready_at: optional_non_empty(answer_ready_at),
    completed_at: optional_non_empty(completed_at),
    due_at: optional_non_empty(due_at),
    available_actions: available_actions,
    can_respond: can_respond,
    timeline: timeline,
    response: response,
    feedback: feedback,
  ))
}

fn transition_decoder() -> decode.Decoder(TransitionOutcome) {
  use from_status <- nullable_string("from_status", "")
  use to_status <- nullable_string("to_status", "")
  use to_status_label <- nullable_string("to_status_label", "")
  decode.success(TransitionApplied(from_status, to_status, to_status_label))
}

fn transition_conflict_decoder() -> decode.Decoder(#(String, String)) {
  use current_status <- nullable_string("current_status", "")
  use message <- nullable_string("message", "")
  decode.success(#(current_status, message))
}

fn missing_requisites_decoder() -> decode.Decoder(List(String)) {
  use items <- decode.optional_field("missing", [], decode.list(decode.string))
  decode.success(items)
}

fn optional_non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    other -> Some(other)
  }
}
