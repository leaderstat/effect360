// services/api/src/effectivnost_360/auth.gleam
//
// RBAC-модуль CJM 360.
//
// ## Модель доступа:
// ------------------
// Токен сессии -> пользователь -> роль. Авторизация проверяется на каждом
// endpoint'е через `authenticate/2` и `Actor`. Анонимный актор не создаётся:
// при ошибке аутентификации endpoint отвечает 401.
//
// ## Разделение ответственности:
// ------------------------------
// * Аутентификация (кто вы) - `authenticate/2`.
// * Ролевая проверка (что можно по роли) - `is_moderator/1`, `can_moderate/2`.
// * Объектная проверка (чьё это) - `can_view_request/2`.
//
// Ни одно из правил не может быть обойтино подменой чужого `id`: доступ к
// заявке проверяется по владельцу, извлечённому из БД, а не из тела запроса.
//
// ## Известные ограничения:
// -----------------------
// * Сессия - bearer-токен в `Authorization`. Нет refresh-токенов, нет MFA.
// * Пароль хранится как bcrypt-хэш в `users.password_hash`.
// * Dev-режим: `POST /api/v1/session` доступен без аутентификации.
//   В v0.1 это допустимо для локальной разработки и демонстрации;
//   в production маршрут должен быть закрыт (Backlog.md #12.4).
//
// ## OBJECT-LEVEL AUTHZ
// ---------------------
// Права на объект заявки не выводятся из роли. Роль задаёт максимум возможностей,
// а фактическое право определяется владельцем заявки, извлечённым из базы:
//   * заявитель видит только свои заявки;
//   * исполнитель - только те заявки, которые ему назначены (или общую очередь);
//   * менеджер - назначенные ему заявки и агрегаты;
//   * администратор - все.
//
// Эти правила применяются в `auth.gleam` (`can_view_request/2`), и повторно
// проверяются на каждом endpoint'е: заявка, модерация, ответ, уведомления.

import common_sql as sql
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import wisp

/// A role in the system. Mirrors the `users.role` CHECK constraint.
pub type Role {
  Applicant
  Executor
  Manager
  Admin
  UnknownRole(String)
}

pub fn parse_role(s: String) -> Role {
  case s {
    "applicant" -> Applicant
    "executor" -> Executor
    "manager" -> Manager
    "admin" -> Admin
    other -> UnknownRole(other)
  }
}

pub fn role_to_string(role: Role) -> String {
  case role {
    Applicant -> "applicant"
    Executor -> "executor"
    Manager -> "manager"
    Admin -> "admin"
    UnknownRole(other) -> other
  }
}

/// The authenticated caller. `user_id` is the object-ownership key.
pub type Actor {
  Actor(user_id: String, role: Role, display_name: String)
}

/// Roles that may act on the moderation queue.
pub fn is_moderator(role: Role) -> Bool {
  case role {
    Executor | Manager | Admin -> True
    Applicant | UnknownRole(_) -> False
  }
}

pub fn is_applicant(role: Role) -> Bool {
  case role {
    Applicant -> True
    Executor | Manager | Admin | UnknownRole(_) -> False
  }
}

// -------------------------------------------------------------
// Session lookup
// -------------------------------------------------------------

fn session_decoder() -> decode.Decoder(Actor) {
  use user_id <- decode.field(0, decode.string)
  use role <- decode.field(1, decode.string)
  use display_name <- decode.field(2, decode.string)
  decode.success(Actor(user_id: user_id, role: parse_role(role), display_name: display_name))
}

/// Resolve a bearer token to an `Actor`.
///
/// Returns `Error(Nil)` when the token is unknown, expired, or the user
/// behind it was deleted. The caller MUST treat `Error(Nil)` as "not
/// authenticated" and answer 401 - never fall back to an anonymous actor.
pub fn authenticate(
  driver: sql.Driver(conn),
  database_url: String,
  token: String,
) -> Result(Actor, Nil) {
  let token = string.trim(token)
  case token == "" {
    True -> Error(Nil)
    False -> {
      let query = "
        SELECT
          u.id::text,
          u.role,
          u.display_name
        FROM sessions s
        JOIN users u ON u.id = s.user_id
        WHERE s.token = $1
          AND s.expires_at > now()
      "
      let result =
        sql.with_connection(driver, database_url, fn(conn) {
          sql.execute(
            driver,
            conn,
            sql.Portable(query),
            [sql.PString(token)],
            session_decoder(),
          )
        })
      case result {
        Ok([actor]) -> Ok(actor)
        Ok(_) -> Error(Nil)
        Error(_) -> Error(Nil)
      }
    }
  }
}

/// Extract the session token from the `Authorization: Bearer <token>` header.
pub fn bearer_token(req: wisp.Request) -> Option(String) {
  case req.headers |> list.find(fn(h) { h.0 == "authorization" }) {
    Ok(#(_, value)) ->
      case string.starts_with(value, "Bearer ") {
        True -> Some(string.trim(string.drop_start(value, 7)))
        False -> None
      }
    Error(Nil) -> None
  }
}

// -------------------------------------------------------------
// Object-level authorization
// -------------------------------------------------------------

/// Ownership facts for one request, as needed by the authorization rules.
pub type RequestOwnership {
  RequestOwnership(requester_id: Option(String), assignee_id: Option(String))
}

fn ownership_decoder() -> decode.Decoder(RequestOwnership) {
  use requester_id <- decode.optional_field(0, None, decode.optional(decode.string))
  use assignee_id <- decode.optional_field(1, None, decode.optional(decode.string))
  decode.success(RequestOwnership(requester_id:, assignee_id:))
}

/// Load the ownership facts of a request.
pub fn load_ownership(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(RequestOwnership, Nil) {
  let query = "
    SELECT
      r.requester_id::text,
      mq.assignee_id::text
    FROM requests r
    LEFT JOIN moderation_queue mq ON mq.request_id = r.id
    WHERE r.id = $1
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        ownership_decoder(),
      )
    })
  case result {
    Ok([ownership]) -> Ok(ownership)
    Ok(_) -> Error(Nil)
    Error(_) -> Error(Nil)
  }
}

/// Can this actor SEE this request?
///
/// Rules:
///   * applicant  - only requests they filed (`requester_id` = actor).
///   * executor   - requests in the queue (assigned to them) or, if
///                  unassigned, any request in the queue (the shared queue).
///   * manager    - aggregate view; sees the request object only when it is
///                  assigned to them or explicitly queued.
///   * admin      - everything.
///
/// A request with no `requester_id` (legacy drafts created before
/// authentication existed) is visible to moderators but NOT to applicants.
pub fn can_view_request(actor: Actor, ownership: RequestOwnership) -> Bool {
  case actor.role {
    Admin -> True
    Applicant ->
      case ownership.requester_id {
        Some(requester) -> requester == actor.user_id
        None -> False
      }
    Executor | Manager ->
      case ownership.assignee_id {
        Some(assignee) -> assignee == actor.user_id
        None -> True
      }
    UnknownRole(_) -> False
  }
}

/// Can this actor PERFORM moderation actions on this request?
///
/// Narrower than `can_view_request`: an applicant can look at their own
/// request but can never moderate it.
pub fn can_moderate(actor: Actor, ownership: RequestOwnership) -> Bool {
  case actor.role {
    Admin -> True
    Executor ->
      case ownership.assignee_id {
        Some(assignee) -> assignee == actor.user_id
        None -> True
      }
    Manager ->
      case ownership.assignee_id {
        Some(assignee) -> assignee == actor.user_id
        None -> True
      }
    Applicant | UnknownRole(_) -> False
  }
}

/// Can this actor ACT AS THE APPLICANT (respond to a clarification)?
///
/// Only the applicant who filed the request, and only while the request is
/// actually awaiting their answer.
pub fn can_respond_as_applicant(
  actor: Actor,
  ownership: RequestOwnership,
  current_status: String,
) -> Bool {
  case actor.role {
    Applicant ->
      case ownership.requester_id {
        Some(requester) ->
          requester == actor.user_id && current_status == "returned"
        None -> False
      }
    Executor | Manager | Admin | UnknownRole(_) -> False
  }
}
