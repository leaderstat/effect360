// services/frontend/src/effectivnost_360_lustre/screen.gleam
//
// CJM → screen map for the applicant journey.
//
// Source of truth: docs/architecture/cjm-screen-map.md (v1.0, 2026-10-23),
// which is derived from docs/Readme.md §"Цели P0", docs/Backlog.md §9,
// docs/tz/CustDev.md §1/§5 and docs/tz/Check-point.md §2/§6.
//
// The screen map has FOUR screens, and the screen a user sees is derived
// from the URL path:
//
//   S0  /                      Старт        — назначение сервиса, одна точка входа
//   S1  /describe              Описание     — свободный текст → черновик
//   S2  /request/{id}          Уточнения    — извлечённые поля + недостающее + основание
//   S4  /request/{id}          Результат    — статус submitted (тот же маршрут, другое состояние)
//
// Routing lives on the SERVER (nginx), not in Lustre: after F5 the browser
// must be able to re-open a request straight from its URL, and the state
// must come from the server, not from client memory. This module therefore
// only *parses* a path into a route; the actual navigation is a plain
// `location.assign` performed by the JS adapter.

import gleam/option.{type Option, None, Some}
import gleam/string

/// The screens of the applicant journey and of the Phase-7 closed loop.
pub type Screen {
  /// S0 — Старт.
  Start
  /// S1 — Описание запроса (свободный текст).
  Describe
  /// S2 — Уточнения: извлечённые поля, недостающее, основания требований.
  Clarify(String)
  /// S4 — Результат: заявка принята.
  Result(String)
  /// P7.1 — Кабинет заявителя: список своих заявок.
  MyRequests
  /// P7.2 — Лента уведомлений заявителя.
  Notifications
  /// P7.3 — Карточка заявки: сведения, история, ответ, результат.
  RequestCard(String)
  /// P7.4 — Таймлайн заявки (отдельный маршрут для «История»).
  RequestHistory(String)
  /// P7.5 — Очередь модератора.
  ModerationQueue
  /// P7.6 — Подготовка и предпросмотр официального ответа.
  ResponseEditor(String)
  /// P7.7 — Метрики эффективности 360.
  Metrics
  // ---- Phase 8: панель цифрового модератора ----
  /// P8.1 — Панель автоматизации (режим + цифровой модератор + очередь).
  AutomationDashboard
  /// P8.2 — Только цифровой модератор: последние проверки и предложения.
  AgentChecks
  /// P8.3 — Очередь исключений «Требуется решение человека».
  AgentExceptions
  /// P8.4 — Журнал автоматических действий.
  AutomationJournal
  /// P8.5 — Переключатель режима автоматизации (manual/confirm/auto).
  AutomationSettings
  /// P8.6 — Уведомления колокольчика с фильтром по агентам (route для читаемого URL).
  ApplicantBell
}

/// A parsed route.
pub type Route {
  Route(screen: Screen, request_id: Option(String))
}

/// Parse a URL path into a route.
///
/// Rules (mirrors the nginx `location` blocks in services/frontend/nginx.conf):
///   "/"                    → S0 Start
///   "/describe"            → S1 Describe
///   "/request/<uuid>"      → S2 Clarify(uuid)
///   anything else          → S0 Start (the server normally 404s first)
pub fn parse_route(path: String) -> Route {
  let trimmed = string.trim(path)
  case trimmed {
    "" | "/" -> Route(Start, None)
    "/describe" -> Route(Describe, None)
    "/my/requests" -> Route(MyRequests, None)
    "/notifications" -> Route(Notifications, None)
    "/moderation/queue" -> Route(ModerationQueue, None)
    "/moderation/metrics" -> Route(Metrics, None)
    _ ->
      case string.split(trimmed, on: "/") {
        ["", "request", id] ->
          case id == "" {
            True -> Route(Start, None)
            False -> Route(Clarify(id), Some(id))
          }
        ["", "request", id, "detail"] ->
          case id == "" {
            True -> Route(Start, None)
            False -> Route(RequestCard(id), Some(id))
          }
        ["", "request", id, "history"] ->
          case id == "" {
            True -> Route(Start, None)
            False -> Route(RequestHistory(id), Some(id))
          }
        ["", "request", id, "response"] ->
          case id == "" {
            True -> Route(Start, None)
            False -> Route(ResponseEditor(id), Some(id))
          }
        // ---- Phase 8: режим автоматизации и ИИ-агенты ----
        ["", "automation"] -> Route(AutomationDashboard, None)
        ["", "automation", "checks"] -> Route(AgentChecks, None)
        ["", "automation", "exceptions"] -> Route(AgentExceptions, None)
        ["", "automation", "journal"] -> Route(AutomationJournal, None)
        ["", "automation", "settings"] -> Route(AutomationSettings, None)
        ["", "account", "bell"] -> Route(ApplicantBell, None)
        _ -> Route(Start, None)
      }
  }
}

/// The path a screen should be rendered at.
pub fn path_for(screen: Screen) -> String {
  case screen {
    Start -> "/"
    Describe -> "/describe"
    Clarify(id) -> "/request/" <> id
    Result(id) -> "/request/" <> id
    MyRequests -> "/my/requests"
    Notifications -> "/notifications"
    RequestCard(id) -> "/request/" <> id <> "/detail"
    RequestHistory(id) -> "/request/" <> id <> "/history"
    ResponseEditor(id) -> "/request/" <> id <> "/response"
    ModerationQueue -> "/moderation/queue"
    Metrics -> "/moderation/metrics"
    AutomationDashboard -> "/automation"
    AgentChecks -> "/automation/checks"
    AgentExceptions -> "/automation/exceptions"
    AutomationJournal -> "/automation/journal"
    AutomationSettings -> "/automation/settings"
    ApplicantBell -> "/account/bell"
  }
}

/// The URL a new draft is written to after creation.
pub fn path_for_new_request(request_id: String) -> String {
  "/request/" <> request_id
}

/// Human-readable title of a screen, used in the page header.
pub fn screen_title(screen: Screen) -> String {
  case screen {
    Start -> "Эффективность 360"
    Describe -> "Опишите запрос"
    Clarify(_) -> "Уточните заявку"
    Result(_) -> "Заявка отправлена"
    MyRequests -> "Мои заявки"
    Notifications -> "Уведомления"
    RequestCard(_) -> "Карточка заявки"
    RequestHistory(_) -> "История заявки"
    ResponseEditor(_) -> "Официальный ответ"
    ModerationQueue -> "Очередь модератора"
    Metrics -> "Метрики эффективности 360"
    AutomationDashboard -> "Панель автоматизации"
    AgentChecks -> "Цифровой модератор"
    AgentExceptions -> "Исключения: требуется человек"
    AutomationJournal -> "Журнал автоматических действий"
    AutomationSettings -> "Режим автоматизации"
    ApplicantBell -> "Уведомления"
  }
}

/// Whether the screen shows the "status + fields + submit" workspace.
pub fn is_request_screen(screen: Screen) -> Bool {
  case screen {
    Clarify(_) | Result(_) -> True
    _ -> False
  }
}

/// Whether the screen needs an authenticated session (Phase-7 screens).
pub fn needs_session(screen: Screen) -> Bool {
  case screen {
    Start | Describe -> False
    _ -> True
  }
}

/// The step number shown in the breadcrumb (1-based), or 0 when there is
/// no step yet.
pub fn step_number(screen: Screen) -> Int {
  case screen {
    Start -> 0
    Describe -> 1
    Clarify(_) -> 2
    Result(_) -> 3
    // The Phase-7 screens are not part of the three-step applicant wizard.
    _ -> 0
  }
}
