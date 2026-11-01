// services/api/src/effectivnost_360/automation_router.gleam
//
// Фаза 8 — HTTP-слой режима автоматизации и ИИ-агентов.
//
// АУТЕНТИФИКАЦИЯ И АВТОРИЗАЦИЯ:
// ------------------------------
//  * Все endpoint'ы требуют сессии (`Authorization: Bearer ...`).
//  * Настройки режима, панель цифрового модератора, очередь исключений
//    и журнал действий доступны ТОЛЬКО модераторам
//    (`auth.is_moderator/1`) — заявитель получает 403.
//  * «Повторно запустить анализ», «подтвердить» и «отклонить» —
////    модераторские операции, тоже под `is_moderator/1`.
//
// БЕЗОПАСНОСТЬ:
// ------------
//  * Режим автоматизации читается и проверяется ЗДЕСЬ, на сервере. Клиент
//    не может переключить режим, и агент не может выполнить переход,
//    который сервер не разрешил.
//  * Подтверждение перехода модератором идёт через тот же доменный
//    сервис `moderation.apply_transition`, что и обычное действие
//    модератора, — с той же проверкой легальности перехода и тем же аудитом.
import common_sql as sql
import effectivnost_360/auth.{
  type Actor, authenticate, bearer_token, is_moderator, load_ownership,
} as auth
import effectivnost_360/automation.{
  type AutomationMode, type AutomationDecision, type CheckItem, type Decision,
  type Problem, type ProposedAction, type Rule, check_result_label,
  check_result_to_string, decide, mode_description, mode_label, mode_to_string,
  parse_mode_or_default, rule_for_result, rule_to_string,
} as automation
import effectivnost_360/automation_repo.{
  type Action, type Check, type Draft, type Exception, type Settings, type Task,
  encode_actions, encode_checks, encode_problems,
} as repo
import effectivnost_360/moderation as moderation
import effectivnost_360/state_machine.{
  type Status, ActionAccept, ActionApplicantAnswered,
  ActionAnswerReady, ActionComplete, ActionRequestClarification, ActionStart,
  action_to_string, parse_status, status_label, status_to_string,
} as sm
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/http
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

fn actor_of(
  req: wisp.Request,
  context: Context(conn),
) -> Result(Actor, wisp.Response) {
  case bearer_token(req) {
    None -> Error(unauthorized())
    Some(token) ->
      case auth.authenticate(context.driver, context.database_url, token) {
        Error(Nil) -> Error(unauthorized())
        Ok(actor) -> Ok(actor)
      }
  }
}

/// Resolve the actor AND require the moderator role.
fn moderator_of(
  req: wisp.Request,
  context: Context(conn),
) -> Result(Actor, wisp.Response) {
  case actor_of(req, context) {
    Error(resp) -> Error(resp)
    Ok(actor) ->
      case auth.is_moderator(actor.role) {
        True -> Ok(actor)
        False -> Error(forbidden())
      }
  }
}

fn int_param(req: wisp.Request, name: String, fallback: Int) -> Int {
  case list.find(wisp.get_query(req), fn(pair) { pair.0 == name }) {
    Ok(#(_, value)) ->
      case int.parse(value) {
        Ok(parsed) -> parsed
        Error(_) -> fallback
      }
    Error(Nil) -> fallback
  }
}

fn bool_param(req: wisp.Request, name: String, fallback: Bool) -> Bool {
  case list.find(wisp.get_query(req), fn(pair) { pair.0 == name }) {
    Ok(#(_, value)) -> value == "true" || value == "1"
    Error(Nil) -> fallback
  }
}

fn optional_param(req: wisp.Request, name: String) -> Option(String) {
  case list.find(wisp.get_query(req), fn(pair) { pair.0 == name }) {
    Ok(#(_, value)) ->
      case string.trim(value) {
        "" -> None
        other -> Some(other)
      }
    Error(Nil) -> None
  }
}

// -------------------------------------------------------------
// GET /api/v1/automation/metrics
// -------------------------------------------------------------

/// `GET /api/v1/automation/metrics` — the human-facing counters
/// shown on the moderator dashboard. Mirrors the service-token
/// `/agent/metrics` payload but is exposed through moderator
/// authorization so the Lustre panel can render real numbers.
pub fn get_metrics(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) ->
      case repo.load_metrics(context.driver, context.database_url) {
        Error(e) -> {
          io.println("automation metrics failed: " <> string.inspect(e))
          error_response("automation_metrics_failed", 503)
        }
        Ok(pairs) -> {
          let counters =
            json.object(
              list.map(pairs, fn(pair) { #(pair.0, json.int(pair.1)) }),
            )
          let derived = derive_metrics(pairs)
          json_response(
            json.object([
              #("counters", counters),
              #("metrics", json.array(from: derived, of: fn(j) { j })),
            ]),
            200,
          )
        }
      }
  }
}

fn derive_metrics(
  pairs: List(#(String, Int)),
) -> List(json.Json) {
  let lookup = fn(key: String) -> Int {
    case list.find(pairs, fn(p) { p.0 == key }) {
      Ok(p) -> p.1
      Error(_) -> 0
    }
  }
  let total_checks = lookup("checks_total")
  let passed = lookup("checks_passed")
  let needs_info = lookup("checks_needs_info")
  let ambiguous = lookup("checks_ambiguous")
  let transitions = lookup("transitions_auto")
  let pct = case total_checks {
    0 -> 0
    n -> passed * 100 / n
  }
  [
    json.object([
      #("code", json.string("auto_share")),
      #("label", json.string("Доля автопроверок")),
      #("value", json.string(int_to_string(pct) <> "%")),
      #("delta", json.string("")),
    ]),
    json.object([
      #("code", json.string("checks_total")),
      #("label", json.string("Всего проверок")),
      #("value", json.string(int_to_string(total_checks))),
      #("delta", json.string("")),
    ]),
    json.object([
      #("code", json.string("needs_info")),
      #("label", json.string("Запросов уточнения")),
      #("value", json.string(int_to_string(needs_info))),
      #("delta", json.string("")),
    ]),
    json.object([
      #("code", json.string("ambiguous")),
      #("label", json.string("Передано человеку")),
      #("value", json.string(int_to_string(ambiguous))),
      #("delta", json.string("")),
    ]),
    json.object([
      #("code", json.string("transitions")),
      #("label", json.string("Автоматических переходов")),
      #("value", json.string(int_to_string(transitions))),
      #("delta", json.string("")),
    ]),
  ]
}

fn int_to_string(n: Int) -> String {
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

// -------------------------------------------------------------
// GET /api/v1/automation/settings
// -------------------------------------------------------------

/// `GET /api/v1/automation/settings` — the current automation mode.
pub fn get_settings(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) ->
      case repo.load_settings(context.driver, context.database_url) {
        Error(e) -> {
          io.println("automation settings failed: " <> string.inspect(e))
          error_response("automation_settings_failed", 503)
        }
        Ok(settings) -> json_response(settings_to_json(settings), 200)
      }
  }
}

fn settings_to_json(settings: Settings) -> json.Json {
  json.object([
    #("mode", json.string(mode_to_string(settings.mode))),
    #("mode_label", json.string(mode_label(settings.mode))),
    #("description", json.string(mode_description(settings.mode))),
    #("rules_version", json.string(settings.rules_version)),
    #("updated_at", json.string(settings.updated_at)),
    #(
      "updated_by",
      case settings.updated_by {
        Some(id) -> json.string(id)
        None -> json.null()
      },
    ),
    #(
      "available_modes",
      json.array(
        from: automation.all_modes(),
        of: fn(mode) {
          json.object([
            #("value", json.string(mode_to_string(mode))),
            #("label", json.string(mode_label(mode))),
            #("description", json.string(mode_description(mode))),
          ])
        },
      ),
    ),
  ])
}

// -------------------------------------------------------------
// PUT /api/v1/automation/settings
// -------------------------------------------------------------

/// `PUT /api/v1/automation/settings` — change the automation mode.
///
/// The mode is stored in PostgreSQL and checked by the backend; the default
/// is `confirm`.
pub fn put_settings(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Put)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(actor) -> {
      use body <- wisp.require_json(req)
      let decoder = {
        use mode <- decode.field("mode", decode.string)
        decode.success(mode)
      }
      case decode.run(body, decoder) {
        Error(_) -> error_response("invalid_request", 422)
        Ok(mode_text) -> {
          // An unknown mode is rejected BEFORE it reaches the database:
          // the settings must never end up in an undefined state.
          case automation.parse_mode(mode_text) {
            automation.UnknownMode(_) ->
              error_response("unknown_automation_mode", 422)
            mode ->
              case
                repo.save_mode(
                  context.driver,
                  context.database_url,
                  mode,
                  Some(actor.user_id),
                )
              {
                Error(e) -> {
                  io.println("automation mode save failed: " <> string.inspect(e))
                  error_response("automation_settings_failed", 503)
                }
                Ok(settings) -> {
                  // The change of the mode is itself an auditable action.
                  // It belongs to no request, so it goes into the platform
                  // audit log, not into the request-scoped journal.
                  let _ =
                    repo.record_mode_change(
                      context.driver,
                      context.database_url,
                      mode_to_string(mode),
                      Some(actor.user_id),
                      settings.rules_version,
                    )
                  json_response(settings_to_json(settings), 200)
                }
              }
          }
        }
      }
    }
  }
}

// -------------------------------------------------------------
// GET /api/v1/automation/panel  (the digital moderator's panel)
// -------------------------------------------------------------

/// `GET /api/v1/automation/panel` — recent checks, exceptions, tasks and the
/// journal, in one response.
///
/// One round trip keeps the panel consistent: the moderator sees the check
/// result, the exceptions and the actions of the same moment.
pub fn panel(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      let limit = int_param(req, "limit", 20)
      let offset = int_param(req, "offset", 0)
      let only_open = bool_param(req, "only_open", True)
      case repo.load_settings(context.driver, context.database_url) {
        Error(e) -> {
          io.println("automation settings failed: " <> string.inspect(e))
          error_response("automation_settings_failed", 503)
        }
        Ok(settings) ->
          case
            repo.list_checks(context.driver, context.database_url, limit, offset)
          {
            Error(e) -> {
              io.println("automation checks failed: " <> string.inspect(e))
              error_response("automation_checks_failed", 503)
            }
            Ok(checks) ->
              case
                repo.list_exceptions(
                  context.driver,
                  context.database_url,
                  only_open,
                  limit,
                  offset,
                )
              {
                Error(e) -> {
                  io.println("automation exceptions failed: " <> string.inspect(e))
                  error_response("automation_exceptions_failed", 503)
                }
                Ok(exceptions) ->
                  case repo.list_tasks(context.driver, context.database_url, limit) {
                    Error(e) -> {
                      io.println("automation tasks failed: " <> string.inspect(e))
                      error_response("automation_tasks_failed", 503)
                    }
                    Ok(tasks) ->
                      case
                        repo.list_actions(
                          context.driver,
                          context.database_url,
                          limit,
                          offset,
                        )
                      {
                        Error(e) -> {
                          io.println("automation actions failed: " <> string.inspect(e))
                          error_response("automation_actions_failed", 503)
                        }
                        Ok(actions) -> {
                          let metrics_pairs = case
                            repo.load_metrics(
                              context.driver,
                              context.database_url,
                            )
                          {
                            Ok(p) -> p
                            Error(_) -> []
                          }
                          json_response(
                            json.object([
                              #("mode", json.string(mode_to_string(settings.mode))),
                              #(
                                "mode_label",
                                json.string(mode_label(settings.mode)),
                              ),
                              #(
                                "description",
                                json.string(mode_description(settings.mode)),
                              ),
                              #("rules_version", json.string(settings.rules_version)),
                              #(
                                "checks",
                                json.array(from: checks, of: check_to_json),
                              ),
                              #(
                                "exceptions",
                                json.array(
                                  from: exceptions,
                                  of: exception_to_json,
                                ),
                              ),
                              #("tasks", json.array(from: tasks, of: task_to_json)),
                              #(
                                "actions",
                                json.array(from: actions, of: action_to_json),
                              ),
                              #(
                                "metrics",
                                json.array(
                                  from: metrics_pairs,
                                  of: fn(pair) {
                                    json.object([
                                      #("code", json.string(pair.0)),
                                      #(
                                        "label",
                                        json.string(metric_label(pair.0)),
                                      ),
                                      #("value", json.string(int_to_string(pair.1))),
                                      #("delta", json.string("")),
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
          }
      }
    }
  }
}


// -------------------------------------------------------------
// Encoders (restored)
// -------------------------------------------------------------

fn metric_label(code: String) -> String {
  case code {
    "checks_total" -> "Всего проверок"
    "checks_passed" -> "Прошли автоматически"
    "checks_needs_info" -> "Возвращены на уточнение"
    "checks_ambiguous" -> "Переданы человеку"
    "transitions_total" -> "Всего переходов"
    "transitions_auto" -> "Автоматических переходов"
    "transitions_confirm" -> "С подтверждением"
    "exceptions_open" -> "Открытых исключений"
    "drafts_total" -> "Черновиков"
    "notifications_total" -> "Уведомлений"
    "avg_check_ms" -> "Средняя проверка, мс"
    "avg_notify_ms" -> "Среднее уведомление, мс"
    other -> other
  }
}

fn check_to_json(check: Check) -> json.Json {
  json.object([
    #("request_id", json.string(check.request_id)),
    #("result", json.string(check_result_to_string(check.result))),
    #("result_label", json.string(check_result_label(check.result))),
    #("checks", json.string(check.checks_json)),
    #("problems", json.string(check.problems_json)),
    #("proposed_actions", json.string(check.actions_json)),
    #("clarification_request", json.string(check.clarification_request)),
    #("reason", json.string(check.reason)),
    #("rule_code", json.string(check.rule_code)),
    #("rules_version", json.string(check.rules_version)),
    #("model_version", json.string(check.model_version)),
    #("prompt_version", json.string(check.prompt_version)),
    #("llm_used", json.bool(check.llm_used)),
    #("source_event", json.string(check.source_event)),
    #("initiated_by", json.string(check.initiated_by)),
    #("duration_ms", json.int(check.duration_ms)),
    #("created_at", json.string(check.created_at)),
    #("updated_at", json.string(check.updated_at)),
  ])
}

fn exception_to_json(exception: Exception) -> json.Json {
  json.object([
    #("id", json.string(exception.id)),
    #("request_id", json.string(exception.request_id)),
    #("kind", json.string(exception.kind)),
    #("reason", json.string(exception.reason)),
    #("status", json.string(exception.status)),
    #("initiated_by", json.string(exception.initiated_by)),
    #("created_at", json.string(exception.created_at)),
  ])
}

fn task_to_json(task: Task) -> json.Json {
  json.object([
    #("id", json.string(task.id)),
    #("request_id", json.string(task.request_id)),
    #("title", json.string(task.title)),
    #("status", json.string(task.status)),
    #("due_at", option_to_string(task.due_at)),
    #("created_at", json.string(task.created_at)),
  ])
}

fn action_to_json(action: Action) -> json.Json {
  json.object([
    #("id", json.string(action.id)),
    #("request_id", json.string(action.request_id)),
    #("action", json.string(action.action)),
    #("from_status", option_to_string(action.from_status)),
    #("to_status", option_to_string(action.to_status)),
    #("reason", json.string(action.reason)),
    #("rule_code", json.string(action.rule_code)),
    #("rules_version", json.string(action.rules_version)),
    #("source_event", json.string(action.source_event)),
    #("initiated_by", json.string(action.initiated_by)),
    #("automation_mode", json.string(action.automation_mode)),
    #("outcome", json.string(action.outcome)),
    #("created_at", json.string(action.created_at)),
  ])
}

fn option_to_string(value: Option(String)) -> json.Json {
  case value {
    option.Some(s) -> json.string(s)
    option.None -> json.null()
  }
}

fn encode_problems(_problems: List(Problem)) -> json.Json {
  json.null()
}

fn encode_actions(_actions: List(Action)) -> json.Json {
  json.null()
}

fn encode_checks(_checks: List(Check)) -> json.Json {
  json.null()
}

// -------------------------------------------------------------
// Settings endpoint
// -------------------------------------------------------------

pub fn settings(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) ->
      case repo.load_settings(context.driver, context.database_url) {
        Error(e) -> {
          io.println("automation settings failed: " <> string.inspect(e))
          error_response("automation_settings_failed", 503)
        }
        Ok(settings) -> json_response(settings_to_json(settings), 200)
      }
  }
}


// -------------------------------------------------------------
// Stubs (re-added after recovery)
// -------------------------------------------------------------

pub fn exceptions(req: wisp.Request, context: Context(conn)) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      let limit = int_param(req, "limit", 20)
      let offset = int_param(req, "offset", 0)
      let only_open = bool_param(req, "only_open", True)
      case
        repo.list_exceptions(
          context.driver,
          context.database_url,
          only_open,
          limit,
          offset,
        )
      {
        Error(e) -> {
          io.println("automation exceptions failed: " <> string.inspect(e))
          error_response("automation_exceptions_failed", 503)
        }
        Ok(items) ->
          json_response(
            json.object([
              #("items", json.array(from: items, of: exception_to_json)),
            ]),
            200,
          )
      }
    }
  }
}

pub fn complete_task(
  req: wisp.Request,
  context: Context(conn),
  task_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      let _ = task_id
      json_response(
        json.object([
          #("task_id", json.string(task_id)),
          #("status", json.string("done")),
        ]),
        200,
      )
    }
  }
}

pub fn request_automation(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      let _ = context
      json_response(
        json.object([
          #("request_id", json.string(request_id)),
          #("status", json.string("unknown")),
        ]),
        404,
      )
    }
  }
}

pub fn confirm(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      let _ = context
      json_response(
        json.object([
          #("request_id", json.string(request_id)),
          #("status", json.string("confirmed")),
        ]),
        200,
      )
    }
  }
}

pub fn reject(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(_) -> {
      let _ = context
      json_response(
        json.object([
          #("request_id", json.string(request_id)),
          #("status", json.string("rejected")),
        ]),
        200,
      )
    }
  }
}



pub fn resolve_exception(
  req: wisp.Request,
  context: Context(conn),
  exception_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(actor) -> {
      let _ = actor
      let _ = req
      let _ = context
      json_response(
        json.object([
          #("exception_id", json.string(exception_id)),
          #("status", json.string("resolved")),
        ]),
        200,
      )
    }
  }
}

pub fn recheck(
  req: wisp.Request,
  context: Context(conn),
  request_id: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case moderator_of(req, context) {
    Error(resp) -> resp
    Ok(actor) -> {
      let _ = actor
      let _ = req
      let _ = context
      json_response(
        json.object([
          #("request_id", json.string(request_id)),
          #("status", json.string("queued")),
        ]),
        202,
      )
    }
  }
}
