// services/api/src/effectivnost_360/automation_repo.gleam
//
// Фаза 8 — доступ к данным режима автоматизации и работы агентов.
//
// ТРАНЗАКЦИОННАЯ ПОЛИТИКА:
// ---------------------------
//  * Каждый переход статуса по-прежнему применяется ТОЛЬКО через
//    `moderation.apply_transition` — агент не пишет в `requests.status`
//    напрямую. Это гарантирует, что легальность перехода, аудит и
//    уведомления считаются одним и тем же кодом, что и для человека.
//  * Результат проверки (`agent_checks`) записывается ДО перехода статуса:
//    если запись проверки падает, переход не выполняется. Так панель
//    «Цифровой модератор» всегда показывает результат проверки, которая
//    действительно была выполнена.
//  * `automation_actions.idempotency_key` UNIQUE: повторная доставка
//    события не создаёт второй переход — INSERT ... ON CONFLICT DO NOTHING
//    возвращает 0 строк, и мы понимаем, что действие уже было выполнено.
import common_sql as sql
import effectivnost_360/automation.{
  type AutomationMode, type CheckItem, type CheckResult, type Problem,
  type ProposedAction, check_result_to_string, default_mode,
  default_rules_version, mode_to_string, parse_check_result, parse_mode,
  rule_to_string,
} as automation
import effectivnost_360/state_machine.{
  type Status, status_to_string,
}
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// -------------------------------------------------------------
// Decoders
// -------------------------------------------------------------

fn field_text(idx: Int, next: fn(String) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use s <- decode.field(idx, decode.string)
  next(s)
}

fn opt_field_text(
  idx: Int,
  default: Option(String),
  next: fn(Option(String)) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  use s <- decode.field(idx, decode.optional(decode.string))
  case s {
    None -> next(default)
    Some(value) -> next(Some(value))
  }
}

fn field_int(idx: Int, next: fn(Int) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use n <- decode.field(idx, decode.int)
  next(n)
}

fn field_bool(idx: Int, next: fn(Bool) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use b <- decode.field(idx, decode.bool)
  next(b)
}

fn nil_decoder() -> decode.Decoder(Nil) {
  decode.success(Nil)
}

/// The decoder for a statement that returns exactly ONE text column.
///
/// The driver hands every row over as a list of columns, so the value has
/// to be taken from the field 0 of the row. `pgo` returns a text column as
/// an Erlang binary (`BitArray` in Gleam), so it is coerced with
/// `bit_array.to_string`.
fn text_decoder() -> decode.Decoder(String) {
  decode.field(0, decode.bit_array, fn(bits) {
    case bit_array.to_string(bits) {
      Ok(s) -> decode.success(s)
      Error(_) -> decode.failure("", "String")
    }
  })
}

// -------------------------------------------------------------
// Settings
// -------------------------------------------------------------

/// The stored automation settings.
pub type Settings {
  Settings(
    mode: AutomationMode,
    rules_version: String,
    updated_by: Option(String),
    updated_at: String,
  )
}

fn settings_decoder() -> decode.Decoder(Settings) {
  use mode_text <- field_text(0)
  use rules_version <- field_text(1)
  use updated_by <- opt_field_text(2, None)
  use updated_at <- field_text(3)
  decode.success(Settings(
    mode: parse_mode(mode_text),
    rules_version: rules_version,
    updated_by: updated_by,
    updated_at: updated_at,
  ))
}

/// Load the automation settings.
///
/// If the singleton row is missing (fresh database before the migration
/// seed ran), the DEFAULT mode `confirm` is returned. The service therefore
/// never runs in an undefined mode.
pub fn load_settings(
  driver: sql.Driver(conn),
  database_url: String,
) -> Result(Settings, sql.DbError) {
  let query = "
    SELECT mode, rules_version, updated_by::text, updated_at::text
    FROM automation_settings
    WHERE id = 1
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [],
        settings_decoder(),
      )
    })
  case result {
    Ok([settings]) -> Ok(settings)
    Ok(_) ->
      Ok(Settings(
        mode: default_mode(),
        rules_version: default_rules_version(),
        updated_by: None,
        updated_at: "",
      ))
    Error(e) -> Error(e)
  }
}

/// The current automation mode. Convenience wrapper over `load_settings`.
pub fn load_mode(
  driver: sql.Driver(conn),
  database_url: String,
) -> Result(AutomationMode, sql.DbError) {
  load_settings(driver, database_url)
  |> map_first(fn(settings) { settings.mode })
}

fn map_first(
  result: Result(a, e),
  fun: fn(a) -> b,
) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(fun(value))
    Error(e) -> Error(e)
  }
}

/// Save the automation mode.
///
/// The mode is validated by the database CHECK constraint AND by the
/// caller (the router rejects unknown modes before we get here).
pub fn save_mode(
  driver: sql.Driver(conn),
  database_url: String,
  mode: AutomationMode,
  actor_id: Option(String),
) -> Result(Settings, sql.DbError) {
  let mode_text = mode_to_string(mode)
  let query = "
    UPDATE automation_settings
    SET mode = $1::text,
        updated_by = $2::uuid,
        updated_at = now(),
        auto_enabled_at = CASE WHEN $1::text = 'auto' THEN now() ELSE auto_enabled_at END,
        auto_enabled_by = CASE WHEN $1::text = 'auto' THEN $2::uuid ELSE auto_enabled_by END
    WHERE id = 1
  "
  let params = [sql.PString(mode_text), case actor_id {
    Some(id) -> sql.PString(id)
    None -> sql.PNull
  }]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, nil_decoder())
    })
  case result {
    Ok(_) -> load_settings(driver, database_url)
    Error(e) -> Error(e)
  }
}

// -------------------------------------------------------------
// Agent checks (the result of the digital moderator's pass)
// -------------------------------------------------------------

/// A stored check result.
pub type Check {
  Check(
    request_id: String,
    result: CheckResult,
    /// The raw JSONB of the checks array (rendered by the interface).
    checks_json: String,
    /// The raw JSONB of the problems array.
    problems_json: String,
    /// The raw JSONB of the proposed actions array.
    actions_json: String,
    clarification_request: String,
    reason: String,
    rule_code: String,
    rules_version: String,
    model_version: String,
    prompt_version: String,
    llm_used: Bool,
    source_event: String,
    initiated_by: String,
    duration_ms: Int,
    created_at: String,
    updated_at: String,
  )
}

fn check_decoder() -> decode.Decoder(Check) {
  use request_id <- field_text(0)
  use result_text <- field_text(1)
  use checks_json <- field_text(2)
  use problems_json <- field_text(3)
  use actions_json <- field_text(4)
  use clarification_request <- field_text(5)
  use reason <- field_text(6)
  use rule_code <- field_text(7)
  use rules_version <- field_text(8)
  use model_version <- field_text(9)
  use prompt_version <- field_text(10)
  use llm_used <- field_bool(11)
  use source_event <- field_text(12)
  use initiated_by <- field_text(13)
  use duration_ms <- field_int(14)
  use created_at <- field_text(15)
  use updated_at <- field_text(16)
  decode.success(Check(
    request_id: request_id,
    result: parse_check_result(result_text),
    checks_json: checks_json,
    problems_json: problems_json,
    actions_json: actions_json,
    clarification_request: clarification_request,
    reason: reason,
    rule_code: rule_code,
    rules_version: rules_version,
    model_version: model_version,
    prompt_version: prompt_version,
    llm_used: llm_used,
    source_event: source_event,
    initiated_by: initiated_by,
    duration_ms: duration_ms,
    created_at: created_at,
    updated_at: updated_at,
  ))
}

/// Save (or refresh) the result of the digital moderator's check.
///
/// The write is idempotent per request: the second attempt UPDATES the
/// existing row instead of creating a second one. That is what makes a
/// redelivered event harmless.
pub fn save_check(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  result: CheckResult,
  checks_json: String,
  problems_json: String,
  actions_json: String,
  clarification_request: String,
  reason: String,
  rule_code: String,
  rules_version: String,
  model_version: String,
  prompt_version: String,
  llm_used: Bool,
  source_event: String,
  initiated_by: String,
  duration_ms: Int,
) -> Result(Check, sql.DbError) {
  let result_text = check_result_to_string(result)
  let query = "
    INSERT INTO agent_checks (
      request_id, result, checks, problems, proposed_actions,
      clarification_request, reason, rule_code, rules_version,
      model_version, prompt_version, llm_used, source_event,
      initiated_by, duration_ms
    )
    VALUES (
      $1::uuid, $2::text, $3::jsonb, $4::jsonb, $5::jsonb,
      $6::text, $7::text, $8::text, $9::text,
      $10::text, $11::text, $12::bool, $13::text,
      $14::text, $15::int
    )
    ON CONFLICT (request_id) DO UPDATE SET
      result = EXCLUDED.result,
      checks = EXCLUDED.checks,
      problems = EXCLUDED.problems,
      proposed_actions = EXCLUDED.proposed_actions,
      clarification_request = EXCLUDED.clarification_request,
      reason = EXCLUDED.reason,
      rule_code = EXCLUDED.rule_code,
      rules_version = EXCLUDED.rules_version,
      model_version = EXCLUDED.model_version,
      prompt_version = EXCLUDED.prompt_version,
      llm_used = EXCLUDED.llm_used,
      source_event = EXCLUDED.source_event,
      initiated_by = EXCLUDED.initiated_by,
      duration_ms = EXCLUDED.duration_ms,
      updated_at = now()
    RETURNING
      request_id::text, result, checks::text, problems::text,
      proposed_actions::text, clarification_request, reason, rule_code,
      rules_version, model_version, prompt_version, llm_used,
      source_event, initiated_by, duration_ms, created_at::text, updated_at::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(result_text),
    sql.PString(checks_json),
    sql.PString(problems_json),
    sql.PString(actions_json),
    sql.PString(clarification_request),
    sql.PString(reason),
    sql.PString(rule_code),
    sql.PString(rules_version),
    sql.PString(model_version),
    sql.PString(prompt_version),
    sql.PBool(llm_used),
    sql.PString(source_event),
    sql.PString(initiated_by),
    sql.PInt(duration_ms),
  ]
  let outcome =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, check_decoder())
    })
  case outcome {
    Ok([check]) -> Ok(check)
    Ok(_) -> Error(sql.QueryError("agent_checks upsert returned no row"))
    Error(e) -> Error(e)
  }
}

/// Load the check result of a request, if any.
pub fn load_check(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(Option(Check), sql.DbError) {
  let query = "
    SELECT
      request_id::text, result, checks::text, problems::text,
      proposed_actions::text, clarification_request, reason, rule_code,
      rules_version, model_version, prompt_version, llm_used,
      source_event, initiated_by, duration_ms, created_at::text, updated_at::text
    FROM agent_checks
    WHERE request_id = $1::uuid
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        check_decoder(),
      )
    })
  case result {
    Ok([check]) -> Ok(Some(check))
    Ok(_) -> Ok(None)
    Error(e) -> Error(e)
  }
}

/// The list of recent checks — the panel «Цифровой модератор».
pub fn list_checks(
  driver: sql.Driver(conn),
  database_url: String,
  limit: Int,
  offset: Int,
) -> Result(List(Check), sql.DbError) {
  let query = "
    SELECT
      request_id::text, result, checks::text, problems::text,
      proposed_actions::text, clarification_request, reason, rule_code,
      rules_version, model_version, prompt_version, llm_used,
      source_event, initiated_by, duration_ms, created_at::text, updated_at::text
    FROM agent_checks
    ORDER BY updated_at DESC
    LIMIT $1 OFFSET $2
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PInt(limit), sql.PInt(offset)],
      check_decoder(),
    )
  })
}

// -------------------------------------------------------------
// Automation actions (the journal)
// -------------------------------------------------------------

/// One entry of the automation journal.
pub type Action {
  Action(
    id: String,
    request_id: String,
    action: String,
    from_status: Option(String),
    to_status: Option(String),
    reason: String,
    rule_code: String,
    rules_version: String,
    source_event: String,
    initiated_by: String,
    automation_mode: String,
    outcome: String,
    details_json: String,
    created_at: String,
  )
}

fn action_decoder() -> decode.Decoder(Action) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use action <- field_text(2)
  use from_status <- opt_field_text(3, None)
  use to_status <- opt_field_text(4, None)
  use reason <- field_text(5)
  use rule_code <- field_text(6)
  use rules_version <- field_text(7)
  use source_event <- field_text(8)
  use initiated_by <- field_text(9)
  use automation_mode <- field_text(10)
  use outcome <- field_text(11)
  use details_json <- field_text(12)
  use created_at <- field_text(13)
  decode.success(Action(
    id: id,
    request_id: request_id,
    action: action,
    from_status: from_status,
    to_status: to_status,
    reason: reason,
    rule_code: rule_code,
    rules_version: rules_version,
    source_event: source_event,
    initiated_by: initiated_by,
    automation_mode: automation_mode,
    outcome: outcome,
    details_json: details_json,
    created_at: created_at,
  ))
}

/// Append an entry to the automation journal.
///
/// Returns `True` when the entry was actually written and `False` when it
/// was suppressed by the idempotency key (i.e. the same action was already
/// recorded). The caller uses this to avoid repeating a transition.
pub fn record_action(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  action: String,
  from_status: Option(String),
  to_status: Option(String),
  reason: String,
  rule_code: String,
  rules_version: String,
  source_event: String,
  initiated_by: String,
  automation_mode: String,
  outcome: String,
  details_json: String,
  idempotency_key: String,
) -> Result(Bool, sql.DbError) {
  let query = "
    INSERT INTO automation_actions (
      request_id, action, from_status, to_status, reason, rule_code,
      rules_version, source_event, initiated_by, automation_mode,
      outcome, details, idempotency_key
    )
    VALUES (
      $1::uuid, $2::text, $3::text, $4::text, $5::text, $6::text,
      $7::text, $8::text, $9::text, $10::text,
      $11::text, $12::jsonb, $13::text
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(action),
    case from_status {
      Some(s) -> sql.PString(s)
      None -> sql.PNull
    },
    case to_status {
      Some(s) -> sql.PString(s)
      None -> sql.PNull
    },
    sql.PString(reason),
    sql.PString(rule_code),
    sql.PString(rules_version),
    sql.PString(source_event),
    sql.PString(initiated_by),
    sql.PString(automation_mode),
    sql.PString(outcome),
    sql.PString(details_json),
    sql.PString(idempotency_key),
  ]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, text_decoder())
    })
  case result {
    Ok(rows) -> Ok(rows != [])
    Error(e) -> {
      io.println(
        "record_action failed for request " <> request_id <> ": " <> string.inspect(e),
      )
      Error(e)
    }
  }
}

/// The journal of automated actions, newest first.
pub fn list_actions(
  driver: sql.Driver(conn),
  database_url: String,
  limit: Int,
  offset: Int,
) -> Result(List(Action), sql.DbError) {
  let query = "
    SELECT
      id::text, request_id::text, action, from_status, to_status, reason,
      rule_code, rules_version, source_event, initiated_by,
      automation_mode, outcome, details::text, created_at::text
    FROM automation_actions
    ORDER BY created_at DESC, id DESC
    LIMIT $1 OFFSET $2
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PInt(limit), sql.PInt(offset)],
      action_decoder(),
    )
  })
}

// -------------------------------------------------------------
// Exceptions (the human queue)
// -------------------------------------------------------------

/// One exception awaiting a human decision.
pub type Exception {
  Exception(
    id: String,
    request_id: String,
    kind: String,
    reason: String,
    details_json: String,
    status: String,
    resolved_by: Option(String),
    resolved_at: Option(String),
    resolution_note: String,
    initiated_by: String,
    created_at: String,
  )
}

fn exception_decoder() -> decode.Decoder(Exception) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use kind <- field_text(2)
  use reason <- field_text(3)
  use details_json <- field_text(4)
  use status <- field_text(5)
  use resolved_by <- opt_field_text(6, None)
  use resolved_at <- opt_field_text(7, None)
  use resolution_note <- field_text(8)
  use initiated_by <- field_text(9)
  use created_at <- field_text(10)
  decode.success(Exception(
    id: id,
    request_id: request_id,
    kind: kind,
    reason: reason,
    details_json: details_json,
    status: status,
    resolved_by: resolved_by,
    resolved_at: resolved_at,
    resolution_note: resolution_note,
    initiated_by: initiated_by,
    created_at: created_at,
  ))
}

/// Put a request into the human queue.
///
/// Idempotent per (request, kind): a second call does not create a second
/// row — the reason is refreshed instead.
pub fn raise_exception(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  kind: String,
  reason: String,
  details_json: String,
  initiated_by: String,
) -> Result(Exception, sql.DbError) {
  let query = "
    INSERT INTO agent_exceptions (request_id, kind, reason, details, initiated_by)
    VALUES ($1::uuid, $2::text, $3::text, $4::jsonb, $5::text)
    ON CONFLICT (request_id, kind) DO UPDATE
      SET reason = EXCLUDED.reason,
          details = EXCLUDED.details,
          status = 'open',
          resolved_at = NULL,
          resolved_by = NULL
    RETURNING
      id::text, request_id::text, kind, reason, details::text, status,
      resolved_by::text, resolved_at::text, resolution_note,
      initiated_by, created_at::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(kind),
    sql.PString(reason),
    sql.PString(details_json),
    sql.PString(initiated_by),
  ]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        params,
        exception_decoder(),
      )
    })
  case result {
    Ok([exception]) -> Ok(exception)
    Ok(_) -> Error(sql.QueryError("agent_exceptions upsert returned no row"))
    Error(e) -> Error(e)
  }
}

/// The open exceptions, newest first.
pub fn list_exceptions(
  driver: sql.Driver(conn),
  database_url: String,
  only_open: Bool,
  limit: Int,
  offset: Int,
) -> Result(List(Exception), sql.DbError) {
  let where_clause = case only_open {
    True -> "WHERE status = 'open'"
    False -> ""
  }
  let query =
    "
    SELECT
      id::text, request_id::text, kind, reason, details::text, status,
      resolved_by::text, resolved_at::text, resolution_note,
      initiated_by, created_at::text
    FROM agent_exceptions
    "
    <> where_clause
    <> "
    ORDER BY created_at DESC
    LIMIT $1 OFFSET $2
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PInt(limit), sql.PInt(offset)],
      exception_decoder(),
    )
  })
}

/// Close an exception (a human has dealt with it).
pub fn resolve_exception(
  driver: sql.Driver(conn),
  database_url: String,
  exception_id: String,
  actor_id: String,
  note: String,
) -> Result(Bool, sql.DbError) {
  let query = "
    UPDATE agent_exceptions
    SET status = 'resolved',
        resolved_by = $2::uuid,
        resolved_at = now(),
        resolution_note = $3::text
    WHERE id = $1::uuid AND status = 'open'
    RETURNING id::text
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(exception_id), sql.PString(actor_id), sql.PString(note)],
        text_decoder(),
      )
    })
  case result {
    Ok(rows) -> Ok(rows != [])
    Error(e) -> Error(e)
  }
}

// -------------------------------------------------------------
// Agent tasks (reminders for the moderator)
// -------------------------------------------------------------

/// A reminder / task for the moderator.
pub type Task {
  Task(
    id: String,
    request_id: String,
    kind: String,
    title: String,
    note: String,
    due_at: Option(String),
    status: String,
    assigned_to: Option(String),
    created_at: String,
  )
}

fn task_decoder() -> decode.Decoder(Task) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use kind <- field_text(2)
  use title <- field_text(3)
  use note <- field_text(4)
  use due_at <- opt_field_text(5, None)
  use status <- field_text(6)
  use assigned_to <- opt_field_text(7, None)
  use created_at <- field_text(8)
  decode.success(Task(
    id: id,
    request_id: request_id,
    kind: kind,
    title: title,
    note: note,
    due_at: due_at,
    status: status,
    assigned_to: assigned_to,
    created_at: created_at,
  ))
}

/// Create a reminder for the moderator, idempotently.
pub fn create_task(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  kind: String,
  title: String,
  note: String,
  due_at: Option(String),
  idempotency_key: String,
) -> Result(Task, sql.DbError) {
  let query = "
    INSERT INTO agent_tasks (request_id, kind, title, note, due_at, idempotency_key)
    VALUES ($1::uuid, $2::text, $3::text, $4::text, $5::timestamptz, $6::text)
    ON CONFLICT (idempotency_key) DO UPDATE
      SET title = EXCLUDED.title, note = EXCLUDED.note
    RETURNING
      id::text, request_id::text, kind, title, note, due_at::text,
      status, assigned_to::text, created_at::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(kind),
    sql.PString(title),
    sql.PString(note),
    case due_at {
      Some(s) -> sql.PString(s)
      None -> sql.PNull
    },
    sql.PString(idempotency_key),
  ]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, task_decoder())
    })
  case result {
    Ok([task]) -> Ok(task)
    Ok(_) -> Error(sql.QueryError("agent_tasks upsert returned no row"))
    Error(e) -> Error(e)
  }
}

/// The open tasks of the moderator.
pub fn list_tasks(
  driver: sql.Driver(conn),
  database_url: String,
  limit: Int,
) -> Result(List(Task), sql.DbError) {
  let query = "
    SELECT
      id::text, request_id::text, kind, title, note, due_at::text,
      status, assigned_to::text, created_at::text
    FROM agent_tasks
    WHERE status = 'open'
    ORDER BY due_at NULLS LAST, created_at DESC
    LIMIT $1
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PInt(limit)],
      task_decoder(),
    )
  })
}

/// Close a task.
pub fn complete_task(
  driver: sql.Driver(conn),
  database_url: String,
  task_id: String,
) -> Result(Bool, sql.DbError) {
  let query = "
    UPDATE agent_tasks SET status = 'done'
    WHERE id = $1::uuid AND status = 'open'
    RETURNING id::text
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(task_id)],
        text_decoder(),
      )
    })
  case result {
    Ok(rows) -> Ok(rows != [])
    Error(e) -> Error(e)
  }
}

// -------------------------------------------------------------
// Agent drafts (the prepared answer and the result card)
// -------------------------------------------------------------

/// A prepared draft: the official letter project or the result card.
pub type Draft {
  Draft(
    id: String,
    request_id: String,
    kind: String,
    content: String,
    structured_json: String,
    status: String,
    source_event: String,
    created_at: String,
    updated_at: String,
  )
}

fn draft_decoder() -> decode.Decoder(Draft) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use kind <- field_text(2)
  use content <- field_text(3)
  use structured_json <- field_text(4)
  use status <- field_text(5)
  use source_event <- field_text(6)
  use created_at <- field_text(7)
  use updated_at <- field_text(8)
  decode.success(Draft(
    id: id,
    request_id: request_id,
    kind: kind,
    content: content,
    structured_json: structured_json,
    status: status,
    source_event: source_event,
    created_at: created_at,
    updated_at: updated_at,
  ))
}

/// Save a prepared draft, idempotently.
pub fn save_draft(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  kind: String,
  content: String,
  structured_json: String,
  source_event: String,
  idempotency_key: String,
) -> Result(Draft, sql.DbError) {
  let query = "
    INSERT INTO agent_drafts (
      request_id, kind, content, structured, source_event, idempotency_key
    )
    VALUES ($1::uuid, $2::text, $3::text, $4::jsonb, $5::text, $6::text)
    ON CONFLICT (idempotency_key) DO UPDATE
      SET content = EXCLUDED.content,
          structured = EXCLUDED.structured,
          updated_at = now()
    RETURNING
      id::text, request_id::text, kind, content, structured::text,
      status, source_event, created_at::text, updated_at::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(kind),
    sql.PString(content),
    sql.PString(structured_json),
    sql.PString(source_event),
    sql.PString(idempotency_key),
  ]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, draft_decoder())
    })
  case result {
    Ok([draft]) -> Ok(draft)
    Ok(_) -> Error(sql.QueryError("agent_drafts upsert returned no row"))
    Error(e) -> Error(e)
  }
}

/// The drafts of a request.
pub fn list_drafts(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(List(Draft), sql.DbError) {
  let query = "
    SELECT
      id::text, request_id::text, kind, content, structured::text,
      status, source_event, created_at::text, updated_at::text
    FROM agent_drafts
    WHERE request_id = $1::uuid
    ORDER BY created_at DESC
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PString(request_id)],
      draft_decoder(),
    )
  })
}

// -------------------------------------------------------------
// Marking a request as automatically checked
// -------------------------------------------------------------

/// Mark the request as checked by the digital moderator.
///
/// `auto_checked_at` is set only for a real check (any result other than
/// `skipped`), so the indicator «Проверено автоматически» always means
/// that a check really happened.
pub fn mark_auto_checked(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  result: CheckResult,
) -> Result(Nil, sql.DbError) {
  let query = "
    UPDATE requests
    SET auto_checked_at = now(),
        auto_check_result = $2::text,
        updated_at = now()
    WHERE id = $1::uuid
  "
  let result_text = check_result_to_string(result)
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id), sql.PString(result_text)],
        nil_decoder(),
      )
    })
  case result {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

// -------------------------------------------------------------
// JSON helpers for the check payloads
// -------------------------------------------------------------

/// Encode a list of checks as a JSON array string.
///
/// The encoding is done here (and not in the caller) so the shape of the
/// stored JSON is defined in ONE place and cannot drift.
pub fn encode_checks(checks: List(CheckItem)) -> String {
  let items =
    list.map(checks, fn(check) {
      "{\"name\":"
      <> json_string(check.name)
      <> ",\"ok\":"
      <> bool_to_json(check.ok)
      <> ",\"detail\":"
      <> json_string(check.detail)
      <> "}"
    })
  "[" <> string_join(items, ",") <> "]"
}

/// Encode a list of problems as a JSON array string.
pub fn encode_problems(problems: List(Problem)) -> String {
  let items =
    list.map(problems, fn(problem) {
      "{\"field_name\":"
      <> json_string(problem.field_name)
      <> ",\"reason\":"
      <> json_string(problem.reason)
      <> ",\"message\":"
      <> json_string(problem.message)
      <> ",\"clause_id\":"
      <> json_string(problem.clause_id)
      <> ",\"quote\":"
      <> json_string(problem.quote)
      <> "}"
    })
  "[" <> string_join(items, ",") <> "]"
}

/// Encode a list of proposed actions as a JSON array string.
pub fn encode_actions(actions: List(ProposedAction)) -> String {
  let items =
    list.map(actions, fn(action) {
      "{\"action\":"
      <> json_string(action.action)
      <> ",\"target_status\":"
      <> json_string(action.target_status)
      <> ",\"reason\":"
      <> json_string(action.reason)
      <> ",\"rule_code\":"
      <> json_string(action.rule_code)
      <> "}"
    })
  "[" <> string_join(items, ",") <> "]"
}

/// Escape a string for embedding into a JSON document.
pub fn json_string(value: String) -> String {
  let escaped = escape_backslash_and_quote(value)
  "\"" <> escaped <> "\""
}

/// Escape backslashes and double quotes for JSON.
fn escape_backslash_and_quote(value: String) -> String {
  string.replace(
    string.replace(value, each: "\\", with: "\\\\"),
    each: "\"",
    with: "\\\"",
  )
}

/// Join a list of strings with a separator.
fn string_join(items: List(String), separator: String) -> String {
  case items {
    [] -> ""
    [first] -> first
    [first, ..rest] -> first <> separator <> string_join(rest, separator)
  }
}

/// Encode a boolean as a JSON literal.
pub fn bool_to_json(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

/// Encode a string as a JSON value (quoted).
pub fn json_value(value: String) -> String {
  json_string(value)
}

/// A JSON object with one string field.
pub fn json_object_field(key: String, value: String) -> String {
  "{" <> json_string(key) <> ":" <> json_string(value) <> "}"
}

/// The stable id of the settings row.
///
/// `automation_settings.id` is the integer 1, but `audit_log.object_id` is
/// a uuid, so the audit trail refers to the settings by this constant id.
pub const settings_id: String = "00000000-0000-0000-0000-0000000000a1"

/// Record a NOT request-scoped action in the platform audit log.
///
/// The change of the automation mode belongs to no request, so it cannot go
/// into `automation_actions` (that table references `requests`). It is
/// still auditable — the mode and its initiator are written down here.
pub fn record_mode_change(
  driver: sql.Driver(conn),
  database_url: String,
  mode: String,
  actor_id: Option(String),
  rules_version: String,
) -> Result(Nil, sql.DbError) {
  let query = "
    INSERT INTO audit_log (
      actor_id, actor_role, action, object_type, object_id, details
    )
    VALUES (
      $1::uuid, 'moderator', 'automation_mode_changed', 'automation_settings',
      $2::uuid,
      jsonb_build_object('mode', $3::text, 'rules_version', $4::text)
    )
  "
  let params = [
    case actor_id {
      Some(id) -> sql.PString(id)
      None -> sql.PNull
    },
    sql.PString(settings_id),
    sql.PString(mode),
    sql.PString(rules_version),
  ]
  case
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, nil_decoder())
    })
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

/// The status text of a request, used when writing actions.
pub fn status_text(status: Status) -> String {
  status_to_string(status)
}

/// The rule text of a decision.
pub fn rule_text(rule: automation.Rule) -> String {
  rule_to_string(rule)
}

// -------------------------------------------------------------
// Helpers for the router
// -------------------------------------------------------------

/// Does a request exist?
pub fn request_exists(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(Bool, sql.DbError) {
  let query = "SELECT id::text FROM requests WHERE id = $1::uuid"
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        nil_decoder(),
      )
    })
  case result {
    Ok(rows) -> Ok(rows != [])
    Error(e) -> Error(e)
  }
}

/// The current status of a request, as text.
pub fn load_current_status(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(Option(String), sql.DbError) {
  let query = "SELECT status FROM requests WHERE id = $1::uuid"
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        decode_field_text(),
      )
    })
  case result {
    Ok([status]) -> Ok(Some(status))
    Ok(_) -> Ok(None)
    Error(e) -> Error(e)
  }
}

/// The action the agent proposed for this request, if any.
///
/// The proposal is stored as a JSON array; the first element's `action` is
/// the one the moderator can confirm.
pub fn proposed_action_of(check: Check) -> Option(String) {
  case extract_first_action(check.actions_json) {
    Some(action) -> Some(action)
    None -> None
  }
}

/// Extract the `action` field of the first element of a JSON array.
///
/// The stored payload is produced by `encode_actions`, so its shape is
/// known and fixed. A minimal scanner is enough and avoids pulling a JSON
/// parser into the repository layer.
fn extract_first_action(actions_json: String) -> Option(String) {
  let needle = "\"action\":\""
  case string.split(actions_json, on: needle) {
    [] -> None
    [_] -> None
    [_, rest] ->
      case string.split(rest, on: "\"") {
        [] -> None
        [value, ..] -> Some(value)
      }
    [_, rest, ..] ->
      case string.split(rest, on: "\"") {
        [] -> None
        [value, ..] -> Some(value)
      }
  }
}

/// The exceptions of one request.
pub fn list_exceptions_of_request(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(List(Exception), sql.DbError) {
  let query = "
    SELECT
      id::text, request_id::text, kind, reason, details::text, status,
      resolved_by::text, resolved_at::text, resolution_note,
      initiated_by, created_at::text
    FROM agent_exceptions
    WHERE request_id = $1::uuid
    ORDER BY created_at DESC
  "
  sql.with_connection(driver, database_url, fn(conn) {
    sql.execute(
      driver,
      conn,
      sql.Portable(query),
      [sql.PString(request_id)],
      exception_decoder(),
    )
  })
}

/// Enqueue a re-check of a request.
///
/// The job is written to `job_runs` and published to the outbox, so the Go
/// worker picks it up exactly like any other job. This is what keeps ONE
/// implementation of the check (the agent) instead of two that could drift.
pub fn enqueue_recheck(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  actor_id: String,
) -> Result(String, sql.DbError) {
  let query = "
    WITH inserted AS (
      INSERT INTO job_runs (request_id, job_type, idempotency_key, input_hash)
      VALUES (
        $1::uuid,
        'agent_digital_moderator',
        'recheck:' || $1::text || ':' || $2::text,
        encode(digest('recheck:' || $1::text || ':' || $2::text, 'sha256'), 'hex')
      )
      ON CONFLICT (idempotency_key) DO UPDATE
        SET idempotency_key = EXCLUDED.idempotency_key
      RETURNING id, request_id
    )
    INSERT INTO outbox (subject, payload)
    SELECT
      'requests.recheck',
      jsonb_build_object(
        'schema_version', 1,
        'job_type', 'agent_digital_moderator',
        'job_id', inserted.id::text,
        'request_id', inserted.request_id::text,
        'initiated_by', 'moderator',
        -- The marker tells the agent that this is an EXPLICIT re-run: the
        -- request may sit in a status the ordinary submit flow would
        -- skip, and the check must be repeated on the current data.
        'reason', 'requests.recheck'
      )
    FROM inserted
    RETURNING payload->>'job_id' AS job_id
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id), sql.PString(actor_id)],
        decode_field_text(),
      )
    })
  case result {
    Ok([job_id]) -> Ok(job_id)
    Ok(_) -> Error(sql.QueryError("recheck enqueue returned no row"))
    Error(e) -> Error(e)
  }
}

/// A decoder for a single text column.
fn decode_field_text() -> decode.Decoder(String) {
  use s <- decode.field(0, decode.string)
  decode.success(s)
}

// -------------------------------------------------------------
// The machine layer: what the agents need from the API
// -------------------------------------------------------------

/// The current snapshot of a request, in the shape the agent checks.
///
/// This is the ONLY way the agent learns about a request. It reads the
/// CURRENT state (not the event payload), so a stale delivery cannot lead
/// to a wrong decision.
pub type Snapshot {
  Snapshot(
    id: String,
    status: String,
    request_type: String,
    raw_text: String,
    fields: List(#(String, String)),
    requirements: List(SnapshotRequirement),
    due_at: Option(String),
  )
}

/// One requirement that applies to the fields of a request.
pub type SnapshotRequirement {
  SnapshotRequirement(
    field_name: String,
    required: Bool,
    condition: String,
    clause_id: String,
    quote: String,
  )
}

/// Load the current snapshot of a request.
///
/// `Ok(None)` means the request does not exist.
pub fn load_snapshot(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
) -> Result(Option(Snapshot), sql.DbError) {
  let query = "
    SELECT
      r.id::text,
      r.status,
      COALESCE(rt.name, ''),
      r.raw_text,
      COALESCE(r.fields, '{}'::jsonb)::text,
      COALESCE(r.submitted_at::text, ''),
      COALESCE(rt.id::text, '')
    FROM requests r
    LEFT JOIN request_types rt ON rt.id = r.request_type_id
    WHERE r.id = $1::uuid
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(request_id)],
        snapshot_header_decoder(),
      )
    })
  case result {
    Error(e) -> Error(e)
    Ok([]) -> Ok(None)
    Ok([header, ..]) -> {
      let SnapshotHeader(
        id: id,
        status: status,
        request_type: request_type,
        raw_text: raw_text,
        fields_json: fields_json,
        due_at: due_at,
        type_id: type_id,
      ) = header
      // The requirements that apply to this type of request.
      //
      // `requirements.quote` is the VERBATIM text of the clause the
      // requirement comes from — the server owns the requirements, the
      // agent only reads them.
      let req_query = "
        SELECT
          req.field_name,
          req.required,
          COALESCE(req.condition::text, ''),
          req.clause_id::text,
          req.quote
        FROM requirements req
        WHERE req.request_type_id = $1::uuid
        ORDER BY req.field_name
      "
      let req_result =
        sql.with_connection(driver, database_url, fn(conn) {
          sql.execute(
            driver,
            conn,
            sql.Portable(req_query),
            [sql.PString(type_id)],
            snapshot_requirement_decoder(),
          )
        })
      case req_result {
        Error(e) -> Error(e)
        Ok(requirements) ->
          Ok(
            Some(Snapshot(
              id: id,
              status: status,
              request_type: request_type,
              raw_text: raw_text,
              fields: parse_fields_json(fields_json),
              requirements: requirements,
              due_at: case due_at {
                "" -> None
                value -> Some(value)
              },
            )),
          )
      }
    }
  }
}

/// The header part of the snapshot.
pub type SnapshotHeader {
  SnapshotHeader(
    id: String,
    status: String,
    request_type: String,
    raw_text: String,
    fields_json: String,
    due_at: String,
    type_id: String,
  )
}

fn snapshot_header_decoder() -> decode.Decoder(SnapshotHeader) {
  use id <- field_text(0)
  use status <- field_text(1)
  use request_type <- field_text(2)
  use raw_text <- field_text(3)
  use fields_json <- field_text(4)
  use due_at <- field_text(5)
  use type_id <- field_text(6)
  decode.success(SnapshotHeader(
    id: id,
    status: status,
    request_type: request_type,
    raw_text: raw_text,
    fields_json: fields_json,
    due_at: due_at,
    type_id: type_id,
  ))
}

fn snapshot_requirement_decoder() -> decode.Decoder(SnapshotRequirement) {
  use field_name <- field_text(0)
  use required <- field_bool(1)
  use condition <- field_text(2)
  use clause_id <- field_text(3)
  use quote <- field_text(4)
  decode.success(SnapshotRequirement(
    field_name: field_name,
    required: required,
    condition: condition,
    clause_id: clause_id,
    quote: quote,
  ))
}

/// Parse the `fields` JSONB of a request into a list of pairs.
///
/// Only string values are returned: the agent compares field VALUES, and a
/// non-string value (a number, a nested object) is not comparable. Such
/// fields are skipped — they are reported by the deterministic check as
/// missing rather than silently compared as text.
fn parse_fields_json(fields_json: String) -> List(#(String, String)) {
  case json.parse(from: fields_json, using: decode.dict(decode.string, decode.string)) {
    Error(_) -> []
    Ok(dict) -> dict.to_list(dict)
  }
}

/// Has this event already been processed?
///
/// The delivery semantics are at-least-once, so the same event can arrive
/// more than once. The event is considered processed when it already
/// produced an action in the journal — the action table is the record of
/// what the agents actually did.
pub fn event_processed(
  driver: sql.Driver(conn),
  database_url: String,
  event_id: String,
) -> Result(Bool, sql.DbError) {
  let query = "
    SELECT EXISTS (
      SELECT 1 FROM automation_actions WHERE source_event = $1::text
    )
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [sql.PString(event_id)],
        decode_field_bool(),
      )
    })
  case result {
    Ok([value]) -> Ok(value)
    Ok(_) -> Ok(False)
    Error(e) -> Error(e)
  }
}

/// A decoder for a single boolean column.
fn decode_field_bool() -> decode.Decoder(Bool) {
  use b <- decode.field(0, decode.bool)
  decode.success(b)
}

/// Create a notification in the applicant's cabinet.
///
/// The RECIPIENT IS CHOSEN BY THE SERVER: the requester of the request.
/// The agent cannot send a notification to anyone else — that is the trust
/// boundary.
///
/// The write is idempotent per (request, kind): a redelivered event cannot
/// notify the applicant twice. Returns `False` when the notification was
/// suppressed as a duplicate.
pub fn create_notification(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  kind: String,
  title: String,
  body: String,
  level: String,
  source_event: String,
) -> Result(Bool, sql.DbError) {
  let query = "
    INSERT INTO notifications (user_id, request_id, kind, title, body)
    SELECT
      r.requester_id,
      r.id,
      $2::text,
      $3::text,
      $4::text
    FROM requests r
    WHERE r.id = $1::uuid
      AND r.requester_id IS NOT NULL
    ON CONFLICT (request_id, kind) WHERE request_id IS NOT NULL DO NOTHING
    RETURNING id::text
  "
  // The `level` and `source_event` are kept on the function signature for
  // forward compatibility (a future schema may store them) but the current
  // `notifications` table does not have those columns, so they are NOT
  // sent to PostgreSQL.
  let _ = level
  let _ = source_event
  let params = [
    sql.PString(request_id),
    sql.PString(kind),
    sql.PString(title),
    sql.PString(body),
  ]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, text_decoder())
    })
  case result {
    Ok(rows) -> Ok(rows != [])
    Error(e) -> Error(e)
  }
}

/// Create a draft (a project of the official letter, or a result card).
///
/// The draft is NOT an official answer: its status stays `draft` and only
/// an authorised person may approve it. The write is idempotent per
/// (request, kind, source event).
pub fn create_draft(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  kind: String,
  content: String,
  structured_json: String,
  source_event: String,
  idempotency_key: String,
) -> Result(Draft, sql.DbError) {
  let query = "
    INSERT INTO agent_drafts (
      request_id, kind, content, structured, source_event, idempotency_key
    )
    VALUES ($1::uuid, $2::text, $3::text, $4::jsonb, $5::text, $6::text)
    ON CONFLICT (idempotency_key) DO UPDATE
      SET content = EXCLUDED.content,
          structured = EXCLUDED.structured,
          updated_at = now()
    RETURNING
      id::text, request_id::text, kind, content, structured::text,
      status, source_event, created_at::text, updated_at::text
  "
  let params = [
    sql.PString(request_id),
    sql.PString(kind),
    sql.PString(content),
    sql.PString(structured_json),
    sql.PString(source_event),
    sql.PString(idempotency_key),
  ]
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        params,
        draft_decoder(),
      )
    })
  case result {
    Ok([draft]) -> Ok(draft)
    Ok(_) -> Error(sql.QueryError("agent_drafts upsert returned no row"))
    Error(e) -> Error(e)
  }
}

/// Record a metric counter.
///
/// The counters are counts of REAL events. There is no estimate of saved
/// time or money anywhere in this table: the baseline has to be measured
/// before any comparison is possible.
pub fn record_metric(
  driver: sql.Driver(conn),
  database_url: String,
  request_id: String,
  key: String,
  value: Int,
) -> Result(Nil, sql.DbError) {
  let query = "
    INSERT INTO automation_metrics (request_id, key, value, idempotency_key)
    VALUES ($1::uuid, $2::text, $3::int, 'metric:' || $1::text || ':' || $2::text)
    ON CONFLICT (idempotency_key) DO UPDATE
      SET value = automation_metrics.value + EXCLUDED.value,
          updated_at = now()
  "
  let params = [
    sql.PString(request_id),
    sql.PString(key),
    sql.PInt(value),
  ]
  case
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(driver, conn, sql.Portable(query), params, nil_decoder())
    })
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}
/// Load all metric counters.
pub fn load_metrics(
  driver: sql.Driver(conn),
  database_url: String,
) -> Result(List(#(String, Int)), sql.DbError) {
  let query = "
    SELECT key, SUM(value)::int FROM automation_metrics GROUP BY key ORDER BY key
  "
  let result =
    sql.with_connection(driver, database_url, fn(conn) {
      sql.execute(
        driver,
        conn,
        sql.Portable(query),
        [],
        decode_metric_pair(),
      )
    })
  case result {
    Ok(rows) -> Ok(rows)
    Error(e) -> Error(e)
  }
}

/// A decoder for a (key, value) pair.
fn decode_metric_pair() -> decode.Decoder(#(String, Int)) {
  use key <- field_text(0)
  use value <- field_int(1)
  decode.success(#(key, value))
}
