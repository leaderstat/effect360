// services/api/src/effectivnost_360/state_machine.gleam
//
// State machine of a request, and the notifications each transition emits.
//
// ## Жизненный цикл заявки CJM (Эффективность 360)
// --------------------------
//   Создана -> Отправлена -> Принята в работу -> В работе -> Ответ подготовлен -> Завершена
//           -> Требуется уточнение -> В работе -> Ответ подготовлен -> Завершена
//
// Реальные статусы в базе данных (см. миграцию 002_moderation_360.sql):
//
//   draft        Черновик                 не создана
//   submitted    Отправлена               не принята
//   accepted     Принята в работу         не принята
//   in_progress  В работе
//   returned     Требуется уточнение       не принята
//   answer_ready Ответ подготовлен        не принят
//   completed    Рассмотрение завершено   не завершена
//
// ## Инварианты:
// -------
//   * Модуль PURE: ни одного SQL-вызова, ни одного HTTP-вызова.
//     Решение о переходе принимается здесь, применяется в `moderation.gleam`.
//   * Каждый допустимый переход порождает ровно одно уведомление заявителю.
//     «Событие аудита» без воронки информирования - это не модельное событие.
//   * `completed` терминален: из него нельзя перейти ни в какой переход.
//   * `returned` - заявитель ответил на уточнение, модератор снова принимает в работу.
//
// ## Совместимость со схемой: старые статусы не переименованы:
// ---------------------------------------
// В 001_initial.sql было: draft | submitted | in_progress | returned | completed.
// Совместимость сохранена: `draft`, `submitted`, `in_progress`, `returned`
// и `completed` сохранили свой смысл. Добавлены промежуточные статусы `accepted` и `answer_ready`,
// поэтому появились и новые переходы, в том числе «принята в работу» и «ответ готов».
//
// ## Именование конструкторов:
// --------------------------
// Gleam не допускает двух конструкторов с одинаковым именем в модуле.
// Конструкторы `Status` повторяют значения колонки `requests.status`
// (`Draft`, `Submitted`, `Accepted`, `InProgress`, `Returned`, `AnswerReady`,
// `Completed`). Конструкторы действий и уведомлений получили префиксы
// `Action*` и `Notification*`, чтобы не пересекаться с ними.

import gleam/option.{type Option, None, Some}

/// The lifecycle status of a request.
pub type Status {
  Draft
  Submitted
  Accepted
  InProgress
  Returned
  AnswerReady
  Completed
  UnknownStatus(String)
}

pub fn parse_status(s: String) -> Status {
  case s {
    "draft" -> Draft
    "submitted" -> Submitted
    "accepted" -> Accepted
    "in_progress" -> InProgress
    "returned" -> Returned
    "answer_ready" -> AnswerReady
    "completed" -> Completed
    other -> UnknownStatus(other)
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    Draft -> "draft"
    Submitted -> "submitted"
    Accepted -> "accepted"
    InProgress -> "in_progress"
    Returned -> "returned"
    AnswerReady -> "answer_ready"
    Completed -> "completed"
    UnknownStatus(other) -> other
  }
}

/// A moderator action.
pub type Action {
  /// Принять в работу (submitted -> accepted).
  ActionAccept
  /// Начать работу по заявке (accepted -> in_progress).
  ActionStart
  /// Запросить уточнение (accepted | in_progress -> returned).
  ActionRequestClarification
  /// Заявитель ответил на уточнение (returned -> in_progress).
  ActionApplicantAnswered
  /// Ответ подготовлен (in_progress -> answer_ready).
  ActionAnswerReady
  /// Рассмотрение завершено (answer_ready -> completed).
  ActionComplete
}

pub fn action_to_string(action: Action) -> String {
  case action {
    ActionAccept -> "accept"
    ActionStart -> "start"
    ActionRequestClarification -> "request_clarification"
    ActionApplicantAnswered -> "applicant_answered"
    ActionAnswerReady -> "answer_ready"
    ActionComplete -> "complete"
  }
}

/// The notification a transition emits to the applicant.
pub type NotificationKind {
  NotificationRequestAccepted
  NotificationRequestInProgress
  NotificationClarificationRequested
  NotificationApplicantAnswered
  NotificationAnswerReady
  NotificationRequestCompleted
  NotificationFeedbackRequested
}

pub fn notification_kind_to_string(kind: NotificationKind) -> String {
  case kind {
    NotificationRequestAccepted -> "request_accepted"
    NotificationRequestInProgress -> "request_in_progress"
    NotificationClarificationRequested -> "clarification_requested"
    NotificationApplicantAnswered -> "applicant_answered"
    NotificationAnswerReady -> "answer_ready"
    NotificationRequestCompleted -> "request_completed"
    NotificationFeedbackRequested -> "feedback_requested"
  }
}

/// Is the transition `from -> to` allowed by the state machine?
///
/// This is the single source of truth for legal transitions. The API layer
/// calls it BEFORE touching the database, and the database layer re-checks
/// the current status under `SELECT ... FOR UPDATE`, so a concurrent
/// moderator cannot sneak an illegal transition through.
pub fn is_allowed(from: Status, to: Status) -> Bool {
  case from, to {
    Submitted, Accepted -> True
    Accepted, InProgress -> True
    Accepted, Returned -> True
    InProgress, Returned -> True
    InProgress, AnswerReady -> True
    // The applicant answered a clarification: the request goes back to work.
    Returned, InProgress -> True
    AnswerReady, Completed -> True
    // Terminal state - nothing leaves `completed`.
    _, _ -> False
  }
}

/// Which status does this action lead to?
pub fn target_status(action: Action) -> Status {
  case action {
    ActionAccept -> Accepted
    ActionStart -> InProgress
    ActionRequestClarification -> Returned
    ActionApplicantAnswered -> InProgress
    ActionAnswerReady -> AnswerReady
    ActionComplete -> Completed
  }
}

/// The notification kind emitted by an action, if any.
///
/// `ActionApplicantAnswered` is initiated by the applicant, so it notifies
/// the moderator, not the applicant - that notification is created by the
/// applicant-response endpoint, not here.
pub fn notification_for(action: Action) -> Option(NotificationKind) {
  case action {
    ActionAccept -> Some(NotificationRequestAccepted)
    ActionStart -> Some(NotificationRequestInProgress)
    ActionRequestClarification -> Some(NotificationClarificationRequested)
    ActionApplicantAnswered -> None
    ActionAnswerReady -> Some(NotificationAnswerReady)
    ActionComplete -> Some(NotificationRequestCompleted)
  }
}

/// Human-readable title for the notification, in Russian.
pub fn notification_title(kind: NotificationKind) -> String {
  case kind {
    NotificationRequestAccepted -> "Заявка принята в работу"
    NotificationRequestInProgress -> "Заявка в работе"
    NotificationClarificationRequested -> "Требуется ваше уточнение"
    NotificationApplicantAnswered -> "Заявитель ответил на уточнение"
    NotificationAnswerReady -> "Официальный ответ подготовлен"
    NotificationRequestCompleted -> "Рассмотрение завершено"
    NotificationFeedbackRequested -> "Оцените ответ"
  }
}

/// Human-readable body for the notification, in Russian.
pub fn notification_body(kind: NotificationKind) -> String {
  case kind {
    NotificationRequestAccepted -> "Модератор принял вашу заявку в работу."
    NotificationRequestInProgress -> "Работа по вашей заявке ведется исполнителем."
    NotificationClarificationRequested ->
      "Для продолжения рассмотрения нужны дополнительные сведения."
    NotificationApplicantAnswered -> "Заявитель предоставил дополнительные сведения."
    NotificationAnswerReady -> "Официальный ответ подготовлен и доступен для просмотра."
    NotificationRequestCompleted ->
      "Рассмотрение завершено. Официальный ответ приложен к заявке."
    NotificationFeedbackRequested ->
      "Оцените ответ, понятен ли вам результат и решен ли ваш вопрос."
  }
}

/// All statuses, in the order of the target CJM path. Used by the
/// applicant UI to render the progress stepper.
pub fn status_path() -> List(Status) {
  [
    Draft,
    Submitted,
    Accepted,
    InProgress,
    Returned,
    AnswerReady,
    Completed,
  ]
}

/// The 1-based step number of a status along the target path.
/// `Returned` is a side-branch, so it shares the step of `InProgress`.
pub fn step_number(status: Status) -> Int {
  case status {
    Draft -> 1
    Submitted -> 2
    Accepted -> 3
    InProgress | Returned -> 4
    AnswerReady -> 5
    Completed -> 6
    UnknownStatus(_) -> 0
  }
}

/// A short Russian label for a status, used in the UI badges.
pub fn status_label(status: Status) -> String {
  case status {
    Draft -> "Черновик"
    Submitted -> "Отправлена"
    Accepted -> "Принята"
    InProgress -> "В работе"
    Returned -> "Требуется уточнение"
    AnswerReady -> "Ответ готов"
    Completed -> "Завершена"
    UnknownStatus(other) -> other
  }
}

/// Actions available for a moderator in a given status.
///
/// The UI renders these buttons; the API validates them independently.
/// Returning the list from ONE place keeps the two in sync.
pub fn available_actions(status: Status) -> List(Action) {
  case status {
    Submitted -> [ActionAccept]
    Accepted -> [ActionStart, ActionRequestClarification]
    InProgress -> [ActionRequestClarification, ActionAnswerReady]
    Returned -> []
    AnswerReady -> [ActionComplete]
    Draft | Completed | UnknownStatus(_) -> []
  }
}
