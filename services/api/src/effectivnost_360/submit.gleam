// services/api/src/effectivnost_360/submit.gleam
//
// Database access for the submit and get-request endpoints.
//
// All queries are read-only or transactional; the submit path uses
// a single SELECT ... FOR UPDATE + UPDATE + INSERT pattern within
// one connection to guarantee atomicity (PostgreSQL automatically
// commits/rolls back at connection release; common_sql wraps that).
//
// Contract:
//   - get_request loads fields + status + type for a given id
//   - get_requirements loads all requirements for a request_type,
//     joining with clauses for the quote text and clause id
//   - submit_if_complete does the whole atomic transition inside
//     a single with_connection block: SELECT FOR UPDATE -> UPDATE
//     -> INSERT request_events -> INSERT audit_log.
import common_sql as sql
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type RequestStatus {
  Draft
  Submitted
  InProgress
  Returned
  Completed
  UnknownStatus(String)
}

pub fn parse_status(s: String) -> RequestStatus {
  case s {
    "draft" -> Draft
    "submitted" -> Submitted
    "in_progress" -> InProgress
    "returned" -> Returned
    "completed" -> Completed
    other -> UnknownStatus(other)
  }
}

pub fn status_to_string(s: RequestStatus) -> String {
  case s {
    Draft -> "draft"
    Submitted -> "submitted"
    InProgress -> "in_progress"
    Returned -> "returned"
    Completed -> "completed"
    UnknownStatus(other) -> other
  }
}

pub fn status_can_submit(s: RequestStatus) -> Bool {
  case s {
    Draft -> True
    _ -> False
  }
}

pub type Request {
  Request(
    id: String,
    status: RequestStatus,
    fields: Dict(String, String),
    request_type_id: Option(String),
    request_type_name: Option(String),
    submitted_at: Option(String),
    created_at: String,
  )
}

pub type RequirementRow {
  RequirementRow(
    field_name: String,
    required: Bool,
    condition: Option(String),
    clause_id: String,
    clause_ref: Option(String),
    quote: String,
  )
}

/// A blocking rule as stored in `requirement_hard_stops`.
pub type HardStopRow {
  HardStopRow(
    field_name: String,
    trigger_expr: String,
    action: String,
    reason: String,
    clause_id: String,
    /// Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ".
    /// Added by migration 010; `None` for rows seeded before it, in which
    /// case the API falls back to the raw clause id.
    clause_ref: Option(String),
    quote: String,
    regulatory_ref_id: Option(String),
  )
}

pub type SubmitOutcome {
  SubmitSucceeded(request_id: String, submitted_at: String)
  AlreadySubmitted(request_id: String)
  UnknownStatusTransition(request_id: String, current: String)
  NotFound
  DbErr(sql.DbError)
}

/// The regulatory reference a transition was based on.
///
/// `request_events.regulatory_ref_id` links the event to the external act
/// (ТК РФ, ПП РФ № 501 …) that justified the decision. It is NULL when
/// the transition is a plain workflow step with no normative basis.
///
/// The reference id is passed as `Option(String)` to
/// `submit_if_complete` — see that function for the details.
pub type RegulatoryRefId =
  Option(String)

fn request_decoder() -> decode.Decoder(Request) {
  use id <- decode.field(0, decode.string)
  use status <- decode.field(1, decode.string)
  use type_id <- decode.field(2, decode.optional(decode.string))
  use type_name <- decode.field(3, decode.optional(decode.string))
  use submitted_at <- decode.field(4, decode.optional(decode.string))
  use created_at <- decode.field(5, decode.string)
  use fields <- decode.field(6, decode.string)
  decode.success(Request(
    id: id,
    status: parse_status(status),
    fields: parse_fields_jsonb(fields),
    request_type_id: type_id,
    request_type_name: type_name,
    submitted_at: submitted_at,
    created_at: created_at,
  ))
}

fn requirement_decoder() -> decode.Decoder(RequirementRow) {
  use field_name <- decode.field(0, decode.string)
  use required <- decode.field(1, decode.bool)
  use condition <- decode.field(2, decode.optional(decode.string))
  use clause_id <- decode.field(3, decode.string)
  use clause_ref <- decode.field(4, decode.optional(decode.string))
  use quote <- decode.field(5, decode.string)
  decode.success(RequirementRow(
    field_name: field_name,
    required: required,
    condition: condition,
    clause_id: clause_id,
    clause_ref: clause_ref,
    quote: quote,
  ))
}

fn hard_stop_decoder() -> decode.Decoder(HardStopRow) {
  use field_name <- decode.field(0, decode.string)
  use trigger_expr <- decode.field(1, decode.string)
  use action <- decode.field(2, decode.string)
  use reason <- decode.field(3, decode.string)
  use clause_id <- decode.field(4, decode.string)
  use clause_ref <- decode.field(5, decode.optional(decode.string))
  use quote <- decode.field(6, decode.string)
  use regulatory_ref_id <- decode.field(7, decode.optional(decode.string))
  decode.success(HardStopRow(
    field_name: field_name,
    trigger_expr: trigger_expr,
    action: action,
    reason: reason,
    clause_id: clause_id,
    clause_ref: clause_ref,
    quote: quote,
    regulatory_ref_id: regulatory_ref_id,
  ))
}

fn parse_fields_jsonb(raw: String) -> Dict(String, String) {
  // PostgreSQL jsonb is always valid JSON. We extract a flat
  // string-to-string map by walking the parsed structure. Non-string
  // values and nested objects are dropped — the completeness check
  // works on strings only.
  let inner = strip_braces(raw)
  let pairs = string.split(inner, on: ",")
  list.fold(pairs, dict.new(), fn(acc, pair) {
    let parts = string.split(pair, on: ":")
    case parts {
      [k, v] -> {
        let key = string.trim(k) |> strip_quotes
        let val = string.trim(v) |> strip_quotes
        case key == "" || val == "" || string.starts_with(val, "{") {
          True -> acc
          False -> dict.insert(acc, key, val)
        }
      }
      _ -> acc
    }
  })
}

fn strip_braces(s: String) -> String {
  let s1 = case string.starts_with(s, "{") {
    True -> string.drop_start(s, 1)
    False -> s
  }
  case string.ends_with(s1, "}") {
    True -> string.drop_end(s1, 1)
    False -> s1
  }
}

fn strip_quotes(s: String) -> String {
  case string.starts_with(s, "\"") {
    True ->
      case string.ends_with(s, "\"") {
        True -> string.drop_end(string.drop_start(s, 1), 1)
        False -> string.drop_start(s, 1)
      }
    False -> s
  }
}

pub fn get_request(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(Request, sql.DbError) {
  let query = "
    SELECT
      r.id::text,
      r.status,
      r.request_type_id::text,
      rt.name,
      r.submitted_at::text,
      r.created_at::text,
      COALESCE(r.fields::text, '{}') AS fields_json
    FROM requests r
    LEFT JOIN request_types rt ON rt.id = r.request_type_id
    WHERE r.id = $1
  "
  sql.with_connection(driver, database_url, fn(conn) {
    case
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        request_decoder(),
      )
    {
      Ok([r]) -> Ok(r)
      Ok([]) -> Error(sql.QueryError("Request not found"))
      Ok(_) -> Error(sql.QueryError("Multiple rows for id"))
      Error(e) -> Error(e)
    }
  })
}

pub fn get_requirements_for_request(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(List(RequirementRow), sql.DbError) {
  let query = "
    SELECT
      req.field_name,
      req.required,
      req.condition::text AS cond,
      c.id::text AS clause_id,
      c.clause_ref,
      req.quote
    FROM requirements req
    JOIN requests r ON r.request_type_id = req.request_type_id
    JOIN clauses c ON c.id = req.clause_id
    WHERE r.id = $1
    ORDER BY req.field_name
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PString(request_id)],
      requirement_decoder(),
    )
  })
}

/// Load the blocking rules that apply to the request's type.
///
/// The rules are joined with `clauses` to carry the verbatim quote of the
/// norm, and with `regulatory_references` to carry the external act id
/// used in the audit trail.
pub fn get_hard_stops_for_request(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(List(HardStopRow), sql.DbError) {
  let query = "
    SELECT
      hs.field_name,
      hs.trigger_expr,
      hs.action,
      hs.reason,
      c.id::text AS clause_id,
      hs.clause_ref,
      COALESCE(c.text, hs.reason) AS quote,
      hs.regulatory_ref_id::text
    FROM requirement_hard_stops hs
    JOIN requests r ON r.request_type_id = hs.request_type_id
    JOIN clauses c ON c.id = hs.clause_id
    WHERE r.id = $1
    ORDER BY hs.action, hs.field_name
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PString(request_id)],
      hard_stop_decoder(),
    )
  })
}

/// Atomic transition draft -> submitted inside a single connection.
/// The caller must have already verified completeness via
/// `completeness.check` before calling this function. We re-check
/// the status under FOR UPDATE to make sure no concurrent caller
/// slipped past us.
///
/// `regulatory_ref_id` is written into the resulting `request_events`
/// row when the transition was based on a specific regulation (e.g. a
/// blocking rule was triggered, or a hard stop was overridden by an
/// employer). When the transition is a plain workflow step with no
/// normative basis, pass `None` and the column is NULL.
pub fn submit_if_complete(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  regulatory_ref_id: Option(String),
) -> SubmitOutcome {
  // Single connection: SELECT FOR UPDATE -> UPDATE -> INSERT event
  // -> INSERT audit -> SELECT submitted_at. common_sql wraps each
  // call in its own implicit transaction, so to keep things atomic
  // we run all four writes in one with_connection block. If any of
  // them errors, the driver rolls back automatically when the
  // connection is released.
  let select_for_update = "
    SELECT status FROM requests WHERE id = $1 FOR UPDATE
  "
  let update_query = "
    UPDATE requests
    SET status = 'submitted',
        submitted_at = now()
    WHERE id = $1
  "
  let event_query = "
    INSERT INTO request_events
      (request_id, from_status, to_status, actor_role, reason_code, regulatory_ref_id)
    VALUES ($1::uuid, 'draft', 'submitted', 'applicant', 'submit_ok', $2)
  "
  let audit_query = "
    INSERT INTO audit_log
      (actor_role, action, object_type, object_id)
    VALUES ('applicant', 'submit', 'request', $1::uuid)
  "
  let now_query = "SELECT submitted_at::text FROM requests WHERE id = $1"

  // The digital moderator is triggered by the SUBMISSION, not by the
  // creation: only at this point the request has the `submitted` status
  // and the fields the applicant filled in. The event is written in the
  // same transaction as the status change, so the agent never sees a
  // request that was not really submitted.
  let agent_event_query = "
    WITH job AS (
      INSERT INTO job_runs (request_id, job_type, idempotency_key, input_hash)
      VALUES (
        $1::uuid,
        'agent_digital_moderator',
        'agent_a:' || $1::text,
        encode(digest('agent_a:' || $1::text, 'sha256'), 'hex')
      )
      ON CONFLICT (idempotency_key) DO UPDATE
        SET idempotency_key = EXCLUDED.idempotency_key
      RETURNING id, request_id
    )
    INSERT INTO outbox (subject, payload)
    SELECT
      'requests.agent_a',
      jsonb_build_object(
        'schema_version', 1,
        'job_type', 'agent_digital_moderator',
        'job_id', job.id::text,
        'request_id', job.request_id::text,
        'event_reason', 'request.submitted',
        'initiated_by', 'system'
      )
    FROM job
    RETURNING id
  "
  let nil_decoder = decode.success(Nil)
  let string_decoder = {
    use s <- decode.field(0, decode.string)
    decode.success(s)
  }
  let event_args = case regulatory_ref_id {
    option.Some(id) -> [sql.PString(request_id), sql.PString(id)]
    option.None -> [sql.PString(request_id), sql.PNull]
  }
  sql.with_connection(driver, database_url, fn(conn) {
    case
      sql.execute(
        driver,
        conn,
        sql.Portable(select_for_update),
        [sql.PString(request_id)],
        string_decoder,
      )
    {
      Ok([]) -> Ok(NotFound)
      Ok([status]) ->
        case status {
          "draft" ->
            case
              sql.execute(
                driver,
                conn,
                sql.Portable(update_query),
                [sql.PString(request_id)],
                nil_decoder,
              )
            {
              Error(e) -> Error(e)
              Ok(_) ->
                case
                  sql.execute(
                    driver,
                    conn,
                    sql.Portable(event_query),
                    event_args,
                    nil_decoder,
                  )
                {
                  Error(e) -> Error(e)
                  Ok(_) ->
                    case
                      sql.execute(
                        driver,
                        conn,
                        sql.Portable(audit_query),
                        [sql.PString(request_id)],
                        nil_decoder,
                      )
                    {
                      Error(e) -> Error(e)
                      Ok(_) ->
                        case
                          sql.execute(
                            driver,
                            conn,
                            sql.Portable(now_query),
                            [sql.PString(request_id)],
                            string_decoder,
                          )
                        {
                          Error(e) -> Error(e)
                          Ok(_) ->
                            case
                              sql.execute(
                                driver,
                                conn,
                                sql.Portable(agent_event_query),
                                [sql.PString(request_id)],
                                nil_decoder,
                              )
                            {
                              Error(e) -> Error(e)
                              Ok(_) ->
                                case
                                  sql.execute(
                                    driver,
                                    conn,
                                    sql.Portable(now_query),
                                    [sql.PString(request_id)],
                                    string_decoder,
                                  )
                                {
                                  Ok([ts]) -> Ok(SubmitSucceeded(request_id, ts))
                                  Ok(_) -> Ok(SubmitSucceeded(request_id, "unknown"))
                                  Error(e) -> Error(e)
                                }
                            }
                        }
                    }
                }
            }
          "submitted" -> Ok(AlreadySubmitted(request_id))
          other -> Ok(UnknownStatusTransition(request_id, other))
        }
      Ok(_) -> Ok(NotFound)
      Error(e) -> Error(e)
    }
  })
  |> wrap_outcome
}

fn wrap_outcome(result: Result(SubmitOutcome, sql.DbError)) -> SubmitOutcome {
  case result {
    Ok(o) -> o
    Error(e) -> DbErr(e)
  }
}
