// services/frontend/src/effectivnost_360_lustre/phase7_state.gleam
//
// The Phase-7 state of the Lustre application: session, the applicant
// cabinet, the notification bell, the moderator queue, the request card,
// the official response and the metrics.
//
// DDD note. This module is the *application layer* for Phase 7: it
// orchestrates the use cases (load the cabinet, apply a moderation
// transition, save a response draft, submit feedback) and holds the
// presentation state. All business rules — which transitions are legal,
// whether a response may be approved, whose request may be seen — live in
// the backend (`state_machine.gleam`, `moderation.gleam`, `auth.gleam`) and
// are re-checked there on every call. The client never decides whether an
// action is allowed; it renders the server's verdict.
//
// The state is deliberately split per screen so that a screen that does not
// need the queue does not pay for loading it.

import effectivnost_360_lustre/phase7_client.{
  type ApplicantRequest, type Feedback, type Metric, type Notification,
  type OfficialResponse, type QueueItem, type RequestCard, type TransitionOutcome,
  TransitionApplied, TransitionMissing, TransitionRefused,
}
import gleam/list
import gleam/option.{type Option, None, Some}

// -------------------------------------------------------------
// Sub-states
// -------------------------------------------------------------

/// The session of the current user: `""` means "not loaded yet".
pub type Session {
  Session(user_id: String, role: String, display_name: String)
}

/// The state of the applicant cabinet.
pub type Cabinet {
  Cabinet(
    requests: List(ApplicantRequest),
    loading: Bool,
    error: Option(String),
  )
}

/// The state of the notification bell.
pub type Bell {
  Bell(items: List(Notification), unread: Int, loading: Bool, error: Option(String))
}

/// The state of the moderator queue and of its filters.
pub type QueueState {
  QueueState(
    items: List(QueueItem),
    total: Int,
    status_filter: String,
    type_filter: String,
    only_overdue: Bool,
    loading: Bool,
    error: Option(String),
  )
}

/// The state of the request card.
pub type CardState {
  CardState(
    card: Option(RequestCard),
    loading: Bool,
    error: Option(String),
    /// The note the moderator types before a transition.
    note: String,
    /// The clarification answer the applicant types.
    answer: String,
    /// The last transition verdict, shown as a toast on the screen.
    notice: Option(String),
    notice_kind: String,
  )
}

/// The state of the official response editor.
pub type ResponseState {
  ResponseState(
    response: Option(OfficialResponse),
    /// The requisites the moderator is editing, as field name → value.
    draft: List(#(String, String)),
    loading: Bool,
    saving: Bool,
    error: Option(String),
    notice: Option(String),
    preview: Bool,
  )
}

/// The state of the metrics dashboard.
pub type MetricsState {
  MetricsState(items: List(Metric), loading: Bool, error: Option(String))
}

// -------------------------------------------------------------
// Constructors
// -------------------------------------------------------------

pub fn empty_cabinet() -> Cabinet {
  Cabinet(requests: [], loading: False, error: None)
}

pub fn empty_bell() -> Bell {
  Bell(items: [], unread: 0, loading: False, error: None)
}

pub fn empty_queue() -> QueueState {
  QueueState(
    items: [],
    total: 0,
    status_filter: "",
    type_filter: "",
    only_overdue: False,
    loading: False,
    error: None,
  )
}

pub fn empty_card() -> CardState {
  CardState(
    card: None,
    loading: False,
    error: None,
    note: "",
    answer: "",
    notice: None,
    notice_kind: "info",
  )
}

pub fn empty_response() -> ResponseState {
  ResponseState(
    response: None,
    draft: [],
    loading: False,
    saving: False,
    error: None,
    notice: None,
    preview: False,
  )
}

pub fn empty_metrics() -> MetricsState {
  MetricsState(items: [], loading: False, error: None)
}

/// The requisites of the official letter, in the edited.
///
/// The list is the UI order of the form. The SERVER decides which of them
/// are required — the client only renders them and shows the `missing[]`
/// list the server returned.
pub fn response_requisites() -> List(#(String, String)) {
  [
    #("organization", "Организация-отправитель"),
    #("requisites", "Реквизиты отправителя"),
    #("registration_number", "Регистрационный номер"),
    #("recipient", "Адресат"),
    #("subject", "Тема обращения"),
    #("legal_basis", "Основание рассмотрения"),
    #("decision_summary", "Краткое изложение решения"),
    #("next_steps", "Дальнейшие действия"),
    #("responsible_executor", "Ответственный исполнитель"),
    #("contact_for_questions", "Контакт для уточнений"),
    #("signature_block", "Подпись"),
  ]
}

// -------------------------------------------------------------
// Pure reducers
// -------------------------------------------------------------

/// Turn a transition verdict into a human-readable notice.
pub fn transition_notice(outcome: TransitionOutcome) -> #(String, String) {
  case outcome {
    TransitionApplied(_, to_status, label) -> #(
      "Статус изменён: " <> label <> " (" <> to_status <> ")",
      "success",
    )
    TransitionRefused(current, reason) ->
      case reason {
        "" -> #("Переход отклонён сервером. Текущий статус: " <> current, "error")
        other -> #("Переход отклонён: " <> other, "error")
      }
    TransitionMissing -> #("Заявка не найдена", "error")
  }
}

/// The value of a requisite in the current draft.
pub fn draft_value(draft: List(#(String, String)), key: String) -> String {
  list.fold(draft, "", fn(acc, pair) {
    case pair.0 == key {
      True -> pair.1
      False -> acc
    }
  })
}

/// Set a requisite in the draft, keeping the order of the form.
pub fn draft_set(
  draft: List(#(String, String)),
  key: String,
  value: String,
) -> List(#(String, String)) {
  list.map(draft, fn(pair) {
    case pair.0 == key {
      True -> #(pair.0, value)
      False -> pair
    }
  })
}

/// Seed the draft from the saved response so that the editor shows the
/// server-side values, not the last local keystroke.
pub fn draft_from_response(response: OfficialResponse) -> List(#(String, String)) {
  list.map(response_requisites(), fn(pair) {
    let value = case pair.0 {
      "organization" -> response.organization
      "requisites" -> response.requisites
      "registration_number" -> response.registration_number
      "recipient" -> response.recipient
      "subject" -> response.subject
      "legal_basis" -> response.legal_basis
      "decision_summary" -> response.decision_summary
      "next_steps" -> response.next_steps
      "responsible_executor" -> response.responsible_executor
      "contact_for_questions" -> response.contact_for_questions
      "signature_block" -> response.signature_block
      _ -> ""
    }
    #(pair.0, value)
  })
}

/// Whether the feedback of a request has already been given.
pub fn has_feedback(feedback: Option(Feedback)) -> Bool {
  case feedback {
    Some(_) -> True
    None -> False
  }
}
