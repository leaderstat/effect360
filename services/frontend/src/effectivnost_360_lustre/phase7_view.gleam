// services/frontend/src/effectivnost_360_lustre/phase7_view.gleam
//
// The Phase-7 screens of «Эффективность 360» as pure view functions.
//
// The functions here take the already-loaded data and render it. They never
// mutate state and never perform I/O — all transport lives in
// `phase7_client.gleam` and all state transitions in `app.gleam`. That
// separation keeps the screens testable and keeps the trust boundary
// obvious: a screen can only show what the backend allowed it to receive.
//
// The module is generic over the message type, so the same screens can be
// reused with a different message set. Every click handler is passed in as
// a `fn(...) -> Msg` callback.
//
// The class names match the Sass design system in `services/frontend/styles`
// (`_layout.sass`, `_components.sass`, `_pages.sass`).

import effectivnost_360_lustre/phase7_client.{
  type ApplicantRequest, type Feedback, type Metric, type Notification,
  type OfficialResponse, type QueueItem, type RequestCard, type TimelineEvent,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// -------------------------------------------------------------
// Shared building blocks
// -------------------------------------------------------------

/// A status badge. The colour is derived from the server's status string —
/// the client does not invent a colour scale of its own.
pub fn status_badge(status: String, label: String) -> Element(msg) {
  html.span([attribute.class("badge " <> badge_variant(status))], [
    html.text(label),
  ])
}

fn badge_variant(status: String) -> String {
  case status {
    "draft" -> "badge--neutral"
    "submitted" -> "badge--info"
    "accepted" -> "badge--primary"
    "in_progress" -> "badge--primary"
    "returned" -> "badge--warning"
    "clarification_requested" -> "badge--warning"
    "answer_ready" -> "badge--success"
    "completed" -> "badge--success"
    "rejected" -> "badge--danger"
    "cancelled" -> "badge--neutral"
    _ -> "badge--neutral"
  }
}

/// An empty-state block. Used when a collection is legitimately empty — the
/// UI never substitutes a fake row for real data.
pub fn empty_state(title: String, description: String) -> Element(msg) {
  html.div([attribute.class("empty-state")], [
    html.p([attribute.class("empty-state__title")], [html.text(title)]),
    html.p([attribute.class("empty-state__description")], [
      html.text(description),
    ]),
  ])
}

/// A key/value pair for the definition lists.
pub fn kv(key: String, value: String) -> Element(msg) {
  html.div([attribute.class("kv")], [
    html.span([attribute.class("kv__key")], [html.text(key)]),
    html.span([attribute.class("kv__value")], [html.text(value)]),
  ])
}

/// Render an optional timestamp: the value or an em-dash placeholder.
pub fn kv_optional(key: String, value: Option(String)) -> Element(msg) {
  kv(key, option_or_dash(value))
}

pub fn option_or_dash(value: Option(String)) -> String {
  case value {
    Some(text) -> text
    None -> "—"
  }
}

// -------------------------------------------------------------
// Applicant cabinet
// -------------------------------------------------------------

/// The list of the applicant's own requests.
pub fn request_list(items: List(ApplicantRequest)) -> Element(msg) {
  case items {
    [] ->
      empty_state(
        "Заявок пока нет",
        "Опишите запрос на главной странице — он появится здесь после отправки.",
      )
    _ ->
      html.div([attribute.class("request-list")], [
        html.div([attribute.class("table-wrapper")], [
          html.table([attribute.class("table")], [
            html.thead([], [
              html.tr([], [
                html.th([], [html.text("Заявка")]),
                html.th([], [html.text("Тип")]),
                html.th([], [html.text("Статус")]),
                html.th([], [html.text("Отправлена")]),
              ]),
            ]),
            html.tbody(
              [],
              list.map(items, fn(item) { view_request_row(item) }),
            ),
          ]),
        ]),
      ])
  }
}

fn view_request_row(item: ApplicantRequest) -> Element(msg) {
  html.tr([], [
    html.td([], [
      html.a(
        [
          attribute.href("/request/" <> item.id),
          attribute.class("table__primary"),
        ],
        [html.text(short_id(item.id))],
      ),
    ]),
    html.td([], [html.text(item.request_type)]),
    html.td([], [status_badge(item.status, item.status_label)]),
    html.td([], [
      html.span([attribute.class("table__secondary")], [
        html.text(option_or_dash(item.submitted_at)),
      ]),
    ]),
  ])
}

// -------------------------------------------------------------
// Notifications
// -------------------------------------------------------------

/// The notification feed.
pub fn notification_feed(
  items: List(Notification),
  unread: Int,
  on_open: fn(String) -> msg,
  on_read: fn(String) -> msg,
) -> Element(msg) {
  case items {
    [] ->
      empty_state(
        "Уведомлений нет",
        "Здесь появятся сообщения о движении заявки по этапам.",
      )
    _ ->
      html.div([attribute.class("notification-feed")], [
        html.div([attribute.class("notification-feed__summary")], [
          html.span([], [html.text("Непрочитанных: " <> int.to_string(unread))]),
        ]),
        html.div(
          [attribute.class("notification-feed__items")],
          list.map(items, fn(item) {
            view_notification(item, on_open, on_read)
          }),
        ),
      ])
  }
}

fn view_notification(
  item: Notification,
  on_open: fn(String) -> msg,
  on_read: fn(String) -> msg,
) -> Element(msg) {
  let classes = case item.is_read {
    True -> "notification"
    False -> "notification notification--unread"
  }
  html.article([attribute.class(classes)], [
    html.div([attribute.class("notification__icon")], [
      html.text(notification_glyph(item.kind)),
    ]),
    html.div([attribute.class("notification__body")], [
      html.p([attribute.class("notification__title")], [html.text(item.title)]),
      html.p([attribute.class("notification__message")], [html.text(item.body)]),
      html.p([attribute.class("notification__time")], [html.text(item.created_at)]),
    ]),
    html.div([attribute.class("notification__actions")], [
      view_notification_open(item.request_id, on_open),
      view_notification_read(item, on_read),
    ]),
  ])
}

fn view_notification_open(
  request_id: String,
  on_open: fn(String) -> msg,
) -> Element(msg) {
  case request_id {
    "" -> html.span([], [])
    _ ->
      html.button(
        [
          attribute.class("btn btn--ghost btn--sm"),
          attribute.data("action", "open-request"),
          attribute.data("request-id", request_id),
          event.on_click(on_open(request_id)),
        ],
        [html.text("Открыть заявку")],
      )
  }
}

fn view_notification_read(
  item: Notification,
  on_read: fn(String) -> msg,
) -> Element(msg) {
  case item.is_read {
    True -> html.span([], [])
    False ->
      html.button(
        [
          attribute.class("btn btn--secondary btn--sm"),
          attribute.data("action", "read-notification"),
          attribute.data("notification-id", item.id),
          event.on_click(on_read(item.id)),
        ],
        [html.text("Прочитано")],
      )
  }
}

fn notification_glyph(kind: String) -> String {
  case kind {
    "request_accepted" -> "✓"
    "clarification_requested" -> "?"
    "answer_ready" -> "!"
    "completed" -> "★"
    "response_approved" -> "✉"
    _ -> "•"
  }
}

// -------------------------------------------------------------
// Stepper — the visible lifecycle
// -------------------------------------------------------------

/// The lifecycle of the request as a stepper.
///
/// The steps are the domain statuses of `state_machine.gleam`; the current
/// step is derived from the status the server sent. No step is ever marked
/// as done that the server has not recorded.
pub fn stepper(status: String) -> Element(msg) {
  let steps = [
    #("Создана", "draft"),
    #("Отправлена", "submitted"),
    #("Принята", "accepted"),
    #("В работе", "in_progress"),
    #("Уточнение", "clarification_requested"),
    #("Ответ готов", "answer_ready"),
    #("Завершена", "completed"),
  ]
  let current = step_index(status)
  html.ol([attribute.class("stepper")], [
    html.li(
      [attribute.class("stepper__item")],
      list.map(steps, fn(step) { view_step(step, current) }),
    ),
  ])
}

fn view_step(step: #(String, String), current: Int) -> Element(msg) {
  let index = step_index(step.1)
  let classes = case index < current {
    True -> "stepper__step stepper__step--done"
    False ->
      case index == current {
        True -> "stepper__step stepper__step--current"
        False -> "stepper__step"
      }
  }
  html.li([attribute.class(classes)], [
    html.span([attribute.class("stepper__index")], [
      html.text(int.to_string(index + 1)),
    ]),
    html.span([attribute.class("stepper__label")], [html.text(step.0)]),
  ])
}

/// The index of a status in the lifecycle, or -1 when the status is outside
/// the visible lifecycle (for example `rejected`).
fn step_index(status: String) -> Int {
  case status {
    "draft" -> 0
    "submitted" -> 1
    "accepted" -> 2
    "in_progress" -> 3
    "clarification_requested" -> 4
    "returned" -> 4
    "answer_ready" -> 5
    "completed" -> 6
    _ -> -1
  }
}

// -------------------------------------------------------------
// Timeline
// -------------------------------------------------------------

/// The history of the request as a vertical timeline.
pub fn timeline(events: List(TimelineEvent)) -> Element(msg) {
  case events {
    [] ->
      empty_state(
        "История пуста",
        "События появятся здесь после первого действия модератора.",
      )
    _ ->
      html.ol([attribute.class("timeline")], [
        html.li([], [
          html.ol(
            [attribute.class("timeline__list")],
            list.map(events, fn(event) { view_timeline_event(event) }),
          ),
        ]),
      ])
  }
}

fn view_timeline_event(event: TimelineEvent) -> Element(msg) {
  html.div([attribute.class("timeline__content")], [
    html.div([attribute.class("timeline__marker-wrap")], [
      html.span(
        [attribute.class("timeline__marker " <> marker_variant(event.to_status))],
        [html.text("")],
      ),
    ]),
    html.div([attribute.class("timeline__body")], [
      html.p([attribute.class("timeline__title")], [
        html.text(event.to_status_label),
      ]),
      html.p([attribute.class("timeline__meta")], [
        html.text(
          event.created_at
            <> " · "
            <> actor_label(event.actor_role, event.actor_name),
        ),
      ]),
      view_timeline_reason(event.reason_code),
    ]),
  ])
}

fn view_timeline_reason(reason_code: String) -> Element(msg) {
  case reason_code {
    "" -> html.span([], [])
    _ ->
      html.p([attribute.class("timeline__body-text")], [html.text(reason_code)])
  }
}

fn marker_variant(status: String) -> String {
  case status {
    "completed" -> "timeline__marker--success"
    "clarification_requested" -> "timeline__marker--warning"
    "returned" -> "timeline__marker--warning"
    "answer_ready" -> "timeline__marker--accent"
    _ -> "timeline__marker"
  }
}

fn actor_label(role: String, name: String) -> String {
  case role {
    "moderator" ->
      case name {
        "" -> "Модератор"
        _ -> "Модератор: " <> name
      }
    "applicant" ->
      case name {
        "" -> "Заявитель"
        _ -> "Заявитель: " <> name
      }
    "system" -> "Система"
    "" -> name
    _ -> role
  }
}

// -------------------------------------------------------------
// Request card
// -------------------------------------------------------------

/// The card of a request: the applicant data, the filled fields, the history
/// and the moderation actions.
pub fn request_card(
  card: RequestCard,
  on_transition: fn(String, String) -> msg,
) -> Element(msg) {
  html.section([attribute.class("request-card")], [
    view_card_header(card),
    view_card_facts(card),
    view_card_fields(card),
    view_card_actions(card, on_transition),
  ])
}

fn view_card_header(card: RequestCard) -> Element(msg) {
  html.div([attribute.class("request-card__section")], [
    html.div([attribute.class("request-card__heading")], [
      html.h2([], [html.text("Заявка " <> short_id(card.id))]),
      status_badge(card.status, card.status_label),
    ]),
    html.div([attribute.class("kv-list")], [
      kv("Заявитель", card.applicant_name),
      kv("Тип заявки", card.request_type),
      kv("Создана", card.created_at),
      kv_optional("Отправлена", card.submitted_at),
      kv_optional("Принята в работу", card.accepted_at),
      kv_optional("Ответ подготовлен", card.answer_ready_at),
      kv_optional("Завершена", card.completed_at),
      kv_optional("Срок", card.due_at),
    ]),
  ])
}

fn view_card_facts(card: RequestCard) -> Element(msg) {
  case card.clarification_note {
    "" -> view_card_applicant_note(card)
    _ ->
      html.div([attribute.class("request-card__section")], [
        html.h3([attribute.class("request-card__heading")], [
          html.text("Запрошено уточнение"),
        ]),
        html.p([attribute.class("request-card__text")], [
          html.text(card.clarification_note),
        ]),
      ])
  }
}

fn view_card_applicant_note(card: RequestCard) -> Element(msg) {
  case card.applicant_note {
    "" -> html.span([], [])
    _ ->
      html.div([attribute.class("request-card__section")], [
        html.h3([attribute.class("request-card__heading")], [
          html.text("Ответ заявителя"),
        ]),
        html.p([attribute.class("request-card__text")], [
          html.text(card.applicant_note),
        ]),
      ])
  }
}

fn view_card_fields(card: RequestCard) -> Element(msg) {
  let pairs = dict.to_list(card.fields)
  case pairs {
    [] -> html.span([], [])
    _ ->
      html.div([attribute.class("request-card__section")], [
        html.h3([attribute.class("request-card__heading")], [
          html.text("Заполненные поля"),
        ]),
        html.div([attribute.class("kv-list")], [
          html.div(
            [attribute.class("kv-list__grid")],
            list.map(pairs, fn(pair) { kv(pair.0, pair.1) }),
          ),
        ]),
      ])
  }
}

fn view_card_actions(
  card: RequestCard,
  on_transition: fn(String, String) -> msg,
) -> Element(msg) {
  case card.available_actions {
    [] -> html.span([], [])
    _ ->
      html.div([attribute.class("request-card__section")], [
        html.h3([attribute.class("request-card__heading")], [html.text("Действия")]),
        html.div([attribute.class("btn-group")], [
          html.div(
            [attribute.class("btn-group")],
            list.map(card.available_actions, fn(action) {
              view_action_button(action, card.id, on_transition)
            }),
          ),
        ]),
      ])
  }
}

fn view_action_button(
  action: String,
  request_id: String,
  on_transition: fn(String, String) -> msg,
) -> Element(msg) {
  html.button(
    [
      attribute.class(action_variant(action)),
      attribute.data("action", action),
      attribute.data("request-id", request_id),
      event.on_click(on_transition(action, request_id)),
    ],
    [html.text(action_label(action))],
  )
}

fn action_variant(action: String) -> String {
  case action {
    "accept" -> "btn btn--primary"
    "start" -> "btn btn--primary"
    "request_clarification" -> "btn btn--warning"
    "answer_ready" -> "btn btn--secondary"
    "complete" -> "btn btn--success"
    _ -> "btn btn--secondary"
  }
}

fn action_label(action: String) -> String {
  case action {
    "accept" -> "Принять в работу"
    "start" -> "Назначить исполнителя"
    "request_clarification" -> "Запросить уточнение"
    "applicant_answered" -> "Принять ответ заявителя"
    "answer_ready" -> "Подготовить ответ"
    "complete" -> "Завершить рассмотрение"
    _ -> action
  }
}

// -------------------------------------------------------------
// Moderator queue
// -------------------------------------------------------------

/// The moderator queue.
pub fn queue(items: List(QueueItem), total: Int) -> Element(msg) {
  case items {
    [] ->
      empty_state(
        "Очередь пуста",
        "Нет заявок, удовлетворяющих выбранным фильтрам.",
      )
    _ ->
      html.div([attribute.class("queue__list")], [
        html.p([attribute.class("queue__summary")], [
          html.text("Всего в выборке: " <> int.to_string(total)),
        ]),
        html.div([], list.map(items, fn(item) { view_queue_item(item) })),
      ])
  }
}

fn view_queue_item(item: QueueItem) -> Element(msg) {
  let classes = case item.is_overdue {
    True -> "queue-item queue-item--overdue"
    False -> "queue-item queue-item--" <> item.status
  }
  html.article([attribute.class(classes)], [
    html.header([attribute.class("queue-item__header")], [
      html.div([], [
        html.h3([attribute.class("queue-item__title")], [
          html.a(
            [attribute.href("/request/" <> item.id <> "/detail")],
            [html.text(short_id(item.id))],
          ),
        ]),
        html.p([attribute.class("queue-item__meta")], [
          html.text(
            item.applicant_name
              <> " · "
              <> item.request_type
              <> " · "
              <> item.created_at,
          ),
        ]),
      ]),
      html.div([attribute.class("queue-item__side")], [
        status_badge(item.status, item.status_label),
        view_overdue_badge(item.is_overdue),
      ]),
    ]),
    html.div([attribute.class("queue-item__fields")], [
      kv_optional("Срок", non_empty(item.due_at)),
      kv("Ответственный", item.assignee_name),
    ]),
    view_queue_note(item.clarification_note),
  ])
}

fn view_overdue_badge(is_overdue: Bool) -> Element(msg) {
  case is_overdue {
    True ->
      html.span([attribute.class("badge badge--danger")], [html.text("Просрочена")])
    False -> html.span([], [])
  }
}

fn view_queue_note(note: String) -> Element(msg) {
  case note {
    "" -> html.span([], [])
    _ -> html.p([attribute.class("queue-item__note")], [html.text(note)])
  }
}

fn non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

// -------------------------------------------------------------
// Metrics
// -------------------------------------------------------------

/// The efficiency-360 metrics.
///
/// A metric without a value is rendered as «Недостаточно данных» — the UI
/// never invents a percentage.
pub fn metrics(items: List(Metric)) -> Element(msg) {
  case items {
    [] ->
      empty_state(
        "Метрики недоступны",
        "Сервер не вернул данных для расчёта показателей.",
      )
    _ ->
      html.div([attribute.class("grid grid--metrics")], [
        html.div([], list.map(items, fn(metric) { view_metric(metric) })),
      ])
  }
}

fn view_metric(metric: Metric) -> Element(msg) {
  let classes = case metric.value {
    Some(_) -> "metric-tile"
    None -> "metric-tile metric-tile--empty"
  }
  html.article([attribute.class(classes)], [
    html.p([attribute.class("metric-tile__label")], [html.text(metric.label)]),
    html.p([attribute.class("metric-tile__value")], [
      html.text(metric_text(metric)),
    ]),
    view_metric_unit(metric.unit),
    view_metric_demo(metric.is_demo),
  ])
}

fn view_metric_unit(unit: String) -> Element(msg) {
  case unit {
    "" -> html.span([], [])
    _ -> html.p([attribute.class("metric-tile__unit")], [html.text(unit)])
  }
}

fn view_metric_demo(is_demo: Bool) -> Element(msg) {
  case is_demo {
    True ->
      html.span([attribute.class("badge badge--warning metric-tile__demo")], [
        html.text("DEMO"),
      ])
    False -> html.span([], [])
  }
}

fn metric_text(metric: Metric) -> String {
  case metric.value {
    Some(value) ->
      case metric.unit {
        "%" -> format_float(value) <> "%"
        "чел." -> int.to_string(round_to_int(value))
        "дн." -> format_float(value)
        _ -> format_float(value) <> " " <> metric.unit
      }
    None -> "Недостаточно данных"
  }
}

/// Format a float with at most one decimal place, without a trailing .0.
fn format_float(value: Float) -> String {
  let negative = value <. 0.0
  let absolute = case negative {
    True -> 0.0 -. value
    False -> value
  }
  let tenths = float.round(absolute *. 10.0)
  let whole = tenths / 10
  let fraction = tenths % 10
  let text = case fraction {
    0 -> int.to_string(whole)
    _ -> int.to_string(whole) <> "," <> int.to_string(fraction)
  }
  case negative {
    True -> "-" <> text
    False -> text
  }
}

/// Round a float to the nearest integer.
fn round_to_int(value: Float) -> Int {
  let negative = value <. 0.0
  let absolute = case negative {
    True -> 0.0 -. value
    False -> value
  }
  let rounded = float.round(absolute)
  case negative {
    True -> -rounded
    False -> rounded
  }
}

// -------------------------------------------------------------
// Official response
// -------------------------------------------------------------

/// The official response: the letter itself plus the requisites check.
pub fn official_response(
  response: OfficialResponse,
  is_approved: Bool,
) -> Element(msg) {
  html.section([attribute.class("official-response")], [
    html.header([attribute.class("official-response__header")], [
      html.div([], [
        html.p([attribute.class("official-response__org")], [
          html.text(response.organization),
        ]),
        html.p([attribute.class("official-response__requisites")], [
          html.text(response.requisites),
        ]),
      ]),
      html.div([], [view_response_status_badge(is_approved)]),
    ]),
    html.div([attribute.class("official-response__meta")], [
      kv("Регистрационный номер", response.registration_number),
      kv("Дата", response.created_at),
    ]),
    html.div([attribute.class("official-response__recipient")], [
      html.p([], [html.text(response.recipient)]),
    ]),
    html.div([attribute.class("official-response__subject")], [
      html.strong([], [html.text(response.subject)]),
    ]),
    html.div([attribute.class("official-response__body")], [
      html.p([], [html.text(response.legal_basis)]),
      html.p([], [html.text(response.decision_summary)]),
      html.p([], [html.text(response.next_steps)]),
      html.p([], [html.text(response.contact_for_questions)]),
    ]),
    html.div([attribute.class("official-response__signature")], [
      html.p([], [html.text(response.responsible_executor)]),
      html.p([], [html.text(response.signature_block)]),
    ]),
    requisite_check(response.missing_requisites),
  ])
}

fn view_response_status_badge(is_approved: Bool) -> Element(msg) {
  case is_approved {
    True ->
      html.span(
        [attribute.class("badge badge--success official-response__approved-badge")],
        [html.text("Утверждён")],
      )
    False ->
      html.span(
        [attribute.class("badge badge--warning official-response__draft-badge")],
        [html.text("Проект, не подписан")],
      )
  }
}

/// The list of the requisites that are still missing. An empty list means
/// every required requisite is filled in.
pub fn requisite_check(missing: List(String)) -> Element(msg) {
  case missing {
    [] -> view_requisites_complete()
    _ -> view_requisites_missing(missing)
  }
}

fn view_requisites_complete() -> Element(msg) {
  html.div([attribute.class("requisite-check")], [
    html.p(
      [
        attribute.class(
          "requisite-check__item requisite-check__item--filled",
        ),
      ],
      [
        html.span([attribute.class("requisite-check__mark")], [html.text("✓")]),
        html.text("Все обязательные реквизиты заполнены"),
      ],
    ),
  ])
}

fn view_requisites_missing(missing: List(String)) -> Element(msg) {
  let items = list.map(missing, fn(item) {
    html.li(
      [
        attribute.class(
          "requisite-check__item requisite-check__item--missing",
        ),
      ],
      [
        html.span([attribute.class("requisite-check__mark")], [html.text("!")]),
        html.text(item),
      ],
    )
  })
  html.div([attribute.class("requisite-check")], [
    html.p([attribute.class("requisite-check__title")], [
      html.text("Не заполнены обязательные реквизиты:"),
    ]),
    html.ul([], items),
  ])
}

// -------------------------------------------------------------
// Result card — the 360 summary for the applicant
// -------------------------------------------------------------

/// The result card: what was decided, what happens next, the deadlines,
/// the grounds, the owner and the history.
pub fn result_card(
  card: RequestCard,
  response: Option(OfficialResponse),
) -> Element(msg) {
  html.section([attribute.class("result-card")], [
    html.h2([attribute.class("result-card__title")], [html.text("Ваш результат")]),
    html.div([attribute.class("result-card__section")], [
      html.h3([attribute.class("result-card__heading")], [
        html.text("Что решено и почему"),
      ]),
      html.p([attribute.class("result-card__text")], [
        html.text(result_summary(card, response)),
      ]),
    ]),
    html.div([attribute.class("result-card__section")], [
      html.h3([attribute.class("result-card__heading")], [html.text("Что дальше")]),
      html.p([attribute.class("result-card__text")], [
        html.text(result_next_steps(response)),
      ]),
    ]),
    html.div([attribute.class("result-card__section")], [
      html.h3([attribute.class("result-card__heading")], [html.text("Сроки")]),
      html.div([attribute.class("kv-list")], [
        kv_optional("Принята в работу", card.accepted_at),
        kv_optional("Ответ подготовлен", card.answer_ready_at),
        kv_optional("Завершена", card.completed_at),
        kv_optional("Срок по заявке", card.due_at),
      ]),
    ]),
    html.div([attribute.class("result-card__section")], [
      html.h3([attribute.class("result-card__heading")], [html.text("Основания")]),
      html.p([attribute.class("result-card__text")], [
        html.text(result_legal_basis(response)),
      ]),
    ]),
    html.div([attribute.class("result-card__section")], [
      html.h3([attribute.class("result-card__heading")], [
        html.text("Ответственный"),
      ]),
      html.p([attribute.class("result-card__text")], [
        html.text(result_owner(response)),
      ]),
    ]),
    html.div([attribute.class("result-card__section")], [
      html.h3([attribute.class("result-card__heading")], [html.text("История")]),
      html.div([attribute.class("result-card__links")], [
        html.a(
          [attribute.href("/request/" <> card.id <> "/history")],
          [html.text("История заявки по этапам")],
        ),
      ]),
    ]),
  ])
}

fn result_summary(card: RequestCard, response: Option(OfficialResponse)) -> String {
  case response {
    Some(r) ->
      case r.decision_summary {
        "" -> card.status_label
        _ -> r.decision_summary
      }
    None -> card.status_label
  }
}

fn result_next_steps(response: Option(OfficialResponse)) -> String {
  case response {
    Some(r) ->
      case r.next_steps {
        "" -> "Дополнительные действия не указаны."
        _ -> r.next_steps
      }
    None -> "Ответ ещё не подготовлен."
  }
}

fn result_legal_basis(response: Option(OfficialResponse)) -> String {
  case response {
    Some(r) ->
      case r.legal_basis {
        "" -> "Основание рассмотрения будет указано в официальном ответе."
        _ -> r.legal_basis
      }
    None -> "Основание рассмотрения будет указано в официальном ответе."
  }
}

fn result_owner(response: Option(OfficialResponse)) -> String {
  case response {
    Some(r) ->
      case r.responsible_executor {
        "" -> "Ответственный будет указан в официальном ответе."
        _ -> r.responsible_executor
      }
    None -> "Ответственный будет указан в официальном ответе."
  }
}

// -------------------------------------------------------------
// Feedback
// -------------------------------------------------------------

/// The applicant feedback widget.
///
/// The feedback is about the CLARITY of the answer. It is deliberately
/// separate from the legal status of the request — rating the answer never
/// closes or reopens the case.
pub fn feedback(
  existing: Option(Feedback),
  on_rate: fn(Bool) -> msg,
) -> Element(msg) {
  case existing {
    Some(f) -> view_feedback_thanks(f)
    None -> view_feedback_options(on_rate)
  }
}

fn view_feedback_thanks(f: Feedback) -> Element(msg) {
  html.div([attribute.class("feedback")], [
    html.p([attribute.class("feedback__thanks")], [
      html.text(
        case f.is_clear {
          True -> "Спасибо: вы отметили, что ответ понятен."
          False -> "Спасибо: вы отметили, что ответ требует уточнения."
        },
      ),
    ]),
    view_feedback_comment(f.comment),
  ])
}

fn view_feedback_comment(comment: String) -> Element(msg) {
  case comment {
    "" -> html.span([], [])
    _ -> html.p([attribute.class("feedback__note")], [html.text(comment)])
  }
}

fn view_feedback_options(on_rate: fn(Bool) -> msg) -> Element(msg) {
  html.div([attribute.class("feedback")], [
    html.p([attribute.class("feedback__title")], [
      html.text("Понятен ли вам ответ?"),
    ]),
    html.div([attribute.class("feedback__scale")], [
      view_feedback_option(True, "Да, понятен", on_rate),
      view_feedback_option(False, "Нужно уточнить", on_rate),
    ]),
  ])
}

fn view_feedback_option(
  is_clear: Bool,
  label: String,
  on_rate: fn(Bool) -> msg,
) -> Element(msg) {
  html.button(
    [
      attribute.class("feedback__option"),
      attribute.data(
        "action",
        case is_clear {
          True -> "feedback-clear"
          False -> "feedback-unclear"
        },
      ),
      event.on_click(on_rate(is_clear)),
    ],
    [
      html.span([attribute.class("feedback__option__emoji")], [
        html.text(
          case is_clear {
            True -> "👍"
            False -> "👎"
          },
        ),
      ]),
      html.text(label),
    ],
  )
}

// -------------------------------------------------------------
// Helpers
// -------------------------------------------------------------

/// A short, readable form of a UUID: the first 8 characters.
pub fn short_id(id: String) -> String {
  string.slice(id, 0, 8)
}
