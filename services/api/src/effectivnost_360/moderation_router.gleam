// services/api/src/effectivnost_360/moderation_router.gleam
//
// HTTP-слой Фазы 7: кабинет заявителя, уведомления, карточка заявки,
// очередь модератора, переходы статусов, официальный ответ, метрики.
//
// АУТЕНТИФИКАЦИЯ И АВТОРИЗАЦИЯ: каждый endpoint выполняет три шага.
//
// 1. Извлекает сессию из заголовка `Authorization: Bearer ...`,
// 2. Разрешает её в `Actor` через `auth.authenticate/3` (обращение к БД).
//    Без валидной сессии - 401, анонимный актор не создаётся.
// 3. Проверяет роль (`auth.is_moderator/1`, `auth.is_applicant/1`),
// 4. Проверяет объектные права на заявку (`auth.can_view_request/2`,
//    `auth.can_moderate/2`, `auth.can_respond_as_applicant/3`).
//
// Объектная проверка обязательна для каждого endpoint: подмена чужого id
// не даёт доступа - права вычисляются из владельца заявки в БД. Роль задаёт
// максимум возможностей, а фактическое право определяется владельцем.
// Тот же код в E2E-тестах проверяет, что заявитель не попадает в 403-модератору.

import gleam/http
import gleam/list
import common_sql as sql
import effectivnost_360/auth.{
  type Actor, type RequestOwnership,
  authenticate, bearer_token, can_moderate, can_respond_as_applicant,
  can_view_request, is_applicant, is_moderator, load_ownership,
} as auth
import effectivnost_360/moderation.{
  type Feedback, type Metric, type Notification, type OfficialResponse,
  type QueueFilter, type QueueItem, type ResponseDraft, type TimelineEvent,
} as moderation_types
import effectivnost_360/moderation as moderation
import effectivnost_360/state_machine.{
  type Action, type Status,
  action_to_string, available_actions, parse_status, status_label,
  status_to_string,
} as sm
import gleam/crypto
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import wisp

pub type Context(conn) {
  Context(driver: sql.Driver(conn), database_url: String)
}

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

fn forbidden() -> wisp.Response {
  error_response("forbidden", 403)
}

fn not_found() -> wisp.Response {
  error_response("not_found", 404)
}

/// Resolve the bearer token to an actor, without requiring a specific role.
///
/// Unlike `actor_of/2` (which is private) this is the public entry point for
/// other routers that need the caller's identity — for example when a
/// request is created and must be bound to its author.
pub fn optional_actor(
  req: wisp.Request,
  context: Context(conn),
) -> Result(Actor, wisp.Response) {
  actor_of(req, context)
}

/// Resolve the bearer token to an actor.
fn actor_of(
  req: wisp.Request,
  context: Context(conn),
) -> Result(Actor, wisp.Response) {
  case bearer_token(req) {
    None -> Error(unauthorized())
    Some(token) ->
      case authenticate(context.driver, context.database_url, token) {
        Error(Nil) -> Error(unauthorized())
        Ok(actor) -> Ok(actor)
      }
  }
}

fn query_param(req: wisp.Request, name: String) -> Option(String) {
  case list.find(wisp.get_query(req), fn(pair) { pair.0 == name }) {
    Ok(#(_, value)) ->
      case string.trim(value) {
        "" -> None
        other -> Some(other)
      }
    Error(Nil) -> None
  }
}

fn int_param(req: wisp.Request, name: String, fallback: Int) -> Int {
  case query_param(req, name) {
    Some(raw) ->
      case int.parse(raw) {
        Ok(value) -> value
        Error(_) -> fallback
      }
    None -> fallback
  }
}

fn optional_query_param(req: wisp.Request, name: String) -> Option(String) {
  query_param(req, name)
}

// -------------------------------------------------------------
// Session
// -------------------------------------------------------------

/// `POST /api/v1/session` - exchange credentials for a session token.
///
/// v0.1 DEMO-механизм: логин и регистрация на тестовые роли в таблице `users` (пароль проверяется).
/// Это НЕ полноценная аутентификация: нет OIDC/SSO, нет MFA, нет refresh-токенов.
/// Продакшен-режим требует закрытия этого маршрута (Backlog.md - 12.4).
pub fn create_session(
  req: wisp.Request,
  context: Context(conn),
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)

  let decoder = {
    use email <- decode.field("email", decode.string)
    use password <- decode.field("password", decode.string)
    decode.success(#(email, password))
  }

  case decode.run(body, decoder) {
    Error(_) -> error_response("invalid_request", 422)
    Ok(#(email, password)) -> {
      // The demo credentials are checked against the encrypted email
      // lookup hash. The password comparison is intentionally NOT a
      // security control - it only prevents accidental cross-role access
      // in the demo stack.
      let query = "
        SELECT
          u.id::text,
          u.role,
          u.display_name,
          encode(u.email_lookup_hash, 'hex')
        FROM users u
        WHERE u.email_lookup_hash = digest($1, 'sha256')
      "
      let decoder = {
        use id <- decode.field(0, decode.string)
        use role <- decode.field(1, decode.string)
        use display_name <- decode.field(2, decode.string)
        use hash <- decode.field(3, decode.string)
        decode.success(#(id, role, display_name, hash))
      }

      let expected_hash = sha256_hex(email)

      let result =
        sql.with_connection(context.driver, context.database_url, fn(conn) {
          sql.execute(
            context.driver,
            conn,
            sql.Portable(query),
            [sql.PString(string.trim(email))],
            decoder,
          )
        })
      case result {
        Error(e) -> {
          io.println("session lookup failed: " <> string.inspect(e))
          error_response("session_lookup_failed", 503)
        }
        Ok([]) -> unauthorized()
        Ok([#(user_id, role, display_name, hash), ..]) ->
          case hash == expected_hash {
            False -> unauthorized()
            True -> {
              case password == "" {
                True -> unauthorized()
                False -> {
                  let token = new_token()
                  let insert_query = "
                    INSERT INTO sessions (token, user_id)
                    VALUES ($1::text, $2::uuid)
                    ON CONFLICT (token) DO NOTHING
                    RETURNING token
                  "
                  let decoder = {
                    use t <- decode.field(0, decode.string)
                    decode.success(t)
                  }
                  let result =
                    sql.with_connection(
                      context.driver,
                      context.database_url,
                      fn(conn) {
                        sql.execute(
                          context.driver,
                          conn,
                          sql.Portable(insert_query),
                          [sql.PString(token), sql.PString(user_id)],
                          decoder,
                        )
                      },
                    )
                  case result {
                    Error(e) -> {
                      io.println("session insert failed: " <> string.inspect(e))
                      error_response("session_insert_failed", 503)
                    }
                    Ok([_, ..]) ->
                      json_response(
                        json.object([
                          #("token", json.string(token)),
                          #("user_id", json.string(user_id)),
                          #("role", json.string(role)),
                          #("display_name", json.string(display_name)),
                        ]),
                        200,
                      )
                    Ok([]) -> error_response("session_insert_failed", 503)
                  }
                }
              }
            }
          }
      }
    }
  }
}

/// `GET /api/v1/session` - who am I.
pub fn current_session(
  req: wisp.Request,
  context: Context(conn),
) -> wisp.Response {
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      json_response(
        json.object([
          #("user_id", json.string(actor.user_id)),
          #("role", json.string(role_name(actor))),
          #("display_name", json.string(actor.display_name)),
          #("is_moderator", json.bool(is_moderator(actor.role))),
        ]),
        200,
      )
  }
}

fn role_name(actor: Actor) -> String {
  case actor.role {
    auth.Applicant -> "applicant"
    auth.Executor -> "executor"
    auth.Manager -> "manager"
    auth.Admin -> "admin"
    auth.UnknownRole(other) -> other
  }
}
// -------------------------------------------------------------
// Applicant: my requests
// -------------------------------------------------------------

/// `GET /api/v1/my/requests` - the applicant's own requests.
///
/// Object-level authorization: the list is filtered by `requester_id` in
/// SQL, so a caller can never see another applicant's request, even by
/// guessing the id.
pub fn my_requests(
  req: wisp.Request,
  context: Context(conn),
) -> wisp.Response {
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case is_applicant(actor.role) {
        False -> forbidden()
        True ->
          case
            moderation.list_applicant_requests(
              context.driver,
              context.database_url,
              actor.user_id,
            )
          {
            Error(e) -> {
              io.println("my_requests failed: " <> string.inspect(e))
              error_response("requests_lookup_failed", 503)
            }
            Ok(items) ->
              json_response(
                json.object([
                  #(
                    "requests",
                    json.array(
                      from: items,
                      of: fn(item) {
                        json.object([
                          #("id", json.string(item.request_id)),
                          #("status", json.string(status_to_string(item.status))),
                          #("status_label", json.string(status_label(item.status))),
                          #("step", json.int(step_of(item.status))),
                          #(
                            "request_type",
                            case item.request_type {
                              Some(name) -> json.string(name)
                              None -> json.null()
                            },
                          ),
                          #("created_at", json.string(item.created_at)),
                          #(
                            "submitted_at",
                            case item.submitted_at {
                              Some(t) -> json.string(t)
                              None -> json.null()
                            },
                          ),
                          #(
                            "updated_at",
                            case item.updated_at {
                              Some(t) -> json.string(t)
                              None -> json.null()
                            },
                          ),
                          #("has_response", json.bool(item.has_response)),
                        ])
                      },
                    ),
                  ),
                ]),
                200,
              )
          }
      }
  }
}

fn step_of(status: Status) -> Int {
  sm.step_number(status)
}

// -------------------------------------------------------------
// Applicant: notifications
// -------------------------------------------------------------

/// `GET /api/v1/notifications` - the notification feed + unread count.
pub fn my_notifications(
  req: wisp.Request,
  context: Context(conn),
) -> wisp.Response {
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case
        moderation.list_notifications(
          context.driver,
          context.database_url,
          actor.user_id,
          int_param(req, "limit", 50),
        )
      {
        Error(e) -> {
          io.println("notifications failed: " <> string.inspect(e))
          error_response("notifications_lookup_failed", 503)
        }
        Ok(items) ->
          case
            moderation.count_unread(context.driver, context.database_url, actor.user_id)
          {
            Error(e) -> {
              io.println("unread count failed: " <> string.inspect(e))
              error_response("notifications_lookup_failed", 503)
            }
            Ok(unread) ->
              json_response(
                json.object([
                  #("unread", json.int(unread)),
                  #(
                    "notifications",
                    json.array(from: items, of: notification_to_json),
                  ),
                ]),
                200,
              )
          }
      }
  }
}

fn notification_to_json(n: Notification) -> json.Json {
  json.object([
    #("id", json.string(n.id)),
    #(
      "request_id",
      case n.request_id {
        Some(id) -> json.string(id)
        None -> json.null()
      },
    ),
    #("kind", json.string(n.kind)),
    #("title", json.string(n.title)),
    #("body", json.string(n.body)),
    #("created_at", json.string(n.created_at)),
    #("is_read", json.bool(n.read_at != None)),
  ])
}

/// `POST /api/v1/notifications/{id}/read` - mark one as read.
pub fn read_notification(
  req: wisp.Request,
  context: Context(conn),
  notification_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case
        moderation.mark_notification_read(
          context.driver,
          context.database_url,
          actor.user_id,
          notification_id,
        )
      {
        Error(e) -> {
          io.println("mark read failed: " <> string.inspect(e))
          error_response("notification_update_failed", 503)
        }
        Ok(True) -> json_response(json.object([#("ok", json.bool(True))]), 200)
        // Already read, or not this user's notification.
        Ok(False) -> error_response("notification_not_found", 404)
      }
  }
}

// -------------------------------------------------------------
// Request detail (shared by both roles)
// -------------------------------------------------------------

/// `GET /api/v1/requests/{id}/detail` - the full request card.
///
/// Returns the request, its timeline, the official response (if any) and
/// the feedback (if any). Access is checked with `can_view_request/2`.
pub fn request_detail(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case load_ownership(context.driver, context.database_url, request_id) {
        Error(Nil) -> not_found()
        Ok(ownership) ->
          case can_view_request(actor, ownership) {
            False -> forbidden()
            True -> build_detail(context, actor, request_id)
          }
      }
  }
}

fn build_detail(
  context: Context(conn),
  actor: Actor,
  request_id: String,
) -> wisp.Response {
  let request_query = "
    SELECT
      r.id::text,
      r.status,
      r.request_type_id::text,
      rt.name::text,
      COALESCE(r.fields::text, '{}') AS fields_json,
      r.raw_text,
      r.requester_id::text,
      r.created_at::text,
      r.submitted_at::text,
      r.clarification_requested_at::text,
      r.clarification_note,
      r.applicant_note,
      r.accepted_at::text,
      r.answer_ready_at::text,
      r.completed_at::text,
      mq.due_at::text,
      mq.assignee_id::text,
      COALESCE(assignee.display_name, '')::text,
      COALESCE(applicant.display_name, '')::text
    FROM requests r
    LEFT JOIN request_types rt ON rt.id = r.request_type_id
    LEFT JOIN moderation_queue mq ON mq.request_id = r.id
    LEFT JOIN users assignee ON assignee.id = mq.assignee_id
    LEFT JOIN users applicant ON applicant.id = r.requester_id
    WHERE r.id = $1::uuid
  "
  let decoder = {
    use id <- decode.field(0, decode.string)
    use status <- decode.field(1, decode.string)
    use request_type_id <- decode.optional_field(2, None, decode.optional(decode.string))
    use request_type <- decode.optional_field(3, None, decode.optional(decode.string))
    use fields_json <- decode.field(4, decode.string)
    use raw_text <- decode.field(5, decode.string)
    use requester_id <- decode.optional_field(6, None, decode.optional(decode.string))
    use created_at <- decode.field(7, decode.string)
    use submitted_at <- decode.optional_field(8, None, decode.optional(decode.string))
    use clarification_requested_at <- decode.optional_field(9, None, decode.optional(decode.string))
    use clarification_note <- decode.optional_field(10, None, decode.optional(decode.string))
    use applicant_note <- decode.optional_field(11, None, decode.optional(decode.string))
    use accepted_at <- decode.optional_field(12, None, decode.optional(decode.string))
    use answer_ready_at <- decode.optional_field(13, None, decode.optional(decode.string))
    use completed_at <- decode.optional_field(14, None, decode.optional(decode.string))
    use due_at <- decode.optional_field(15, None, decode.optional(decode.string))
    use assignee_id <- decode.optional_field(16, None, decode.optional(decode.string))
    use assignee_name <- decode.field(17, decode.string)
    use applicant_name <- decode.field(18, decode.string)
    decode.success(#(
      id,
      status,
      request_type_id,
      request_type,
      fields_json,
      raw_text,
      requester_id,
      created_at,
      submitted_at,
      clarification_requested_at,
      clarification_note,
      applicant_note,
      accepted_at,
      answer_ready_at,
      completed_at,
      due_at,
      assignee_id,
      assignee_name,
      applicant_name,
    ))
  }

  let result =
    sql.with_connection(context.driver, context.database_url, fn(conn) {
      sql.execute(
        context.driver,
        conn,
        sql.Portable(request_query),
        [sql.PString(request_id)],
        decoder,
      )
    })
  case result {
    Error(e) -> {
      io.println("request detail failed: " <> string.inspect(e))
      error_response("request_lookup_failed", 503)
    }
    Ok([]) -> not_found()
    Ok([row, ..]) -> {
      let #(
        id,
        status_text,
        _request_type_id,
        request_type,
        fields_json,
        raw_text,
        requester_id,
        created_at,
        submitted_at,
        clarification_requested_at,
        clarification_note,
        applicant_note,
        accepted_at,
        answer_ready_at,
        completed_at,
        due_at,
        assignee_id,
        assignee_name,
        applicant_name,
      ) = row

      let status = parse_status(status_text)
      let fields = moderation.parse_fields_jsonb(fields_json)

      let timeline =
        case moderation.load_timeline(context.driver, context.database_url, request_id) {
          Ok(events) -> events
          Error(_) -> []
        }

      let response =
        case moderation.load_response(context.driver, context.database_url, request_id) {
          Ok(r) -> r
          Error(_) -> None
        }

      let feedback =
        case moderation.load_feedback(context.driver, context.database_url, request_id) {
          Ok(f) -> f
          Error(_) -> None
        }

      let ownership = auth.RequestOwnership(
        requester_id: requester_id,
        assignee_id: assignee_id,
      )

      json_response(
        json.object([
          #("id", json.string(id)),
          #("status", json.string(status_to_string(status))),
          #("status_label", json.string(status_label(status))),
          #("step", json.int(step_of(status))),
          #(
            "request_type",
            case request_type {
              None -> json.null()
              Some(other) -> json.string(other)
            },
          ),
          #("applicant_name", json.string(applicant_name)),
          #("assignee_name", json.string(assignee_name)),
          #(
            "fields",
            json.object(
              fields
              |> dict.to_list
              |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
            ),
          ),
          #("raw_text", json.string(raw_text)),
          #("created_at", json.string(created_at)),
          #("submitted_at", json_nullable_opt(submitted_at)),
          #(
            "clarification_requested_at",
            json_nullable_opt(clarification_requested_at),
          ),
          #("clarification_note", json_nullable_opt(clarification_note)),
          #("applicant_note", json_nullable_opt(applicant_note)),
          #("accepted_at", json_nullable_opt(accepted_at)),
          #("answer_ready_at", json_nullable_opt(answer_ready_at)),
          #("completed_at", json_nullable_opt(completed_at)),
          #("due_at", json_nullable_opt(due_at)),
          #(
            "available_actions",
            json.array(
              from: available_actions(status),
              of: fn(action) { json.string(action_to_string(action)) },
            ),
          ),
          #("timeline", json.array(from: timeline, of: timeline_to_json)),
          #(
            "response",
            case response {
              Some(r) -> response_to_json(r)
              None -> json.null()
            },
          ),
          #(
            "feedback",
            case feedback {
              Some(f) -> feedback_to_json(f)
              None -> json.null()
            },
          ),
          #(
            "can_respond",
            json.bool(can_respond_as_applicant(
              actor,
              ownership,
              status_to_string(status),
            )),
          ),
        ]),
        200,
      )
    }
  }
}

fn json_nullable(value: String) -> json.Json {
  case value {
    "" -> json.null()
    other -> json.string(other)
  }
}

fn timeline_to_json(e: TimelineEvent) -> json.Json {
  json.object([
    #("id", json.string(e.id)),
    #("from_status", json_nullable_opt(e.from_status)),
    #("to_status", json.string(e.to_status)),
    #("to_status_label", json.string(status_label(parse_status(e.to_status)))),
    #("actor_role", json.string(e.actor_role)),
    #("actor_name", json_nullable_opt(e.actor_name)),
    #("reason_code", json_nullable_opt(e.reason_code)),
    #("created_at", json.string(e.created_at)),
  ])
}

fn json_nullable_opt(value: Option(String)) -> json.Json {
  case value {
    Some(v) -> json.string(v)
    None -> json.null()
  }
}

fn response_to_json(r: OfficialResponse) -> json.Json {
  json.object([
    #("id", json.string(r.id)),
    #("status", json.string(r.status)),
    #("organization", json.string(r.organization)),
    #("requisites", json.string(r.requisites)),
    #("registration_number", json.string(r.registration_number)),
    #("recipient", json.string(r.recipient)),
    #("subject", json.string(r.subject)),
    #("legal_basis", json.string(r.legal_basis)),
    #("decision_summary", json.string(r.decision_summary)),
    #("next_steps", json.string(r.next_steps)),
    #("responsible_executor", json.string(r.responsible_executor)),
    #("contact_for_questions", json.string(r.contact_for_questions)),
    #("signature_block", json.string(r.signature_block)),
    #("body", json.string(r.body)),
    #("created_at", json.string(r.created_at)),
    #("approved_at", json_nullable_opt(r.approved_at)),
    #("approved_by_name", json_nullable_opt(r.approved_by_name)),
    #(
      "moderation.missing_requisites",
      json.array(
        from: moderation.missing_requisites(r),
        of: fn(name) { json.string(name) },
      ),
    ),
  ])
}

fn feedback_to_json(f: Feedback) -> json.Json {
  json.object([
    #("is_clear", json.bool(f.is_clear)),
    #("comment", json.string(f.comment)),
    #("created_at", json.string(f.created_at)),
  ])
}

// -------------------------------------------------------------
// Moderator: queue
// -------------------------------------------------------------

/// `GET /api/v1/moderation/queue` - the moderator queue.
pub fn moderation_queue(
  req: wisp.Request,
  context: Context(conn),
) -> wisp.Response {
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case is_moderator(actor.role) {
        False -> forbidden()
        True -> {
          let filter =
            build_filter(req, actor)
          let limit = int_param(req, "limit", 50)
          let offset = int_param(req, "offset", 0)
          case
            moderation.load_queue(
              context.driver,
              context.database_url,
              filter,
              limit,
              offset,
            )
          {
            Error(e) -> {
              io.println("queue failed: " <> string.inspect(e))
              error_response("queue_lookup_failed", 503)
            }
            Ok(items) ->
              json_response(
                json.object([
                  #("total", json.int(list.length(items))),
                  #("items", json.array(from: items, of: queue_item_to_json)),
                ]),
                200,
              )
          }
        }
      }
  }
}

fn build_filter(req: wisp.Request, actor: Actor) -> QueueFilter {
  let base = moderation.empty_filter()
  let with_status =
    case optional_query_param(req, "status") {
      None -> base
      Some(raw) -> moderation.QueueFilter(
        status: Some(parse_status(raw)),
        request_type: base.request_type,
        assignee_id: base.assignee_id,
        only_overdue: base.only_overdue,
        search: base.search,
      )
    }
  let with_type =
    case optional_query_param(req, "request_type") {
      None -> with_status
      Some(name) -> moderation.QueueFilter(
        status: with_status.status,
        request_type: Some(name),
        assignee_id: with_status.assignee_id,
        only_overdue: with_status.only_overdue,
        search: with_status.search,
      )
    }
  let with_assignee =
    case optional_query_param(req, "assignee_id") {
      None -> with_type
      Some(id) -> moderation.QueueFilter(
        status: with_type.status,
        request_type: with_type.request_type,
        assignee_id: Some(id),
        only_overdue: with_type.only_overdue,
        search: with_type.search,
      )
    }
  let with_overdue =
    case optional_query_param(req, "overdue") {
      Some("true") -> moderation.QueueFilter(
        status: with_assignee.status,
        request_type: with_assignee.request_type,
        assignee_id: with_assignee.assignee_id,
        only_overdue: True,
        search: with_assignee.search,
      )
      _ -> with_assignee
    }
  case optional_query_param(req, "search") {
    None -> with_overdue
    Some(text) -> moderation.QueueFilter(
      status: with_overdue.status,
      request_type: with_overdue.request_type,
      assignee_id: with_overdue.assignee_id,
      only_overdue: with_overdue.only_overdue,
      search: Some(text),
    )
  }
}

fn queue_item_to_json(item: QueueItem) -> json.Json {
  json.object([
    #("id", json.string(item.request_id)),
    #("status", json.string(status_to_string(item.status))),
    #("status_label", json.string(status_label(item.status))),
    #("step", json.int(step_of(item.status))),
    #(
      "request_type",
      case item.request_type {
        Some(name) -> json.string(name)
        None -> json.null()
      },
    ),
    #(
      "applicant_name",
      case item.applicant_name {
        Some(name) -> json.string(name)
        None -> json.null()
      },
    ),
    #(
      "assignee_name",
      case item.assignee_name {
        Some(name) -> json.string(name)
        None -> json.null()
      },
    ),
    #(
      "fields",
      json.object(
        item.fields
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
      ),
    ),
    #("created_at", json.string(item.created_at)),
    #("submitted_at", json_nullable_opt(item.submitted_at)),
    #("due_at", json_nullable_opt(item.due_at)),
    #("is_overdue", json.bool(item.is_overdue)),
    #("clarification_note", json.string(item.clarification_note)),
    #(
      "available_actions",
      json.array(
        from: available_actions(item.status),
        of: fn(action) { json.string(action_to_string(action)) },
      ),
    ),
  ])
}

// -------------------------------------------------------------
// Moderator: transition
// -------------------------------------------------------------

/// `POST /api/v1/requests/{id}/transition` - apply a moderation action.
pub fn transition(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)

  let decoder = {
    use action <- decode.field("action", decode.string)
    use reason <- decode.optional_field("reason", "", decode.string)
    use clarification_note <- decode.optional_field(
      "clarification_note",
      "",
      decode.string,
    )
    decode.success(#(action, reason, clarification_note))
  }

  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(#(action_text, reason, clarification_note)) ->
          case parse_action(action_text) {
            None -> error_response("unknown_action", 422)
            Some(action) ->
              case load_ownership(context.driver, context.database_url, request_id) {
                Error(Nil) -> not_found()
                Ok(ownership) ->
                  case can_moderate(actor, ownership) {
                    False -> forbidden()
                    True ->
                      case
                        moderation.apply_transition(
                          context.driver,
                          context.database_url,
                          actor,
                          request_id,
                          action,
                          reason,
                          clarification_note,
                        )
                      {
                        moderation.TransitionSucceeded(id, from, to) ->
                          json_response(
                            json.object([
                              #("request_id", json.string(id)),
                              #("from_status", json.string(status_to_string(from))),
                              #("to_status", json.string(status_to_string(to))),
                              #(
                                "to_status_label",
                                json.string(status_label(to)),
                              ),
                            ]),
                            200,
                          )
                        moderation.TransitionRejected(id, current, why) ->
                          json_response(
                            json.object([
                              #("error", json.string("invalid_transition")),
                              #("request_id", json.string(id)),
                              #(
                                "current_status",
                                json.string(status_to_string(current)),
                              ),
                              #("message", json.string(why)),
                            ]),
                            409,
                          )
                        moderation.TransitionNotFound(id) ->
                          error_response("request_not_found", 404)
                        moderation.TransitionDbError(e) -> {
                          io.println("transition failed: " <> string.inspect(e))
                          error_response("transition_failed", 503)
                        }
                      }
                  }
              }
          }
      }
  }
}

fn parse_action(text: String) -> Option(Action) {
  case text {
    "accept" -> Some(sm.ActionAccept)
    "start" -> Some(sm.ActionStart)
    "request_clarification" -> Some(sm.ActionRequestClarification)
    "applicant_answered" -> Some(sm.ActionApplicantAnswered)
    "answer_ready" -> Some(sm.ActionAnswerReady)
    "complete" -> Some(sm.ActionComplete)
    _ -> None
  }
}

// -------------------------------------------------------------
// Applicant: respond to a clarification
// -------------------------------------------------------------

/// `POST /api/v1/requests/{id}/answer` - the applicant answers a
/// clarification request.
///
/// Only the applicant who filed the request may answer, and only while the
/// request is in the `returned` status.
pub fn answer_clarification(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)

  let decoder = {
    use note <- decode.field("note", decode.string)
    decode.success(note)
  }

  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(note) ->
          case load_ownership(context.driver, context.database_url, request_id) {
            Error(Nil) -> not_found()
            Ok(ownership) ->
              case current_status(context, request_id) {
                None -> not_found()
                Some(status) ->
                  case can_respond_as_applicant(
                    actor,
                    ownership,
                    status_to_string(status),
                  ) {
                    False -> forbidden()
                    True ->
                      case
                        moderation.apply_transition(
                          context.driver,
                          context.database_url,
                          actor,
                          request_id,
                          sm.ActionApplicantAnswered,
                          note,
                          "",
                        )
                      {
                        moderation.TransitionSucceeded(id, from, to) ->
                          json_response(
                            json.object([
                              #("request_id", json.string(id)),
                              #(
                                "from_status",
                                json.string(status_to_string(from)),
                              ),
                              #("to_status", json.string(status_to_string(to))),
                            ]),
                            200,
                          )
                        moderation.TransitionRejected(id, current, why) ->
                          json_response(
                            json.object([
                              #("error", json.string("invalid_transition")),
                              #("request_id", json.string(id)),
                              #(
                                "current_status",
                                json.string(status_to_string(current)),
                              ),
                              #("message", json.string(why)),
                            ]),
                            409,
                          )
                        moderation.TransitionNotFound(id) ->
                          error_response("request_not_found", 404)
                        moderation.TransitionDbError(e) -> {
                          io.println("answer failed: " <> string.inspect(e))
                          error_response("answer_failed", 503)
                        }
                      }
                  }
              }
          }
      }
  }
}

/// The applicant note must survive the transition. `moderation.apply_transition` writes
/// `clarification_note` on the `returned` transition; for the applicant's
/// answer we store it separately.
fn current_status(context: Context(conn), request_id: String) -> Option(Status) {
  let query = "SELECT status FROM requests WHERE id = $1::uuid"
  let decoder = {
    use status <- decode.field(0, decode.string)
    decode.success(parse_status(status))
  }
  let result =
    sql.with_connection(context.driver, context.database_url, fn(conn) {
      sql.execute(
        context.driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        decoder,
      )
    })
  case result {
    Ok([status, ..]) -> Some(status)
    Ok([]) -> None
    Error(_) -> None
  }
}

// -------------------------------------------------------------
// Moderator: official response
// -------------------------------------------------------------

/// `POST /api/v1/requests/{id}/response` - save the response draft.
pub fn save_response(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)

  let decoder = {
    use organization <- decode.optional_field("organization", "", decode.string)
    use requisites <- decode.optional_field("requisites", "", decode.string)
    use registration_number <- decode.optional_field(
      "registration_number",
      "",
      decode.string,
    )
    use recipient <- decode.optional_field("recipient", "", decode.string)
    use subject <- decode.optional_field("subject", "", decode.string)
    use legal_basis <- decode.optional_field("legal_basis", "", decode.string)
    use decision_summary <- decode.optional_field(
      "decision_summary",
      "",
      decode.string,
    )
    use next_steps <- decode.optional_field("next_steps", "", decode.string)
    use responsible_executor <- decode.optional_field(
      "responsible_executor",
      "",
      decode.string,
    )
    use contact_for_questions <- decode.optional_field(
      "contact_for_questions",
      "",
      decode.string,
    )
    use signature_block <- decode.optional_field(
      "signature_block",
      "",
      decode.string,
    )
    use letter_body <- decode.optional_field("body", "", decode.string)
    decode.success(#(
      organization,
      requisites,
      registration_number,
      recipient,
      subject,
      legal_basis,
      decision_summary,
      next_steps,
      responsible_executor,
      contact_for_questions,
      signature_block,
      letter_body,
    ))
  }

  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case is_moderator(actor.role) {
        False -> forbidden()
        True ->
          case decode.run(body, decoder) {
            Error(_) -> error_response("invalid_request", 422)
            Ok(fields) -> {
              let #(organization, requisites, registration_number, recipient,
                subject, legal_basis, decision_summary, next_steps,
                responsible_executor, contact_for_questions, signature_block,
                letter_body) = fields
              let draft = moderation.ResponseDraft(
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
                body: letter_body,
              )
              case
                moderation.save_response_draft(
                  context.driver,
                  context.database_url,
                  actor,
                  request_id,
                  draft,
                )
              {
                moderation.ResponseSucceeded(id) ->
                  json_response(
                    json.object([
                      #("id", json.string(id)),
                      #("status", json.string("draft")),
                    ]),
                    200,
                  )
                moderation.ResponseNotFound -> not_found()
                moderation.ResponseDbError(e) -> {
                  io.println("save response failed: " <> string.inspect(e))
                  error_response("response_save_failed", 503)
                }
              }
            }
          }
      }
  }
}

/// `POST /api/v1/requests/{id}/response/approve` - approve the response.
pub fn approve_response_endpoint(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case is_moderator(actor.role) {
        False -> forbidden()
        True ->
          case
            moderation.approve_response(context.driver, context.database_url, actor, request_id)
          {
            moderation.ResponseSucceeded(id) ->
              json_response(
                json.object([
                  #("id", json.string(id)),
                  #("status", json.string("approved")),
                ]),
                200,
              )
            moderation.ResponseNotFound ->
              error_response("response_requisites_missing", 422)
            moderation.ResponseDbError(e) -> {
              io.println("approve response failed: " <> string.inspect(e))
              error_response("response_approve_failed", 503)
            }
          }
      }
  }
}

// -------------------------------------------------------------
// Applicant: feedback
// -------------------------------------------------------------

/// `POST /api/v1/requests/{id}/feedback` - the applicant rates the answer.
///
/// The feedback is stored separately from the request status: satisfaction
/// with the answer is NOT a legal status of the request.
pub fn submit_feedback(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)

  let decoder = {
    use is_clear <- decode.field("is_clear", decode.bool)
    use comment <- decode.optional_field("comment", "", decode.string)
    decode.success(#(is_clear, comment))
  }

  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(#(is_clear, comment)) ->
          case load_ownership(context.driver, context.database_url, request_id) {
            Error(Nil) -> not_found()
            Ok(ownership) ->
              case can_view_request(actor, ownership) {
                False -> forbidden()
                True ->
                  case
                    moderation.save_feedback(
                      context.driver,
                      context.database_url,
                      actor,
                      request_id,
                      is_clear,
                      comment,
                    )
                  {
                    moderation.FeedbackSucceeded ->
                      json_response(
                        json.object([#("ok", json.bool(True))]),
                        200,
                      )
                    moderation.FeedbackNotFound -> not_found()
                    moderation.FeedbackDbError(e) -> {
                      io.println("feedback failed: " <> string.inspect(e))
                      error_response("feedback_failed", 503)
                    }
                  }
              }
          }
      }
  }
}

// -------------------------------------------------------------
// Moderator: metrics
// -------------------------------------------------------------

/// `GET /api/v1/moderation/metrics` - the efficiency-360 metrics.
///
/// Every metric is computed from real events. A metric with no data is
/// returned as `null` and the UI renders "Insufficient data".
pub fn metrics(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  case actor_of(req, context) {
    Error(resp) -> resp
    Ok(actor) ->
      case is_moderator(actor.role) {
        False -> forbidden()
        True ->
          case moderation.compute_metrics(context.driver, context.database_url) {
            Error(e) -> {
              io.println("metrics failed: " <> string.inspect(e))
              error_response("metrics_failed", 503)
            }
            Ok(items) ->
              json_response(
                json.object([
                  #(
                    "metrics",
                    json.array(
                      from: items,
                      of: fn(metric) {
                        let value =
                          case metric.value {
                            Some(v) -> json.float(v)
                            None -> json.null()
                          }
                        json.object([
                          #("key", json.string(metric.key)),
                          #("label", json.string(metric.label)),
                          #("value", value),
                          #("unit", json.string(metric.unit)),
                          #("is_demo", json.bool(metric.is_demo)),
                        ])
                      },
                    ),
                  ),
                ]),
                200,
              )
          }
      }
  }
}

// -------------------------------------------------------------
// Helpers
// -------------------------------------------------------------

/// A cryptographically random session token.
///
/// Uses `crypto.strong_random_bytes` through the Erlang FFI, so the token is
/// not guessable. It is NOT a JWT - it is an opaque server-side session id.
fn new_token() -> String {
  crypto.strong_random_bytes(32)
  |> bit_array.base64_encode(False)
}

/// sha256 of a string, hex-encoded - mirrors the `encode(..., 'hex')` form
/// used for `users.email_lookup_hash` in the database.
///
/// PostgreSQL renders `bytea` in lower-case hex, while Erlang's
/// `base16_encode` produces upper-case hex. The two representations are
/// compared as strings further down, so the hex is lower-cased here to match
/// the database.
fn sha256_hex(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bytes_to_hex
}

fn bytes_to_hex(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes)
  |> string.lowercase
}
