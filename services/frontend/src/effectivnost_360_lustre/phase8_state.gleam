// services/frontend/src/effectivnost_360_lustre/phase8_state.gleam
//
// Состояния экранов Фазы 8: панель автоматизации, цифровой модератор,
// очередь исключений, журнал действий, настройки режима.
//
// Здесь только типизированное состояние и фабрики. Эффекты и обновление
// остаются в app.gleam, чтобы не размывать границу между экранами.

import effectivnost_360_lustre/phase8_client.{
  type AgentCheck, type AgentException, type AutomationAction,
  type AutomationPanel, type AutomationSettings, type EfficiencyMetric,
  empty_panel, empty_settings,
}
import gleam/option.{type Option, None}

// -------------------------------------------------------------
// Состояние конкретного экрана панели автоматизации.
// -------------------------------------------------------------

/// Состояние, общее для всех экранов Phase 8: оно подтягивается одним
/// запросом к `/api/v1/automation/panel`, а остальные экраны перезапрашивают
/// нужные куски при необходимости.
pub type AutomationState {
  AutomationState(
    settings: AutomationSettings,
    panel: AutomationPanel,
    metrics: List(EfficiencyMetric),
    loading: Bool,
    error: Option(String),
    last_action_notice: Option(String),
    last_action_kind: String,
  )
}

pub fn empty_automation() -> AutomationState {
  AutomationState(
    settings: empty_settings(),
    panel: empty_panel(),
    metrics: [],
    loading: False,
    error: None,
    last_action_notice: None,
    last_action_kind: "info",
  )
}

/// Объединяет в себе всё состояние экрана «Очередь исключений».
pub type ExceptionsState {
  ExceptionsState(
    items: List(AgentException),
    loading: Bool,
    error: Option(String),
    resolving: Option(String),
    notice: Option(String),
  )
}

pub fn empty_exceptions() -> ExceptionsState {
  ExceptionsState(items: [], loading: False, error: None, resolving: None, notice: None)
}

/// Состояние экрана «Журнал автоматических действий».
pub type JournalState {
  JournalState(
    items: List(AutomationAction),
    loading: Bool,
    error: Option(String),
    filter_mode: String,
  )
}

pub fn empty_journal() -> JournalState {
  JournalState(items: [], loading: False, error: None, filter_mode: "all")
}

/// Состояние экрана «Цифровой модератор».
pub type AgentChecksState {
  AgentChecksState(
    checks: List(AgentCheck),
    loading: Bool,
    error: Option(String),
    rechecking: Option(String),
    notice: Option(String),
    filter_result: String,
  )
}

pub fn empty_agent_checks() -> AgentChecksState {
  AgentChecksState(
    checks: [],
    loading: False,
    error: None,
    rechecking: None,
    notice: None,
    filter_result: "all",
  )
}

/// Состояние экрана «Настройки режима».
pub type SettingsState {
  SettingsState(
    settings: AutomationSettings,
    loading: Bool,
    saving: Bool,
    error: Option(String),
    notice: Option(String),
  )
}

pub fn empty_settings_state() -> SettingsState {
  SettingsState(
    settings: empty_settings(),
    loading: False,
    saving: False,
    error: None,
    notice: None,
  )
}

/// Удобные селекторы.
pub fn panel(state: AutomationState) -> AutomationPanel {
  state.panel
}

pub fn has_data(state: AutomationState) -> Bool {
  !state.loading && state.error == None
}

pub fn open_exception_count(state: AutomationState) -> Int {
  state.panel.exceptions
  |> count_open_exceptions
}

fn count_open_exceptions(items: List(AgentException)) -> Int {
  case items {
    [] -> 0
    [head, ..tail] ->
      case head.status {
        "open" -> 1 + count_open_exceptions(tail)
        _ -> count_open_exceptions(tail)
      }
  }
}

/// Метка статуса исключения для UI.
pub fn exception_status_label(status: String) -> String {
  case status {
    "open" -> "Открыто"
    "resolved" -> "Решено"
    "dismissed" -> "Отклонено"
    other -> other
  }
}

/// Метка типа исключения.
pub fn exception_kind_label(kind: String) -> String {
  case kind {
    "needs_info" -> "Нужны уточнения"
    "ambiguous" -> "Неопределённость"
    "error" -> "Ошибка"
    "incomplete" -> "Не заполнено"
    other -> other
  }
}

/// Метка действия в журнале.
pub fn action_label(action: String) -> String {
  case action {
    "propose" -> "Предложение"
    "transition" -> "Переход"
    "clarification" -> "Запрос уточнения"
    "exception" -> "Исключение"
    "recheck" -> "Повторная проверка"
    other -> other
  }
}

/// Метка результата проверки для цифрового модератора.
pub fn check_result_label(result: String) -> String {
  case result {
    "passed" -> "Пройдено"
    "needs_info" -> "Нужны уточнения"
    "ambiguous" -> "Передано человеку"
    other -> other
  }
}

/// Простая запись уведомления для колокольчика заявителя.
pub type BellNotification {
  BellNotification(
    id: String,
    request_id: String,
    kind: String,
    title: String,
    body: String,
    read: Bool,
    created_at: String,
  )
}

/// Метка режима автоматизации.
pub fn mode_label(mode: String) -> String {
  case mode {
    "manual" -> "Ручной"
    "confirm" -> "С подтверждением"
    "auto" -> "Автоматический"
    other -> other
  }
}
