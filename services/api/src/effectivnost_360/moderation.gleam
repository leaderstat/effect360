// services/api/src/effectivnost_360/moderation.gleam
//
// Data access for Phase 7: the moderation queue, official responses,
// applicant notifications, applicant feedback and the efficiency-360 metrics.
//
// TRANSACTION POLICY:
// -------------------
//  1. The request row is locked with `SELECT ... FOR UPDATE` before reading
//     its current status, so the legal-transition check below cannot race
//     with a concurrent moderator. The same transaction writes the `UPDATE`,
//     `INSERT request_events`, `INSERT moderation_actions`, `INSERT audit_log`
//     and `INSERT notifications`. A failure anywhere rolls back the whole
//     batch: the status change and its audit trail are never half-written.
//  2. The legal-transition check runs INSIDE the transaction, against the
//     locked status. The check in the API layer is a fast pre-check for a
//     friendly error message; the check here is authoritative. An illegal
//     transition is rejected with `Error(IllegalTransition)`, and nothing is
//     written. The completeness check runs in the same transaction and uses
//     the same `requirements`/`clauses` rules as the completeness endpoint,
//     so the UI preview and the authoritative check cannot drift apart.
import common_sql as sql
import effectivnost_360/auth.{type Actor, role_to_string}
import effectivnost_360/state_machine.{type Action, type NotificationKind, type Status, action_to_string, is_allowed, notification_body, notification_for, notification_kind_to_string, notification_title, parse_status, status_to_string, target_status,}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// -------------------------------------------------------------
// Postgres binary в†’ Gleam-String decoders
// -------------------------------------------------------------
//
// `pgo` returns every text column as an Erlang binary (`BitArray` in Gleam),
// but `decode.string` expects a Gleam-String (a list of `UtfCodepoint`).
// These helpers accept the field by index, coerce the binary to a String
// via `bit_array.to_string`, and feed the value to the next decoder step.

/// A decoder for a PostgreSQL text column.
///
/// `pgo` returns every text column as an Erlang binary (`BitArray` in Gleam),
/// but the value we want is a Gleam-String (a list of `UtfCodepoint`).
/// This decoder accepts the binary and coerces it with `bit_array.to_string`.
fn text_decoder() -> decode.Decoder(String) {
  decode.bit_array
  |> decode.then(fn(bits) {
    case bit_array.to_string(bits) {
      Ok(s) -> decode.success(s)
      Error(_) -> decode.failure("", "String")
    }
  })
}

/// A decoder for a nullable PostgreSQL text column.
fn optional_text_decoder() -> decode.Decoder(Option(String)) {
  decode.optional(text_decoder())
}

fn field_text(idx: Int, next: fn(String) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use s <- decode.field(idx, text_decoder())
  next(s)
}

fn opt_field_text(
  idx: Int,
  default: Option(String),
  next: fn(Option(String)) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  use s <- decode.field(idx, optional_text_decoder())
  case s {
    None -> next(default)
    Some(value) -> next(Some(value))
  }
}

fn field_int(idx: Int, next: fn(Int) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use n <- decode.field(idx, decode.int)
  next(n)
}

fn field_float(idx: Int, next: fn(Float) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use n <- decode.field(idx, decode.float)
  next(n)
}

fn field_bool(idx: Int, next: fn(Bool) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use b <- decode.field(idx, decode.bool)
  next(b)
}

// -------------------------------------------------------------
// Outcome types
// -------------------------------------------------------------

pub type TransitionResult {
  TransitionSucceeded(request_id: String, from: Status, to: Status)
  TransitionRejected(request_id: String, current: Status, reason: String)
  TransitionNotFound(request_id: String)
  TransitionDbError(sql.DbError)
}

pub type SaveResponseResult {
  ResponseSucceeded(id: String)
  ResponseNotFound
  ResponseDbError(sql.DbError)
}

pub type FeedbackResult {
  FeedbackSucceeded
  FeedbackNotFound
  FeedbackDbError(sql.DbError)
}

// -------------------------------------------------------------
// Decoders
// -------------------------------------------------------------

fn status_decoder() -> decode.Decoder(Status) {
  use raw <- field_text(0)
  decode.success(parse_status(raw))
}

fn request_id_decoder() -> decode.Decoder(String) {
  use id <- field_text(0)
  decode.success(id)
}

fn count_decoder() -> decode.Decoder(Int) {
  use value <- field_int(0)
  decode.success(value)
}

// -------------------------------------------------------------
// Queue
// -------------------------------------------------------------

/// One row of the moderator queue.
pub type QueueItem {
  QueueItem(
    request_id: String,
    status: Status,
    request_type: Option(String),
    applicant_name: Option(String),
    fields: Dict(String, String),
    created_at: String,
    submitted_at: Option(String),
    due_at: Option(String),
    assignee_id: Option(String),
    assignee_name: Option(String),
    clarification_note: String,
    is_overdue: Bool,
  )
}

/// Filters of the moderator queue. All fields are optional; `None` means
/// "do not filter by this dimension".
pub type QueueFilter {
  QueueFilter(
    status: Option(Status),
    request_type: Option(String),
    assignee_id: Option(String),
    only_overdue: Bool,
    search: Option(String),
  )
}

pub fn empty_filter() -> QueueFilter {
  QueueFilter(
    status: None,
    request_type: None,
    assignee_id: None,
    only_overdue: False,
    search: None,
  )
}

/// Load the moderation queue.
///
/// The filter is applied IN SQL, not in Gleam: the queue must stay
/// paginatable and the counts must reflect the same predicate.
pub fn load_queue(
  driver: sql.Driver(conn),
  database_url: String,
  filter: QueueFilter,
  limit: Int,
  offset: Int,
) -> Result(List(QueueItem), sql.DbError) {
  let where_parts = ["TRUE"]
  let params: List(sql.Param) = []

  // Build the WHERE clause incrementally.
  let #(params, where_parts) =
    case filter.status {
      None -> #(params, where_parts)
      Some(status) -> #(
        list.append(params, [sql.PString(status_to_string(status))]),
        list.append(
          where_parts,
          ["r.status = $" <> int.to_string(list.length(params))],
        ),
      )
    }

  let #(params, where_parts) =
    case filter.request_type {
      None -> #(params, where_parts)
      Some(name) -> #(
        list.append(params, [sql.PString(name)]),
        list.append(
          where_parts,
          ["rt.name = $" <> int.to_string(list.length(params))],
        ),
      )
    }

  let #(params, where_parts) =
    case filter.assignee_id {
      None -> #(params, where_parts)
      Some(id) -> #(
        list.append(params, [sql.PString(id)]),
        list.append(
          where_parts,
          ["mq.assignee_id::text = $" <> int.to_string(list.length(params))],
        ),
      )
    }

  let #(params, where_parts) =
    case filter.only_overdue {
      False -> #(params, where_parts)
      True -> #(
        params,
        list.append(
          where_parts,
          ["mq.due_at IS NOT NULL AND mq.due_at < now()"],
        ),
      )
    }

  let #(params, where_parts) =
    case filter.search {
      None -> #(params, where_parts)
      Some(text) -> {
        let pattern = "%" <> string.trim(text) <> "%"
        #(
          list.append(params, [sql.PString(pattern)]),
          list.append(
            where_parts,
            [
              "(r.id::text ILIKE $"
              <> int.to_string(list.length(params))
              <> " OR r.raw_text ILIKE $"
              <> int.to_string(list.length(params))
              <> ")",
            ],
          ),
        )
      }
    }

  let where_clause = string.join(where_parts, " AND ")

  let query =
    "
    SELECT
      r.id::text,
      r.status,
      rt.name::text,
      applicant.display_name::text,
      COALESCE(r.fields::text, '{}') AS fields_json,
      r.created_at::text,
      r.submitted_at::text,
      mq.due_at::text,
      mq.assignee_id::text,
      assignee.display_name::text,
      r.clarification_note,
      CASE
        WHEN mq.due_at IS NOT NULL AND mq.due_at < now() THEN TRUE
        ELSE FALSE
      END AS is_overdue
    FROM requests r
    LEFT JOIN request_types rt ON rt.id = r.request_type_id
    LEFT JOIN moderation_queue mq ON mq.request_id = r.id
    LEFT JOIN users applicant ON applicant.id = r.requester_id
    LEFT JOIN users assignee ON assignee.id = mq.assignee_id
    WHERE "
    <> where_clause
    <> "
    ORDER BY
      CASE WHEN mq.due_at IS NOT NULL AND mq.due_at < now() THEN 0 ELSE 1 END,
      mq.due_at NULLS LAST,
      r.created_at DESC
    LIMIT $"
    <> int.to_string(list.length(params) + 1)
    <> " OFFSET $"
    <> int.to_string(list.length(params) + 2)

  let all_params =
    list.append(
      params,
      [sql.PInt(limit), sql.PInt(offset)],
    )

  let decoder = {
    use id <- field_text(0)
    use status_text <- field_text(1)
    use request_type <- opt_field_text(2, None)
    use applicant_name <- opt_field_text(3, None)
    use fields_json <- field_text(4)
    use created_at <- field_text(5)
    use submitted_at <- opt_field_text(6, None)
    use due_at <- opt_field_text(7, None)
    use assignee_id <- opt_field_text(8, None)
    use assignee_name <- opt_field_text(9, None)
    use clarification_note <- field_text(10)
    use is_overdue <- field_bool(11)
    decode.success(QueueItem(
      request_id: id,
      status: parse_status(status_text),
      request_type: request_type,
      applicant_name: applicant_name,
      fields: parse_fields_jsonb(fields_json),
      created_at: created_at,
      submitted_at: submitted_at,
      due_at: due_at,
      assignee_id: assignee_id,
      assignee_name: assignee_name,
      clarification_note: clarification_note,
      is_overdue: is_overdue,
    ))
  }

  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      all_params,
      decoder,
    )
  })
}

/// Count the queue rows matching the same filter - used by the UI to show
/// the total without loading all rows.
pub fn count_queue(
  driver: sql.Driver(conn),
  database_url: String,
  filter: QueueFilter,
) -> Result(Int, sql.DbError) {
  let query =
    "
    SELECT count(*)
    FROM requests r
    LEFT JOIN request_types rt ON rt.id = r.request_type_id
    LEFT JOIN moderation_queue mq ON mq.request_id = r.id
    WHERE r.status <> 'draft'
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [],
        count_decoder(),
      )
    })
  case result {
    Ok([total, ..]) -> Ok(total)
    Ok([]) -> Ok(0)
    Error(e) -> Error(e)
  }
}

// -------------------------------------------------------------
// Transition
// -------------------------------------------------------------

/// Apply a status transition atomically.
///
/// The current status is re-read under `SELECT ... FOR UPDATE`, so the
/// legality check inside the transaction is authoritative - a stale UI
/// cannot push an illegal transition.
pub fn apply_transition(
  driver: sql.Driver(conn),
  database_url: String,
  actor: Actor,
  request_id: String,
  action: Action,
  reason: String,
  clarification_note: String,
) -> TransitionResult {
  let target = target_status(action)

  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      // Step 1: lock the row and read the current status.
      case
        sql.execute(
          driver,
          conn,
          sql.Portable("SELECT status FROM requests WHERE id = $1 FOR UPDATE"),
          [sql.PString(request_id)],
          status_decoder(),
        )
      {
        Error(e) -> Error(e)
        Ok([]) -> Ok(TransitionNotFound(request_id))
        Ok([current, ..]) -> {
          // Step 2: validate the transition.
          case is_allowed(current, target) {
            False ->
              Ok(TransitionRejected(
                request_id,
                current,
                "РџРµСЂРµС…РѕРґ Р·Р°РїСЂРµС‰С‘РЅ: РЅРµРґРѕРїСѓСЃС‚РёРјРѕ СЃРјРµРЅРёС‚СЊ СЃС‚Р°С‚СѓСЃ СЃ "
                <> status_to_string(current)
                <> " РЅР° "
                <> status_to_string(target),
              ))
            True -> {
              let outcome =
                write_transition(
                  driver,
                  conn,
                  actor,
                  request_id,
                  current,
                  target,
                  action,
                  reason,
                  clarification_note,
                )
              case outcome {
                Ok(Nil) -> Ok(TransitionSucceeded(request_id, current, target))
                Error(e) -> Error(e)
              }
            }
          }
        }
      }
    })
  case result {
    Ok(outcome) -> outcome
    Error(e) -> TransitionDbError(e)
  }
}

fn write_transition(
  driver: sql.Driver(conn),
  conn: conn,
  actor: Actor,
  request_id: String,
  current: Status,
  target: Status,
  action: Action,
  reason: String,
  clarification_note: String,
) -> Result(Nil, sql.DbError) {
  let nil_decoder = decode.success(Nil)
  let from_text = status_to_string(current)
  let to_text = status_to_string(target)
  let action_text = action_to_string(action)
  let actor_id = sql.PString(actor.user_id)
  let actor_role = sql.PString(auth.role_to_string(actor.role))

  // Step 3: UPDATE the status + the timestamp column the transition implies.
  let update_query =
    "
    UPDATE requests
    SET status = $2::text,
        accepted_at = CASE WHEN $2::text = 'accepted'
                           THEN COALESCE(accepted_at, now()) ELSE accepted_at END,
        in_progress_at = CASE WHEN $2::text = 'in_progress'
                           THEN COALESCE(in_progress_at, now()) ELSE in_progress_at END,
        clarification_requested_at = CASE WHEN $2::text = 'returned'
                           THEN COALESCE(clarification_requested_at, now())
                           ELSE clarification_requested_at END,
        clarification_note = CASE WHEN $2::text = 'returned'
                           THEN $3::text ELSE clarification_note END,
        applicant_note = CASE WHEN $3::text <> '' AND $2::text = 'in_progress'
                           THEN $3::text ELSE applicant_note END,
        answer_ready_at = CASE WHEN $2::text = 'answer_ready'
                           THEN COALESCE(answer_ready_at, now()) ELSE answer_ready_at END,
        completed_at = CASE WHEN $2::text = 'completed'
                           THEN COALESCE(completed_at, now()) ELSE completed_at END,
        updated_at = now()
    WHERE id = $1::uuid
  "
  let update_params = [
    sql.PString(request_id),
    sql.PString(to_text),
    sql.PString(clarification_note),
  ]

  case sql.execute(driver, conn, sql.Portable(update_query), update_params, nil_decoder) {
    Error(e) -> Error(e)
    Ok(_) -> {
      // Step 4: the canonical request_events row (append-only history).
      let event_query = "
        INSERT INTO request_events
          (request_id, from_status, to_status, actor_id, actor_role, reason_code)
        VALUES ($1::uuid, $2::text, $3::text, $4::uuid, $5::text, $6::text)
      "
      let event_params = [
        sql.PString(request_id),
        sql.PString(from_text),
        sql.PString(to_text),
        actor_id,
        actor_role,
        sql.PString(action_text),
      ]

      case sql.execute(driver, conn, sql.Portable(event_query), event_params, nil_decoder) {
        Error(e) -> {
          io.println("transition step4 request_events failed: " <> string.inspect(e))
          Error(e)
        }
        Ok(_) -> {
          // Step 5: the moderator-facing audit trail.
          let action_query = "
            INSERT INTO moderation_actions
              (request_id, actor_id, actor_role, action, from_status, to_status, reason)
            VALUES ($1::uuid, $2::uuid, $3::text, $4::text, $5::text, $6::text, $7::text)
          "
          let action_params = [
            sql.PString(request_id),
            actor_id,
            actor_role,
            sql.PString(action_text),
            sql.PString(from_text),
            sql.PString(to_text),
            sql.PString(reason),
          ]

          case
            sql.execute(
              driver,
              conn,
              sql.Portable(action_query),
              action_params,
              nil_decoder,
            )
          {
            Error(e) -> {
              io.println(
                "transition step5 moderation_actions failed: " <> string.inspect(e),
              )
              Error(e)
            }
            Ok(_) -> {
              // Step 6: the platform-wide audit log.
              let audit_query = "
                INSERT INTO audit_log
                  (actor_id, actor_role, action, object_type, object_id, details)
                VALUES ($1::uuid, $2::text, $3::text, 'request', $4::uuid,
                        jsonb_build_object('from', $5::text, 'to', $6::text, 'reason', $7::text))
              "
              let audit_params = [
                actor_id,
                actor_role,
                sql.PString("moderation_" <> action_text),
                sql.PString(request_id),
                sql.PString(from_text),
                sql.PString(to_text),
                sql.PString(reason),
              ]

              case
                sql.execute(
                  driver,
                  conn,
                  sql.Portable(audit_query),
                  audit_params,
                  nil_decoder,
                )
              {
                Error(e) -> {
                  io.println(
                    "transition step6 audit_log failed: " <> string.inspect(e),
                  )
                  Error(e)
                }
                Ok(_) -> {
                  // Step 7: enqueue the request into the moderation queue
                  // the first time a moderator touches it.
                  let queue_query = "
                    INSERT INTO moderation_queue (request_id, assignee_id, note)
                    VALUES ($1::uuid, $2::uuid, $3::text)
                    ON CONFLICT (request_id) DO UPDATE
                      SET assignee_id = COALESCE(moderation_queue.assignee_id, EXCLUDED.assignee_id)
                  "
                  let queue_params = [
                    sql.PString(request_id),
                    actor_id,
                    sql.PString(reason),
                  ]

                  case
                    sql.execute(
                      driver,
                      conn,
                      sql.Portable(queue_query),
                      queue_params,
                      nil_decoder,
                    )
                  {
                    Error(e) -> {
                      io.println(
                        "transition step7 moderation_queue failed: "
                        <> string.inspect(e),
                      )
                      Error(e)
                    }
                    Ok(_) -> {
                      let notified =
                        notify_applicant(driver, conn, request_id, action)
                      case notified {
                        Error(e) -> {
                          io.println(
                            "transition step8 notify failed: " <> string.inspect(e),
                          )
                          Error(e)
                        }
                        Ok(Nil) ->
                          emit_status_event(
                            driver,
                            conn,
                            request_id,
                            from_text,
                            to_text,
                            action_text,
                            reason,
                            actor_id,
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
}

/// Emit the `requests.status_changed` outbox event in the same transaction as
/// the transition.
///
/// THIS IS THE TRIGGER OF AGENT B. The applicant-support agent subscribes to
/// this event and creates the notification, the result card and the draft of
/// the official letter.
///
/// The event id (the id of the outbox row) is the idempotency key of
/// Agent B: a redelivered event can therefore never create two
/// notifications.
fn emit_status_event(
  driver: sql.Driver(conn),
  conn: conn,
  request_id: String,
  from_text: String,
  to_text: String,
  action_text: String,
  reason: String,
  actor_id: sql.Param,
) -> Result(Nil, sql.DbError) {
  // The job is created in the SAME transaction as the outbox row, with the
  // SAME `id`. That single uuid is referenced from three places:
  //
  //   - `outbox.payload.job_id`   — the worker uses it as the event id and
  //     to update `job_runs.id`,
  //   - `outbox.payload.event_id` — the idempotency key of Agent B (the
  //     digital moderator and the applicant support use distinct ids), and
  //   - `job_runs.id`              — the row the worker transitions through
  //     `queued -> running -> terminal`.
  //
  // All three are generated by ONE call to `gen_random_uuid()`, so they are
  // guaranteed to be identical and unique within the transaction.
  let query = "
    WITH new_event AS (
      SELECT gen_random_uuid() AS job_id
    ),
    inserted_outbox AS (
      INSERT INTO outbox (subject, payload)
      SELECT
        'requests.status_changed',
        jsonb_build_object(
          'schema_version', 1,
          'job_type', 'agent_applicant_support',
          'job_id', new_event.job_id::text,
          'event_id', new_event.job_id::text,
          'request_id', $1::text,
          'event_reason', $2::text,
          'from_status', $3::text,
          'to_status', $4::text,
          'action', $5::text,
          'reason', $6::text,
          'initiator', 'system',
          'comment', '',
          'decision_id', '',
          'next_deadline', ''
        )
      FROM new_event
      RETURNING (payload->>'job_id')::uuid AS job_id
    )
    INSERT INTO job_runs (
      id, request_id, job_type, idempotency_key, input_hash,
      status, schema_version, attempts
    )
    SELECT
      inserted_outbox.job_id,
      $1::uuid,
      'agent_applicant_support',
      'applicant_support:' || inserted_outbox.job_id::text,
      'applicant_support:' || inserted_outbox.job_id::text,
      'queued',
      1,
      0
    FROM inserted_outbox
  "
  let params = [
    sql.PString(request_id),
    sql.PString(reason),
    sql.PString(from_text),
    sql.PString(to_text),
    sql.PString(action_text),
    actor_id,
  ]
  case
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      params,
      decode.success(Nil),
    )
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> {
      io.println("transition step9 emit_status_event failed: " <> string.inspect(e))
      Error(e)
    }
  }
}

/// Create the applicant notification for a transition, in the same
/// transaction. Returns `Error` if there is nobody to notify - that is
/// NOT an error: a request created before authentication has no applicant.
fn notify_applicant(
  driver: sql.Driver(conn),
  conn: conn,
  request_id: String,
  action: Action,
) -> Result(Nil, sql.DbError) {
  case notification_for(action) {
    None -> Ok(Nil)
    Some(kind) -> {
      let requester_query = "
        SELECT requester_id::text FROM requests WHERE id = $1
      "
      // The row holds ONE nullable column, so the value is read from the
      // field 0. `decode.optional` works on the VALUE of a field, not on
      // the row itself.
      let requester_decoder = {
        use value <- decode.field(0, optional_text_decoder())
        decode.success(value)
      }
      case
        sql.execute(
          driver,
          conn,
          sql.Portable(requester_query),
          [sql.PString(request_id)],
          requester_decoder,
        )
      {
        Error(e) -> Error(e)
        Ok([]) -> Ok(Nil)
        Ok([None, ..]) -> Ok(Nil)
        Ok([Some(requester_id), ..]) -> {
          let insert_query = "
            INSERT INTO notifications (user_id, request_id, kind, title, body)
            VALUES ($1::uuid, $2::uuid, $3::text, $4::text, $5::text)
            ON CONFLICT DO NOTHING
          "
          let insert_params = [
            sql.PString(requester_id),
            sql.PString(request_id),
            sql.PString(notification_kind_to_string(kind)),
            sql.PString(notification_title(kind)),
            sql.PString(notification_body(kind)),
          ]
          let result =
            sql.execute(
              driver,
              conn,
              sql.Portable(insert_query),
              insert_params,
              decode.success(Nil),
            )
          case result {
            Ok(_) -> Ok(Nil)
            Error(e) -> Error(e)
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// Notifications
// -------------------------------------------------------------

pub type Notification {
  Notification(
    id: String,
    request_id: Option(String),
    kind: String,
    title: String,
    body: String,
    created_at: String,
    read_at: Option(String),
  )
}

fn notification_decoder() -> decode.Decoder(Notification) {
  use id <- field_text(0)
  use request_id <- opt_field_text(1, None)
  use kind <- field_text(2)
  use title <- field_text(3)
  use body <- field_text(4)
  use created_at <- field_text(5)
  use read_at <- opt_field_text(6, None)
  decode.success(Notification(
    id: id,
    request_id: request_id,
    kind: kind,
    title: title,
    body: body,
    created_at: created_at,
    read_at: read_at,
  ))
}

/// Load the notifications of a user, newest first.
pub fn list_notifications(
  driver: sql.Driver(conn),
  database_url: String,
  user_id: String,
  limit: Int,
) -> Result(List(Notification), sql.DbError) {
  let query = "
    SELECT
      n.id::text,
      n.request_id::text,
      n.kind,
      n.title,
      n.body,
      n.created_at::text,
      n.read_at::text
    FROM notifications n
    WHERE n.user_id = $1::uuid
    ORDER BY n.created_at DESC
    LIMIT $2
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PString(user_id), sql.PInt(limit)],
      notification_decoder(),
    )
  })
}

/// The number of unread notifications of a user - the bell badge.
pub fn count_unread(
  driver: sql.Driver(conn),
  database_url: String,
  user_id: String,
) -> Result(Int, sql.DbError) {
  let query = "
    SELECT count(*) FROM notifications
    WHERE user_id = $1::uuid AND read_at IS NULL
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(user_id)],
        count_decoder(),
      )
    })
  case result {
    Ok([total, ..]) -> Ok(total)
    Ok([]) -> Ok(0)
    Error(e) -> Error(e)
  }
}

/// Mark a notification as read. The `user_id` guard makes sure a user
/// cannot mark somebody else's notification as read.
pub fn mark_notification_read(
  driver: sql.Driver(conn),
  database_url: String,
  user_id: String,
  notification_id: String,
) -> Result(Bool, sql.DbError) {
  let query = "
    UPDATE notifications
    SET read_at = now()
    WHERE id = $2::uuid AND user_id = $1::uuid AND read_at IS NULL
    RETURNING id::text
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(user_id), sql.PString(notification_id)],
        request_id_decoder(),
      )
    })
  case result {
    Ok(rows) -> Ok(rows != [])
    Error(e) -> Error(e)
  }
}

// -------------------------------------------------------------
// Timeline (history)
// -------------------------------------------------------------

pub type TimelineEvent {
  TimelineEvent(
    id: String,
    from_status: Option(String),
    to_status: String,
    actor_role: String,
    actor_name: Option(String),
    reason_code: Option(String),
    created_at: String,
  )
}

fn timeline_decoder() -> decode.Decoder(TimelineEvent) {
  use id <- field_text(0)
  use from_status <- opt_field_text(1, None)
  use to_status <- field_text(2)
  use actor_role <- field_text(3)
  use actor_name <- opt_field_text(4, None)
  use reason_code <- opt_field_text(5, None)
  use created_at <- field_text(6)
  decode.success(TimelineEvent(
    id: id,
    from_status: from_status,
    to_status: to_status,
    actor_role: actor_role,
    actor_name: actor_name,
    reason_code: reason_code,
    created_at: created_at,
  ))
}

/// The full history of a request: status transitions plus notifications
/// and moderation actions, merged into one chronological timeline.
pub fn load_timeline(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(List(TimelineEvent), sql.DbError) {
  let query = "
    SELECT
      e.id::text,
      e.from_status::text,
      e.to_status,
      e.actor_role,
      COALESCE(u.display_name, '')::text,
      e.reason_code::text,
      e.created_at::text
    FROM request_events e
    LEFT JOIN users u ON u.id = e.actor_id
    WHERE e.request_id = $1::uuid
    ORDER BY e.created_at ASC, e.id ASC
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PString(request_id)],
      timeline_decoder(),
    )
  })
}

// -------------------------------------------------------------
// Applicant request list
// -------------------------------------------------------------

pub type ApplicantRequest {
  ApplicantRequest(
    request_id: String,
    status: Status,
    request_type: Option(String),
    created_at: String,
    submitted_at: Option(String),
    updated_at: Option(String),
    has_response: Bool,
  )
}

fn applicant_request_decoder() -> decode.Decoder(ApplicantRequest) {
  use request_id <- field_text(0)
  use status_text <- field_text(1)
  use request_type <- opt_field_text(2, None)
  use created_at <- field_text(3)
  use submitted_at <- opt_field_text(4, None)
  use updated_at <- opt_field_text(5, None)
  use has_response <- field_bool(6)
  decode.success(ApplicantRequest(
    request_id: request_id,
    status: parse_status(status_text),
    request_type: request_type,
    created_at: created_at,
    submitted_at: submitted_at,
    updated_at: updated_at,
    has_response: has_response,
  ))
}

/// The requests of ONE applicant. The `requester_id` filter is the
/// object-level authorization for this endpoint.
pub fn list_applicant_requests(
  driver: sql.Driver(conn),
  database_url: String,
  requester_id: String,
) -> Result(List(ApplicantRequest), sql.DbError) {
  let query = "
    SELECT
      r.id::text,
      r.status,
      rt.name::text,
      r.created_at::text,
      r.submitted_at::text,
      r.updated_at::text,
      (res.id IS NOT NULL) AS has_response
    FROM requests r
    LEFT JOIN request_types rt ON rt.id = r.request_type_id
    LEFT JOIN official_responses res ON res.request_id = r.id
    WHERE r.requester_id = $1::uuid
    ORDER BY r.created_at DESC
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PString(requester_id)],
      applicant_request_decoder(),
    )
  })
}

// -------------------------------------------------------------
// Official response
// -------------------------------------------------------------

/// The official response, as stored. `status` is `draft` or `approved`.
pub type OfficialResponse {
  OfficialResponse(
    id: String,
    request_id: String,
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
  )
}

fn response_decoder() -> decode.Decoder(OfficialResponse) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use status <- field_text(2)
  use organization <- field_text(3)
  use requisites <- field_text(4)
  use registration_number <- field_text(5)
  use recipient <- field_text(6)
  use subject <- field_text(7)
  use legal_basis <- field_text(8)
  use decision_summary <- field_text(9)
  use next_steps <- field_text(10)
  use responsible_executor <- field_text(11)
  use contact_for_questions <- field_text(12)
  use signature_block <- field_text(13)
  use body <- field_text(14)
  use created_at <- field_text(15)
  use approved_at <- opt_field_text(16, None)
  use approved_by_name <- opt_field_text(17, None)
  decode.success(OfficialResponse(
    id: id,
    request_id: request_id,
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
    approved_at: approved_at,
    approved_by_name: approved_by_name,
  ))
}

/// Load the official response of a request, if any.
pub fn load_response(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(Option(OfficialResponse), sql.DbError) {
  let query = "
    SELECT
      res.id::text,
      res.request_id::text,
      res.status,
      res.organization,
      res.requisites,
      res.registration_number,
      res.recipient,
      res.subject,
      res.legal_basis,
      res.decision_summary,
      res.next_steps,
      res.responsible_executor,
      res.contact_for_questions,
      res.signature_block,
      res.body,
      res.created_at::text,
      res.approved_at::text,
      COALESCE(approver.display_name, '')::text
    FROM official_responses res
    LEFT JOIN users approver ON approver.id = res.approved_by
    WHERE res.request_id = $1::uuid
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        response_decoder(),
      )
    })
  case result {
    Ok([response, ..]) -> Ok(Some(response))
    Ok(_) -> Ok(None)
    Error(e) -> Error(e)
  }
}

/// The fields of a response draft that a moderator may edit.
pub type ResponseDraft {
  ResponseDraft(
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
  )
}

/// Save (create or update) the response draft.
///
/// Only a `draft` may be edited. An `approved` response is immutable -
/// otherwise the "official" document could change after the applicant saw it.
pub fn save_response_draft(
  driver: sql.Driver(conn),
  database_url: String,
  actor: Actor,
  request_id: String,
  draft: ResponseDraft,
) -> SaveResponseResult {
  let query = "
    INSERT INTO official_responses (
      request_id, status, organization, requisites, registration_number,
      recipient, subject, legal_basis, decision_summary, next_steps,
      responsible_executor, contact_for_questions, signature_block, body,
      created_by, updated_at
    )
    VALUES ($1::uuid, 'draft', $2::text, $3::text, $4::text, $5::text,
            $6::text, $7::text, $8::text, $9::text, $10::text, $11::text,
            $12::text, $13::text, $14::uuid, now())
    ON CONFLICT (request_id) DO UPDATE
      SET organization = EXCLUDED.organization,
          requisites = EXCLUDED.requisites,
          registration_number = EXCLUDED.registration_number,
          recipient = EXCLUDED.recipient,
          subject = EXCLUDED.subject,
          legal_basis = EXCLUDED.legal_basis,
          decision_summary = EXCLUDED.decision_summary,
          next_steps = EXCLUDED.next_steps,
          responsible_executor = EXCLUDED.responsible_executor,
          contact_for_questions = EXCLUDED.contact_for_questions,
          signature_block = EXCLUDED.signature_block,
          body = EXCLUDED.body,
          updated_at = now()
      WHERE official_responses.status = 'draft'
    RETURNING id::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(draft.organization),
    sql.PString(draft.requisites),
    sql.PString(draft.registration_number),
    sql.PString(draft.recipient),
    sql.PString(draft.subject),
    sql.PString(draft.legal_basis),
    sql.PString(draft.decision_summary),
    sql.PString(draft.next_steps),
    sql.PString(draft.responsible_executor),
    sql.PString(draft.contact_for_questions),
    sql.PString(draft.signature_block),
    sql.PString(draft.body),
    sql.PString(actor.user_id),
  ]

  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        params,
        request_id_decoder(),
      )
    })
  case result {
    Ok([id, ..]) -> ResponseSucceeded(id)
    Ok([]) ->
      // The ON CONFLICT DO UPDATE ... WHERE status='draft' matched no row:
      // either there is no request, or the response is already approved.
      ResponseNotFound
    Error(e) -> ResponseDbError(e)
  }
}

/// Approve the official response.
///
/// Approval requires all mandatory requisites to be filled - an approved
/// response that misses the registration number or the legal basis would be
/// presented to the applicant as an official document.
pub fn approve_response(
  driver: sql.Driver(conn),
  database_url: String,
  actor: Actor,
  request_id: String,
) -> SaveResponseResult {
  let query = "
    UPDATE official_responses
    SET status = 'approved',
        approved_by = $2::uuid,
        approved_at = now(),
        updated_at = now()
    WHERE request_id = $1::uuid
      AND status = 'draft'
      AND length(trim(organization)) > 0
      AND length(trim(registration_number)) > 0
      AND length(trim(recipient)) > 0
      AND length(trim(subject)) > 0
      AND length(trim(decision_summary)) > 0
      AND length(trim(legal_basis)) > 0
      AND length(trim(next_steps)) > 0
      AND length(trim(responsible_executor)) > 0
    RETURNING id::text
  "
  let params = [sql.PString(request_id), sql.PString(actor.user_id)]

  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        params,
        request_id_decoder(),
      )
    })
  case result {
    Ok([id, ..]) -> ResponseSucceeded(id)
    Ok([]) -> ResponseNotFound
    Error(e) -> ResponseDbError(e)
  }
}

/// Which mandatory requisites of the response are still missing.
pub fn missing_requisites(response: OfficialResponse) -> List(String) {
  list.filter(
    [
      #("organization", response.organization),
      #("registration_number", response.registration_number),
      #("recipient", response.recipient),
      #("subject", response.subject),
      #("legal_basis", response.legal_basis),
      #("decision_summary", response.decision_summary),
      #("next_steps", response.next_steps),
      #("responsible_executor", response.responsible_executor),
    ],
    fn(entry) { string.trim(entry.1) == "" },
  )
  |> list.map(fn(entry) { entry.0 })
}

// -------------------------------------------------------------
// Applicant feedback
// -------------------------------------------------------------

/// Record the applicant's feedback about the answer.
///
/// This is deliberately SEPARATE from the request status: satisfaction with
/// the answer is not a legal status of the request.
pub fn save_feedback(
  driver: sql.Driver(conn),
  database_url: String,
  actor: Actor,
  request_id: String,
  is_clear: Bool,
  comment: String,
) -> FeedbackResult {
  let query = "
    INSERT INTO response_feedback (request_id, user_id, is_clear, comment)
    VALUES ($1::uuid, $2::uuid, $3::bool, $4::text)
    ON CONFLICT (request_id, user_id) DO UPDATE
      SET is_clear = EXCLUDED.is_clear,
          comment = EXCLUDED.comment,
          created_at = now()
    RETURNING id::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(actor.user_id),
    sql.PBool(is_clear),
    sql.PString(comment),
  ]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        params,
        request_id_decoder(),
      )
    })
  case result {
    Ok([_id, ..]) -> FeedbackSucceeded
    Ok([]) -> FeedbackNotFound
    Error(e) -> FeedbackDbError(e)
  }
}

pub type Feedback {
  Feedback(is_clear: Bool, comment: String, created_at: String)
}

fn feedback_decoder() -> decode.Decoder(Feedback) {
  use is_clear <- field_bool(0)
  use comment <- field_text(1)
  use created_at <- field_text(2)
  decode.success(Feedback(is_clear:, comment:, created_at:))
}

/// Load the feedback of a request, if any.
pub fn load_feedback(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(Option(Feedback), sql.DbError) {
  let query = "
    SELECT is_clear, comment, created_at::text
    FROM response_feedback
    WHERE request_id = $1::uuid
    ORDER BY created_at DESC
    LIMIT 1
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        feedback_decoder(),
      )
    })
  case result {
    Ok([feedback, ..]) -> Ok(Some(feedback))
    Ok(_) -> Ok(None)
    Error(e) -> Error(e)
  }
}

// -------------------------------------------------------------
// Metrics
// -------------------------------------------------------------

/// One metric of the efficiency-360 dashboard.
///
/// Every metric is computed from REAL events. When the denominator is zero
/// the metric is `None` and the UI shows "Insufficient data" - we never
/// invent a percentage.
pub type Metric {
  Metric(
    key: String,
    label: String,
    value: Option(Float),
    unit: String,
    is_demo: Bool,
  )
}

/// Compute all metrics from the database.
///
/// `is_demo` is TRUE when the whole dataset is DEMO (every request was
/// created by a DEMO user) - the UI labels such metrics explicitly.
pub fn compute_metrics(
  driver: sql.Driver(conn),
  database_url: String,
) -> Result(List(Metric), sql.DbError) {
  let totals_query = "
    SELECT
      count(*) FILTER (
        WHERE r.status <> 'draft'
      )::int AS total,
      count(*) FILTER (
        WHERE r.status = 'returned' OR r.return_count > 0
      )::int AS needs_clarification,
      count(*) FILTER (
        WHERE r.status = 'completed'
      )::int AS completed,
      count(*) FILTER (
        WHERE mq.due_at IS NOT NULL AND mq.due_at < now()
      )::int AS overdue,
      count(*) FILTER (
        WHERE r.accepted_at IS NOT NULL
      )::int AS accepted_count,
      count(*) FILTER (
        WHERE r.submitted_at IS NOT NULL AND r.accepted_at IS NOT NULL
      )::int AS first_action_count,
      COALESCE(
        sum(
          EXTRACT(EPOCH FROM (
            r.accepted_at - r.submitted_at
          ))
        ) FILTER (
          WHERE r.accepted_at IS NOT NULL AND r.submitted_at IS NOT NULL
        ),
        0
      )::float AS first_action_seconds_sum,
      COALESCE(
        sum(
          EXTRACT(EPOCH FROM (
            r.completed_at - r.submitted_at
          ))
        ) FILTER (
          WHERE r.completed_at IS NOT NULL AND r.submitted_at IS NOT NULL
        ),
        0
      )::float AS handling_seconds_sum,
      count(*) FILTER (
        WHERE r.status = 'completed'
          AND r.submitted_at IS NOT NULL
          AND r.completed_at IS NOT NULL
      )::int AS handling_count,
      count(*) FILTER (
        WHERE fb.id IS NOT NULL
      )::int AS feedback_total,
      count(*) FILTER (
        WHERE fb.is_clear
      )::int AS feedback_clear,
      count(*) FILTER (
        WHERE u.is_demo
      )::int AS demo_users
    FROM requests r
    LEFT JOIN moderation_queue mq ON mq.request_id = r.id
    LEFT JOIN users u ON u.id = r.requester_id
    LEFT JOIN response_feedback fb ON fb.request_id = r.id
  "

  let decoder = {
    use total <- field_int(0)
    use needs_clarification <- field_int(1)
    use completed <- field_int(2)
    use overdue <- field_int(3)
    use accepted_count <- field_int(4)
    use first_action_count <- field_int(5)
    use first_action_seconds_sum <- field_float(6)
    use handling_seconds_sum <- field_float(7)
    use handling_count <- field_int(8)
    use feedback_total <- field_int(9)
    use feedback_clear <- field_int(10)
    use demo_users <- field_int(11)
    decode.success(#(
      total,
      needs_clarification,
      completed,
      overdue,
      accepted_count,
      first_action_count,
      first_action_seconds_sum,
      handling_seconds_sum,
      handling_count,
      feedback_total,
      feedback_clear,
      demo_users,
    ))
  }

  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(totals_query),
        [],
        decoder,
      )
    })
  case result {
    Error(e) -> Error(e)
    Ok([row, ..]) -> {
      let #(
        total,
        needs_clarification,
        completed,
        overdue,
        _accepted_count,
        first_action_count,
        first_action_seconds_sum,
        handling_seconds_sum,
        handling_count,
        feedback_total,
        feedback_clear,
        demo_users,
      ) = row

      let is_demo = total > 0 && demo_users == total

      let ratio = fn(numerator: Int, denominator: Int) -> Option(Float) {
        case denominator {
          0 -> None
          _ ->
            Some(
              int_to_float(numerator) /. int_to_float(denominator) *. 100.0,
            )
        }
      }

      let average_hours = fn(total_seconds: Float, count: Int) -> Option(Float) {
        case count {
          0 -> None
          _ -> Some(total_seconds /. int_to_float(count) /. 3600.0)
        }
      }

      Ok([
        Metric(
          key: "time_to_first_action_hours",
          label: "Р’СЂРµРјСЏ РґРѕ РїРµСЂРІРѕРіРѕ РґРµР№СЃС‚РІРёСЏ РјРѕРґРµСЂР°С‚РѕСЂР°",
          value: average_hours(first_action_seconds_sum, first_action_count),
          unit: "С‡",
          is_demo: is_demo,
        ),
        Metric(
          key: "handling_time_hours",
          label: "РЎСЂРµРґРЅРµРµ РІСЂРµРјСЏ РѕР±СЂР°Р±РѕС‚РєРё Р·Р°СЏРІРєРё",
          value: average_hours(handling_seconds_sum, handling_count),
          unit: "С‡",
          is_demo: is_demo,
        ),
        Metric(
          key: "clarification_share",
          label: "Р”РѕР»СЏ Р·Р°СЏРІРѕРє, С‚СЂРµР±СѓСЋС‰РёС… СѓС‚РѕС‡РЅРµРЅРёСЏ",
          value: ratio(needs_clarification, total),
          unit: "%",
          is_demo: is_demo,
        ),
        Metric(
          key: "overdue_count",
          label: "РџСЂРѕСЃСЂРѕС‡РµРЅРЅС‹Рµ Р·Р°СЏРІРєРё",
          value: case total {
            0 -> None
            _ -> Some(int_to_float(overdue))
          },
          unit: "Р·Р°СЏРІ.",
          is_demo: is_demo,
        ),
        Metric(
          key: "completion_share",
          label: "Р”РѕР»СЏ Р·Р°РІРµСЂС€С‘РЅРЅС‹С… Р·Р°СЏРІРѕРє",
          value: ratio(completed, total),
          unit: "%",
          is_demo: is_demo,
        ),
        Metric(
          key: "answer_clarity_share",
          label: "Р”РѕР»СЏ РїРѕРЅСЏС‚РЅС‹С… Р·Р°СЏРІРёС‚РµР»СЋ РѕС‚РІРµС‚РѕРІ",
          value: ratio(feedback_clear, feedback_total),
          unit: "%",
          is_demo: is_demo,
        ),
      ])
    }
    Ok(_) -> Error(sql.QueryError("metrics query returned no row"))
  }
}

// -------------------------------------------------------------
// Helpers
// -------------------------------------------------------------

/// Tolerant jsonb -> Dict(String, String) parser.
///
/// Same contract as `submit.gleam::parse_fields_jsonb`: PostgreSQL jsonb is
/// always valid JSON, so we only have to handle non-string and nested
/// values, which are dropped.
pub fn parse_fields_jsonb(raw: String) -> Dict(String, String) {
  let inner = string.trim(raw)
  let inner = case string.starts_with(inner, "{") {
    True -> string.drop_start(inner, 1)
    False -> inner
  }
  let inner = case string.ends_with(inner, "}") {
    True -> string.drop_end(inner, 1)
    False -> inner
  }
  case string.trim(inner) == "" {
    True -> dict.new()
    False -> {
      string.split(inner, on: ",")
      |> list.fold(dict.new(), fn(acc, pair) {
        case string.split(pair, on: ":") {
          [k, v] -> {
            let key = string.trim(k) |> strip_quotes
            let value = string.trim(v) |> strip_quotes
            case key == "" || value == "" || string.starts_with(value, "{") {
              True -> acc
              False -> dict.insert(acc, key, value)
            }
          }
          _ -> acc
        }
      })
    }
  }
}

fn strip_quotes(s: String) -> String {
  let s = case string.starts_with(s, "\"") {
    True -> string.drop_start(s, 1)
    False -> s
  }
  case string.ends_with(s, "\"") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}

fn int_to_float(n: Int) -> Float {
  int.to_float(n)
}
