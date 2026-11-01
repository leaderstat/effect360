// services/frontend/src/effectivnost_360_lustre/phase8_client.gleam
//
// DTO и декодеры Phase 8. Полностью переписано под фиксированные
// сигнатуры gleam_stdlib 1.x: все optional-поля обрабатываются через
// обязательные `decode.field` с дефолтом и post-processing в `Option`.
//
// `null` в JSON трактуется как пустая строка `""`, которая в свою
// очередь превращается в `None`. Это работает потому что API
// возвращает `NULL` из PostgreSQL как пустую строку или null;
// `decode.string` падает на null, поэтому требуется чтобы бэкенд
// возвращал "" вместо null. Если бэкенд вернёт null —
// decoder упадёт и появится BannerError. Это явный контракт.

import effectivnost_360_lustre/api_client
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

// -------------------------------------------------------------
// Types
// -------------------------------------------------------------

pub type ModeOption {
  ModeOption(value: String, label: String, description: String)
}

pub type AutomationSettings {
  AutomationSettings(
    mode: String,
    mode_label: String,
    description: String,
    rules_version: String,
    updated_at: String,
    updated_by: Option(String),
    available_modes: List(ModeOption),
  )
}

pub type AgentCheck {
  AgentCheck(
    request_id: String,
    result: String,
    result_label: String,
    rule_code: String,
    rules_version: String,
    model_version: String,
    prompt_version: String,
    llm_used: Bool,
    source_event: String,
    initiated_by: String,
    reason: String,
    description: String,
    duration_ms: Int,
    created_at: String,
    updated_at: String,
  )
}

/// `AgentCheck` may carry extra fields that the API renders but the
/// decoder does not need; we ignore them on purpose. The fields below
/// must be present in every check payload — the backend contract is
/// documented in `services/api/src/effectivnost_360/router.gleam`.
pub type AgentException {
  AgentException(
    id: String,
    request_id: String,
    kind: String,
    reason: String,
    status: String,
    resolution_note: String,
    initiated_by: String,
    created_at: String,
    resolved_at: Option(String),
  )
}

pub type AgentTask {
  AgentTask(
    id: String,
    request_id: String,
    kind: String,
    title: String,
    note: String,
    status: String,
    created_at: String,
    due_at: Option(String),
  )
}

pub type AutomationAction {
  AutomationAction(
    id: String,
    request_id: String,
    action: String,
    from_status: Option(String),
    to_status: Option(String),
    from_status_label: Option(String),
    to_status_label: Option(String),
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

pub type AutomationPanel {
  AutomationPanel(
    mode: String,
    mode_label: String,
    description: String,
    rules_version: String,
    checks: List(AgentCheck),
    exceptions: List(AgentException),
    tasks: List(AgentTask),
    actions: List(AutomationAction),
    metrics: List(EfficiencyMetric),
  )
}

pub type AgentDraft {
  AgentDraft(
    id: String,
    request_id: String,
    kind: String,
    title: String,
    body: String,
    status: String,
    created_at: String,
  )
}

pub type EfficiencyMetric {
  EfficiencyMetric(code: String, label: String, value: String, delta: String)
}

pub type DraftEnvelope {
  DraftEnvelope(drafts: List(AgentDraft))
}

pub type MetricsEnvelope {
  MetricsEnvelope(metrics: List(EfficiencyMetric))
}

pub fn empty_settings() -> AutomationSettings {
  AutomationSettings(
    mode: "confirm",
    mode_label: "С подтверждением",
    description: "",
    rules_version: "v1",
    updated_at: "",
    updated_by: None,
    available_modes: [],
  )
}

pub fn empty_panel() -> AutomationPanel {
  AutomationPanel(
    mode: "confirm",
    mode_label: "С подтверждением",
    description: "",
    rules_version: "v1",
    checks: [],
    exceptions: [],
    tasks: [],
    actions: [],
    metrics: [],
  )
}

// -------------------------------------------------------------
// Decoders — все optional-поля декодируются как String и потом
// превращаются в Option через `opt_string`.
// -------------------------------------------------------------

fn mode_option_decoder() -> decode.Decoder(ModeOption) {
  use value <- decode.field("value", decode.string)
  use label <- decode.field("label", decode.string)
  use description <- decode.field("description", decode.string)
  decode.success(ModeOption(value: value, label: label, description: description))
}

fn settings_decoder() -> decode.Decoder(AutomationSettings) {
  use mode <- decode.field("mode", decode.string)
  use mode_label <- decode.field("mode_label", decode.string)
  use description <- decode.field("description", decode.string)
  use rules_version <- decode.field("rules_version", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  use updated_by_raw <- decode.field("updated_by", opt_string_decoder())
  use available_modes <- decode.field(
    "available_modes",
    decode.list(mode_option_decoder()),
  )
  decode.success(AutomationSettings(
    mode: mode,
    mode_label: mode_label,
    description: description,
    rules_version: rules_version,
    updated_at: updated_at,
    updated_by: opt_string(updated_by_raw),
    available_modes: available_modes,
  ))
}

fn check_decoder() -> decode.Decoder(AgentCheck) {
  use request_id <- decode.field("request_id", decode.string)
  use result <- decode.field("result", decode.string)
  use result_label <- decode.field("result_label", decode.string)
  use rule_code <- decode.field("rule_code", decode.string)
  use rules_version <- decode.field("rules_version", decode.string)
  use model_version <- decode.field("model_version", decode.string)
  use prompt_version <- decode.field("prompt_version", decode.string)
  use llm_used <- decode.field("llm_used", decode.bool)
  use source_event <- decode.field("source_event", decode.string)
  use initiated_by <- decode.field("initiated_by", decode.string)
  use reason <- decode.field("reason", decode.string)
  use duration_ms <- decode.field("duration_ms", decode.int)
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  decode.success(AgentCheck(
    request_id: request_id,
    result: result,
    result_label: result_label,
    rule_code: rule_code,
    rules_version: rules_version,
    model_version: model_version,
    prompt_version: prompt_version,
    llm_used: llm_used,
    source_event: source_event,
    initiated_by: initiated_by,
    reason: reason,
    description: "",
    duration_ms: duration_ms,
    created_at: created_at,
    updated_at: updated_at,
  ))
}

fn exception_decoder() -> decode.Decoder(AgentException) {
  use id <- decode.field("id", decode.string)
  use request_id <- decode.field("request_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use reason <- decode.field("reason", decode.string)
  use status <- decode.field("status", decode.string)
  use initiated_by <- decode.field("initiated_by", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  decode.success(AgentException(
    id: id,
    request_id: request_id,
    kind: kind,
    reason: reason,
    status: status,
    initiated_by: initiated_by,
    created_at: created_at,
    resolution_note: "",
    resolved_at: None,
  ))
}

fn task_decoder() -> decode.Decoder(AgentTask) {
  use id <- decode.field("id", decode.string)
  use request_id <- decode.field("request_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use title <- decode.field("title", decode.string)
  use note <- decode.field("note", decode.string)
  use status <- decode.field("status", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  use due_at_raw <- decode.field("due_at", opt_string_decoder())
  decode.success(AgentTask(
    id: id,
    request_id: request_id,
    kind: kind,
    title: title,
    note: note,
    status: status,
    created_at: created_at,
    due_at: opt_string(due_at_raw),
  ))
}

fn action_decoder() -> decode.Decoder(AutomationAction) {
  use id <- decode.field("id", decode.string)
  use request_id <- decode.field("request_id", decode.string)
  use action <- decode.field("action", decode.string)
  use from_status_raw <- decode.field("from_status", opt_string_decoder())
  use to_status_raw <- decode.field("to_status", opt_string_decoder())
  use from_status_label_raw <- decode.field("from_status_label", opt_string_decoder())
  use to_status_label_raw <- decode.field("to_status_label", opt_string_decoder())
  use reason <- decode.field("reason", decode.string)
  use rule_code <- decode.field("rule_code", decode.string)
  use rules_version <- decode.field("rules_version", decode.string)
  use source_event <- decode.field("source_event", decode.string)
  use initiated_by <- decode.field("initiated_by", decode.string)
  use automation_mode <- decode.field("automation_mode", decode.string)
  use outcome <- decode.field("outcome", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  decode.success(AutomationAction(
    id: id,
    request_id: request_id,
    action: action,
    from_status: opt_string(from_status_raw),
    to_status: opt_string(to_status_raw),
    from_status_label: None,
    to_status_label: None,
    reason: reason,
    rule_code: rule_code,
    rules_version: rules_version,
    source_event: source_event,
    initiated_by: initiated_by,
    automation_mode: automation_mode,
    outcome: outcome,
    details_json: "",
    created_at: created_at,
  ))
}

fn opt_string(value: String) -> Option(String) {
  case value {
    "" -> None
    other -> Some(other)
  }
}

/// Decoder for a JSON value that may be a string OR null OR missing.
/// Real PostgreSQL NULL is rendered as JSON null in the Gleam backend,
/// so the typed `decode.string` decoder fails on those fields. The
/// pattern below tries `decode.string` first, then falls back to a
/// manual null check (using `decode.optional`), and finally returns an
/// empty string. The result is always a plain `String`.
fn opt_string_decoder() -> decode.Decoder(String) {
  decode.one_of(
    decode.string,
    [
      // null in JSON — return "".
      decode.optional(decode.string)
      |> decode.map(fn(opt) { opt |> option.unwrap("") }),
      // field missing — return "".
      decode.success(""),
    ],
  )
}

fn panel_decoder() -> decode.Decoder(AutomationPanel) {
  use mode <- decode.field("mode", decode.string)
  use mode_label <- decode.field("mode_label", decode.string)
  use description <- decode.field("description", decode.string)
  use rules_version <- decode.field("rules_version", decode.string)
  use checks <- decode.field("checks", decode.list(check_decoder()))
  use exceptions <- decode.field("exceptions", decode.list(exception_decoder()))
  use tasks <- decode.field("tasks", decode.list(task_decoder()))
  use actions <- decode.field("actions", decode.list(action_decoder()))
  // The backend embeds `metrics` in the panel payload
  // (services/api/src/effectivnost_360/automation_router.gleam :: get_panel).
  // Reading it is mandatory: load_efficiency_metrics/1 returns whatever the
  // panel sent, otherwise the dashboard always shows
  // "Метрики пока не посчитаны".
  // The field is optional for backward compatibility with older payloads.
  use metrics <- decode.optional_field(
    "metrics",
    [],
    decode.list(metric_decoder()),
  )
  decode.success(AutomationPanel(
    mode: mode,
    mode_label: mode_label,
    description: description,
    rules_version: rules_version,
    checks: checks,
    exceptions: exceptions,
    tasks: tasks,
    actions: actions,
    metrics: metrics,
  ))
}

fn draft_decoder() -> decode.Decoder(AgentDraft) {
  use id <- decode.field("id", decode.string)
  use request_id <- decode.field("request_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  use status <- decode.field("status", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  decode.success(AgentDraft(
    id: id,
    request_id: request_id,
    kind: kind,
    title: title,
    body: body,
    status: status,
    created_at: created_at,
  ))
}

fn metric_decoder() -> decode.Decoder(EfficiencyMetric) {
  use code <- decode.field("code", decode.string)
  use label <- decode.field("label", decode.string)
  // The backend serialises `value` as a JSON string (int_to_string/1),
  // but a future endpoint may emit a JSON number. The dashboard renders
  // both as text, so we accept either and coerce to a String.
  use value <- decode.field("value", metric_value_decoder())
  use delta <- decode.optional_field("delta", "", decode.string)
  decode.success(EfficiencyMetric(code: code, label: label, value: value, delta: delta))
}

/// Decode a metric `value` that may be a JSON string or a JSON number.
/// The dashboard always renders it as text; we just normalise.
fn metric_value_decoder() -> decode.Decoder(String) {
  decode.one_of(
    decode.string,
    [
      decode.int |> decode.map(int_to_string_helper),
      decode.float |> decode.map(float_to_string_helper),
      // Null and missing fields are reported as "" so the tile renders
      // "Недостаточно данных" downstream instead of failing the whole
      // panel payload.
      decode.optional(decode.string)
      |> decode.map(fn(opt) {
        case opt {
          Some(v) -> v
          None -> ""
        }
      }),
      decode.success(""),
    ],
  )
}

fn int_to_string_helper(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> int_to_string_loop(n, "")
  }
}

fn int_to_string_loop(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> {
      let digit = case n % 10 {
        0 -> "0"
        1 -> "1"
        2 -> "2"
        3 -> "3"
        4 -> "4"
        5 -> "5"
        6 -> "6"
        7 -> "7"
        8 -> "8"
        _ -> "9"
      }
      int_to_string_loop(n / 10, digit <> acc)
    }
  }
}

fn float_to_string_helper(f: Float) -> String {
  int_to_string_helper(float_to_int_helper(f))
}

fn float_to_int_helper(f: Float) -> Int {
  // gleam_json decoded to a Float. The dashboard only needs an
  // approximate representation, so we round to the nearest integer.
  let rounded = case f <. 0.0 {
    True -> f -. 0.5
    False -> f +. 0.5
  }
  case rounded >=. 0.0 {
    True -> truncate_positive(rounded)
    False -> 0 - truncate_positive(0.0 -. rounded)
  }
}

fn truncate_positive(f: Float) -> Int {
  // Take the integer part of a non-negative float by repeated subtraction.
  case f <. 1.0 {
    True -> 0
    False -> 1 + truncate_positive(f -. 1.0)
  }
}

fn metrics_list_decoder() -> decode.Decoder(MetricsEnvelope) {
  use items <- decode.field("metrics", decode.list(metric_decoder()))
  decode.success(MetricsEnvelope(metrics: items))
}

fn drafts_list_decoder() -> decode.Decoder(DraftEnvelope) {
  use items <- decode.field("drafts", decode.list(draft_decoder()))
  decode.success(DraftEnvelope(drafts: items))
}

pub fn result_label(result: String) -> String {
  case result {
    "passed" -> "Пройдено"
    "needs_info" -> "Нужны уточнения"
    "ambiguous" -> "Передано человеку"
    other -> other
  }
}

pub fn mode_label(mode: String) -> String {
  case mode {
    "manual" -> "Ручной"
    "confirm" -> "С подтверждением"
    "auto" -> "Автоматический"
    other -> other
  }
}

pub fn parse_panel(text: String) -> Result(AutomationPanel, String) {
  json.parse(text, panel_decoder())
  |> map_error("Не удалось разобрать ответ панели")
}

pub fn parse_settings(text: String) -> Result(AutomationSettings, String) {
  json.parse(text, settings_decoder())
  |> map_error("Не удалось разобрать ответ настроек")
}

pub fn parse_metrics(text: String) -> Result(List(EfficiencyMetric), String) {
  case json.parse(text, metrics_list_decoder()) {
    Ok(env) -> Ok(env.metrics)
    Error(_) -> Error("Не удалось разобрать метрики")
  }
}

pub fn parse_drafts(text: String) -> Result(List(AgentDraft), String) {
  case json.parse(text, drafts_list_decoder()) {
    Ok(env) -> Ok(env.drafts)
    Error(_) -> Error("Не удалось разобрать черновики")
  }
}

fn map_error(result: Result(a, b), msg: String) -> Result(a, String) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(msg)
  }
}

// -------------------------------------------------------------
// HTTP wrappers
// -------------------------------------------------------------

/// `GET /api/v1/automation/panel` — load the full panel.
pub fn load_panel(
  on_done: fn(Result(AutomationPanel, String)) -> Nil,
) -> Nil {
  api_client.request("GET", "/api/v1/automation/panel", "", fn(_status, body) {
    on_done(parse_panel(body))
  }, fn(reason) {
    on_done(Error(reason))
  })
}

/// `GET /api/v1/automation/settings` — load the current mode + options.
pub fn load_settings(
  on_done: fn(Result(AutomationSettings, String)) -> Nil,
) -> Nil {
  api_client.request("GET", "/api/v1/automation/settings", "", fn(_status, body) {
    on_done(parse_settings(body))
  }, fn(reason) {
    on_done(Error(reason))
  })
}

/// `GET /api/v1/automation/panel` already embeds `metrics` (Phase 8.1 fix).
/// We re-use the panel payload so the moderator token works and there is
/// no extra request.
pub fn load_efficiency_metrics(
  on_done: fn(Result(List(EfficiencyMetric), String)) -> Nil,
) -> Nil {
  load_panel(fn(result) {
    case result {
      Ok(panel) -> on_done(Ok(panel.metrics))
      Error(reason) -> on_done(Error(reason))
    }
  })
}

/// `GET /api/v1/automation/exceptions` — list of exceptions.
pub fn load_exceptions(
  only_open: Bool,
  on_done: fn(Result(List(AgentException), String)) -> Nil,
) -> Nil {
  let path = case only_open {
    True -> "/api/v1/automation/exceptions?only_open=true"
    False -> "/api/v1/automation/exceptions"
  }
  api_client.request("GET", path, "", fn(_status, body) {
    // The backend wraps the list as `{ items: [...] }`.
    let decoder = {
      use items <- decode.field("items", decode.list(exception_decoder()))
      decode.success(items)
    }
    case json.parse(body, decoder) {
      Ok(items) -> on_done(Ok(items))
      Error(_) -> on_done(Error("Не удалось разобрать исключения"))
    }
  }, fn(reason) {
    on_done(Error(reason))
  })
}

/// `GET /api/v1/automation/panel` is the source of truth for the journal
/// (it embeds `actions`). The Lustre journal screen simply reuses the
/// panel payload and pulls `.actions` out of it.
pub fn load_journal(
  on_done: fn(Result(List(AutomationAction), String)) -> Nil,
) -> Nil {
  load_panel(fn(result) {
    case result {
      Ok(panel) -> on_done(Ok(panel.actions))
      Error(reason) -> on_done(Error(reason))
    }
  })
}

/// `POST /api/v1/automation/mode` — change automation mode.
pub fn save_mode(
  mode: String,
  on_done: fn(Result(AutomationSettings, String)) -> Nil,
) -> Nil {
  let body =
    json.object([#("mode", json.string(mode))])
    |> json.to_string
  api_client.request("POST", "/api/v1/automation/mode", body, fn(_status, text) {
    on_done(parse_settings(text))
  }, fn(reason) {
    on_done(Error(reason))
  })
}

/// `POST /api/v1/automation/recheck` — ask Agent A to re-check a request.
pub fn recheck_request(
  request_id: String,
  on_done: fn(Result(String, String)) -> Nil,
) -> Nil {
  let body =
    json.object([#("request_id", json.string(request_id))])
    |> json.to_string
  api_client.request("POST", "/api/v1/automation/recheck", body, fn(_status, text) {
    on_done(Ok(text))
  }, fn(reason) {
    on_done(Error(reason))
  })
}

/// `POST /api/v1/automation/exceptions/{id}/resolve` — resolve exception.
pub fn resolve_exception(
  exception_id: String,
  note: String,
  on_done: fn(Result(String, String)) -> Nil,
) -> Nil {
  let path = "/api/v1/automation/exceptions/" <> exception_id <> "/resolve"
  let body =
    json.object([#("note", json.string(note))])
    |> json.to_string
  api_client.request("POST", path, body, fn(_status, text) {
    on_done(Ok(text))
  }, fn(reason) {
    on_done(Error(reason))
  })
}
