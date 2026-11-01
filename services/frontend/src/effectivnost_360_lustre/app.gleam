// services/frontend/src/effectivnost_360_lustre/app.gleam
//
// Lustre application for the applicant journey of «Эффективность 360».
//
// CJM → screens: docs/architecture/cjm-screen-map.md
//
//   S0  /              Старт      — назначение сервиса, одна точка входа
//   S1  /describe      Описание   — свободный текст → черновик
//   S2  /request/{id}  Уточнения  — извлечённые поля + недостающее + основание
//   S4  /request/{id}  Результат  — заявка принята (тот же маршрут)
//
// Transport: every HTTP call goes through `api_client` (relative paths) and
// is wrapped into a Lustre `Effect` with `effect.from`, which is the only
// supported way to write a custom effect in Lustre 5.x.
//
// Trust boundary: the server owns the requirements. The client shows the
// `missing[]` array it receives from the server verbatim, including the
// `clause_id` and the literal `quote`. The client never invents a clause or
// a quote, and it never reports success unless the server returned 200.

import gleam/dict
import gleam/result
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, map}
import lustre/element/html
import lustre/event

import effectivnost_360_lustre/api_client.{
  type HardStopField, type MissingField, type Request, type SubmitOutcome,
  create_draft, load_request, random_key, status_to_string, submit_request,
  Submitted, SubmitAlreadyDone, SubmitBlocked, SubmitConflict, SubmitIncomplete,
  SubmitInvalid, SubmitNotFound, SubmitServerError, SubmitSucceeded,
}
import effectivnost_360_lustre/fields.{
  type FieldSpec, field_specs, locally_missing,
}
import effectivnost_360_lustre/screen.{
  type Route, type Screen, parse_route, path_for_new_request, screen_title,
  step_number,
} as screen_map
import effectivnost_360_lustre/phase7_client.{
  type ApplicantRequest, type Metric, type Notification, type OfficialResponse,
  type Queue,     type RequestCard, type TransitionOutcome, FeedbackMissing, FeedbackStored,
    Notification, apply_transition, approve_response, load_metrics,
    load_my_requests, load_notifications, load_queue, load_request_card,
    load_session, login, mark_notification_read, save_response_draft,
    submit_clarification, submit_feedback,
  }
import effectivnost_360_lustre/phase7_state.{
  type Bell, type Cabinet, type CardState, type MetricsState, type QueueState,
  type ResponseState, type Session, Bell, Cabinet, CardState, MetricsState,
  QueueState, ResponseState, Session, draft_from_response, draft_set,
  draft_value, empty_bell, empty_cabinet, empty_card, empty_metrics,
  empty_queue, empty_response, response_requisites, transition_notice,
}
import effectivnost_360_lustre/phase7_view.{
  feedback, metrics, notification_feed, official_response, queue, request_card,
  request_list, stepper, timeline,
}
import effectivnost_360_lustre/phase8_client as phase8_client
import effectivnost_360_lustre/phase8_state as automation_state
import effectivnost_360_lustre/phase8_view as phase8_view

// -------------------------------------------------------------
// Model
// -------------------------------------------------------------

pub type Model {
  Model(
    /// The route the current page represents.
    route: Route,
    /// The screen derived from `route`.
    screen: Screen,
    /// S1 input: the free-text description.
    text: String,
    /// The idempotency key used for the next draft creation.
    idempotency_key: String,
    /// The request currently being worked on (S2/S4).
    request: Option(Request),
    /// The values currently shown in the form. Seeded from the server's
  /// `fields` and updated as the user types.
    values: dict.Dict(String, String),
    /// The authoritative `missing[]` from the server (422 response).
    server_missing: List(MissingField),
    /// The blocking rules from the server (422 response, `hard_stop`).
    /// A hard stop is not a missing field: the value is filled in and
    /// forbidden by a regulation, so the submission is rejected.
    server_hard_stops: List(HardStopField),
    /// The last submit outcome.
    outcome: Option(SubmitOutcome),
    /// A transport/validation error to display.
    error_text: Option(String),
    /// Whether a request is in flight.
    busy: Bool,
    /// S0 maturity sliders: dimension name (1..5).
    maturity_inputs: dict.Dict(String, Int),
    /// S0 FAQ widget draft text.
    faq_draft: String,
    /// S0 FAQ widget sent flag.
    faq_sent: Bool,
    /// ---- Phase 7: the closed CJM 360 loop ----
    /// The session of the current user (`None` = not loaded).
    session: Option(Session),
    /// The applicant cabinet: the user's own requests.
    cabinet: Cabinet,
    /// The notification bell of the applicant.
    bell: Bell,
    /// The moderator queue and its filters.
    queue_state: QueueState,
    /// The request card (applicant or moderator view).
    card_state: CardState,
    /// The official response editor.
    response_state: ResponseState,
    /// The efficiency-360 metrics.
    metrics_state: MetricsState,
    /// The login form (Phase 7 screens require a session).
    login_email: String,
    login_password: String,
    login_error: Option(String),
    // ---- Phase 8: панель автоматизации ----
    /// Сводное состояние панели автоматизации.
    automation_state: automation_state.AutomationState,
    /// Состояние экрана «Цифровой модератор».
    agent_checks_state: automation_state.AgentChecksState,
    /// Состояние экрана «Очередь исключений».
    exceptions_state: automation_state.ExceptionsState,
    /// Состояние экрана «Журнал автоматических действий».
    journal_state: automation_state.JournalState,
    /// Состояние экрана «Настройки режима».
    settings_state: automation_state.SettingsState,
    /// Выбранный режим для сохранения (PUT /api/v1/automation/settings).
    pending_mode: String,
  )
}

/// Initial values for the maturity sliders on the corporate landing page.
/// Real product does not compute organisational analytics — see
/// view_maturity for the transparent formula.
fn default_maturity() -> dict.Dict(String, Int) {
  dict.from_list([
    #("completeness", 3),
    #("returns", 3),
    #("speed", 3),
  ])
}

pub type Msg {
  /// S1: the user typed the free-text description.
  TextChanged(String)
  /// S1: submit the description → create a draft.
  CreateDraft
  /// The draft was created (or the request failed).
  DraftCreated(Result(String, String))
  /// The request was loaded from the server.
  RequestLoaded(Result(Request, String))
  /// S2: the user edited a field.
  FieldEdited(String, String)
  /// S2: submit the request.
  SubmitRequest
  /// The submit call returned.
  SubmitFinished(Result(SubmitOutcome, String))
  /// Navigation to another path.
  Navigate(String)
  /// S0: user moved a maturity slider.
  MaturityChanged(String, Int)
  /// S0: user typed into the FAQ widget.
  FaqChanged(String)
  /// S0: user submitted the FAQ widget.
  FaqSubmitted
  // ---- Phase 7 ----
  /// The login form: the user typed an e-mail.
  LoginEmailChanged(String)
  /// The login form: the user typed a password.
  LoginPasswordChanged(String)
  /// The login form was submitted.
  LoginSubmitted
  /// The session was created (or the login failed).
  LoginFinished(Result(String, String))
  /// The session profile was loaded.
  SessionLoaded(Result(#(String, String, String), String))
  /// The applicant's own requests were loaded.
  MyRequestsLoaded(Result(List(ApplicantRequest), String))
  /// The notification feed was loaded.
  NotificationsLoaded(Result(#(List(Notification), Int), String))
  /// A notification was marked as read.
  NotificationRead(String)
  /// The request card was loaded.
  CardLoaded(Result(RequestCard, String))
  /// The moderator queue was loaded.
  QueueLoaded(Result(Queue, String))
  /// The queue filter by status changed.
  QueueStatusFilterChanged(String)
  /// The queue filter by request type changed.
  QueueTypeFilterChanged(String)
  /// The "overdue only" filter toggled.
  QueueOverdueToggled
  /// A moderation action was requested.
  TransitionRequested(String, String)
  /// The moderation action returned.
  TransitionFinished(String, Result(TransitionOutcome, String))
  /// The moderator typed a note before a transition.
  CardNoteChanged(String)
  /// The applicant typed an answer to the clarification request.
  CardAnswerChanged(String)
  /// The applicant submitted the answer.
  ClarificationSubmitted(String)
  /// The applicant submitted the answer; the server answered.
  ClarificationFinished(Result(Nil, String))
  /// The response editor: a requisite was edited.
  ResponseFieldChanged(String, String)
  /// The moderator asked to save the response draft.
  SaveResponseRequested(String)
  /// The moderator asked to approve the response.
  ApproveResponseRequested(String)
  /// The response draft was saved.
  ResponseSaved(Result(OfficialResponse, String))
  /// The response was approved.
  ResponseApproved(Result(OfficialResponse, String))
  /// The response editor: the preview was toggled.
  ResponsePreviewToggled
  /// The applicant rated the answer.
  FeedbackSubmitted(String, Bool)
  /// The feedback was stored.
  FeedbackFinished(String, Result(#(Bool, String), String))
  /// The metrics were loaded.
  MetricsLoaded(Result(List(Metric), String))
  // ---- Phase 8: панель автоматизации ----
  /// Загружена сводка панели (mode, settings, checks, exceptions, actions).
  AutomationPanelLoaded(Result(phase8_client.AutomationPanel, String))
  /// Загружены настройки автоматизации.
  AutomationSettingsLoaded(Result(phase8_client.AutomationSettings, String))
  /// Загружены метрики эффективности 360.
  EfficiencyMetricsLoaded(Result(List(phase8_client.EfficiencyMetric), String))
  /// Загружены только проверки цифрового модератора.
  AgentChecksLoaded(Result(List(phase8_client.AgentCheck), String))
  /// Загружена очередь исключений.
  ExceptionsLoaded(Result(List(phase8_client.AgentException), String))
  /// Загружен журнал автоматических действий.
  JournalLoaded(Result(List(phase8_client.AutomationAction), String))
  /// Выбран новый режим (только в UI, ещё не сохранён).
  AutomationModeSelected(String)
  /// Запрос на сохранение режима.
  AutomationModeSaveRequested
  /// Режим сохранён на сервере.
  AutomationModeSaved(Result(phase8_client.AutomationSettings, String))
  /// Запрошена повторная проверка для конкретной заявки.
  AgentRecheckRequested(String)
  /// Результат повторной проверки (строка — ok/err).
  AgentRecheckFinished(String, Result(String, String))
  /// Изменён фильтр цифрового модератора по результату.
  AgentFilterChanged(String)
  /// Запрошено разрешение исключения.
  ExceptionResolveRequested(String)
  /// Исключение разрешено на сервере.
  ExceptionResolveFinished(String, Result(String, String))
  /// Изменён фильтр журнала по режиму.
  JournalFilterChanged(String)
  /// Глобальное обновление панели (нажатие кнопки «Обновить»).
  AutomationRefreshRequested
}

// -------------------------------------------------------------
// Init
// -------------------------------------------------------------

pub fn init(flags) -> #(Model, Effect(Msg)) {
  let path = current_path(flags)
  let route = parse_route(path)
  let screen = route.screen
  let model =
    Model(
      route: route,
      screen: screen,
      text: "",
      idempotency_key: random_key(),
      request: None,
      values: dict.new(),
      server_missing: [],
      server_hard_stops: [],
      outcome: None,
      error_text: None,
      busy: False,
      maturity_inputs: default_maturity(),
      faq_draft: "",
      faq_sent: False,
      session: None,
      cabinet: empty_cabinet(),
      bell: empty_bell(),
      queue_state: empty_queue(),
      card_state: empty_card(),
      response_state: empty_response(),
      metrics_state: empty_metrics(),
      login_email: "",
      login_password: "",
      login_error: None,
      automation_state: automation_state.empty_automation(),
      agent_checks_state: automation_state.empty_agent_checks(),
      exceptions_state: automation_state.empty_exceptions(),
      journal_state: automation_state.empty_journal(),
      settings_state: automation_state.empty_settings_state(),
      pending_mode: "",
    )
  // On a request screen we must load the state from the server — after F5
  // the browser must restore the request, not show an empty form.
  case screen {
    screen_map.Clarify(id) | screen_map.Result(id) -> {
      let fx = load_request_effect(id)
      #(Model(..model, busy: True), fx)
    }
    screen_map.Start | screen_map.Describe -> #(model, effect.none())
    _ -> {
      // Phase-7 screens: load the session first; the data of the screen is
      // loaded after the session is confirmed.
      let fx = load_session_effect()
      #(Model(..model, busy: True), fx)
    }
  }
}

// -------------------------------------------------------------
// Update
// -------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TextChanged(text) -> #(Model(..model, text: text), effect.none())
    CreateDraft -> {
      case string.trim(model.text) {
        "" ->
          #(
            Model(..model, error_text: Some("Опишите запрос текстом.")),
            effect.none(),
          )
        _ -> {
          let fx = create_draft_effect(model.text, model.idempotency_key)
          #(Model(..model, busy: True, error_text: None), fx)
        }
      }
    }
    DraftCreated(Ok(request_id)) -> {
      // Navigate to the request screen. The route change is a server-side
      // navigation so that F5 restores the same request.
      let fx = navigate_effect(path_for_new_request(request_id))
      #(
        Model(
          ..model,
          busy: False,
          error_text: None,
          idempotency_key: random_key(),
        ),
        fx,
      )
    }
    DraftCreated(Error(reason)) -> #(
      Model(..model, busy: False, error_text: Some(reason)),
      effect.none(),
    )
    RequestLoaded(Ok(request)) -> {
      let values = merge_values(request.fields, model.values)
      let next_screen = case request.status {
        Submitted -> screen_map.Result(request.id)
        _ -> screen_map.Clarify(request.id)
      }
      #(
        Model(
          ..model,
          request: Some(request),
          values: values,
          screen: next_screen,
          busy: False,
          error_text: None,
        ),
        effect.none(),
      )
    }
    RequestLoaded(Error(reason)) -> #(
      Model(..model, busy: False, error_text: Some(reason)),
      effect.none(),
    )
    FieldEdited(name, value) -> {
      let values = dict.insert(model.values, name, value)
      #(Model(..model, values: values), effect.none())
    }
    SubmitRequest -> {
      case model.request {
        None -> #(
          Model(..model, error_text: Some("Сначала откройте заявку.")),
          effect.none(),
        )
        Some(request) -> {
          let fx = submit_request_effect(request.id)
          #(Model(..model, busy: True, error_text: None, outcome: None), fx)
        }
      }
    }
    SubmitFinished(Ok(outcome)) -> {
      // Refresh the request from the server so the status is authoritative.
      let refresh = case model.request {
        Some(request) -> load_request_effect(request.id)
        None -> effect.none()
      }
      let model =
        case outcome {
          SubmitIncomplete(items) ->
            Model(
              ..model,
              server_missing: items,
              server_hard_stops: [],
              outcome: Some(outcome),
            )
          SubmitBlocked(hits) ->
            Model(
              ..model,
              server_missing: [],
              server_hard_stops: hits,
              outcome: Some(outcome),
            )
          SubmitSucceeded(_) ->
            Model(
              ..model,
              server_missing: [],
              server_hard_stops: [],
              outcome: Some(outcome),
              screen: screen_map.Result(""),
            )
          _ -> Model(..model, outcome: Some(outcome))
        }
      #(Model(..model, busy: False), refresh)
    }
    SubmitFinished(Error(reason)) -> #(
      Model(..model, busy: False, error_text: Some(reason)),
      effect.none(),
    )
    MaturityChanged(field, value) -> {
      let next = dict.insert(model.maturity_inputs, field, value)
      #(Model(..model, maturity_inputs: next), effect.none())
    }
    FaqChanged(text) -> #(Model(..model, faq_draft: text), effect.none())
    FaqSubmitted -> #(Model(..model, faq_sent: True), effect.none())
    // ---- Phase 7: session ----
    LoginEmailChanged(email) -> #(Model(..model, login_email: email), effect.none())
    LoginPasswordChanged(password) -> #(
      Model(..model, login_password: password),
      effect.none(),
    )
    LoginSubmitted -> {
      let email = string.trim(model.login_email)
      let password = model.login_password
      case email == "" || password == "" {
        True -> #(
          Model(
            ..model,
            login_error: Some("Укажите адрес и пароль."),
            busy: False,
          ),
          effect.none(),
        )
        False -> #(
          Model(..model, busy: True, login_error: None),
          login_effect(email, password),
        )
      }
    }
    LoginFinished(Ok(_token)) -> {
      // The token is already stored by the client; load the profile and the
      // data of the current screen.
      #(Model(..model, busy: True, login_error: None), load_session_effect())
    }
    LoginFinished(Error(reason)) -> #(
      Model(..model, busy: False, login_error: Some(reason)),
      effect.none(),
    )
    SessionLoaded(Ok(#(user_id, role, display_name))) -> {
      let model = Model(
        ..model,
        session: Some(Session(
          user_id: user_id,
          role: role,
          display_name: display_name,
        )),
        busy: False,
        login_error: None,
      )
      #(model, load_screen_data_effect(model))
    }
    SessionLoaded(Error(reason)) -> {
      // A missing session is the normal state BEFORE the sign-in: the app
      // probes the session on every screen behind the closed loop. Showing
      // "сессия недействительна" then would be noise — the sign-in form is
      // the right answer. The error is only shown when the user actually
      // tried to sign in (the model carries a non-empty e-mail).
      let attempted = model.login_email != ""
      let login_error =
        case attempted {
          True -> Some(reason)
          False -> None
        }
      #(Model(..model, busy: False, login_error: login_error), effect.none())
    }
    // ---- Phase 7: applicant cabinet ----
    MyRequestsLoaded(Ok(items)) -> #(
      Model(
        ..model,
        cabinet: Cabinet(
          requests: items,
          loading: False,
          error: None,
        ),
        busy: False,
      ),
      effect.none(),
    )
    MyRequestsLoaded(Error(reason)) -> #(
      Model(
        ..model,
        cabinet: Cabinet(
          requests: model.cabinet.requests,
          loading: False,
          error: Some(reason),
        ),
        busy: False,
      ),
      effect.none(),
    )
    NotificationsLoaded(Ok(#(items, unread))) -> #(
      Model(
        ..model,
        bell: Bell(items: items, unread: unread, loading: False, error: None),
        busy: False,
      ),
      effect.none(),
    )
    NotificationsLoaded(Error(reason)) -> #(
      Model(
        ..model,
        bell: Bell(
          items: model.bell.items,
          unread: model.bell.unread,
          loading: False,
          error: Some(reason),
        ),
        busy: False,
      ),
      effect.none(),
    )
    NotificationRead(id) -> {
      // Mark the notification as read locally for immediate feedback and
      // confirm it on the server; the server remains the source of truth.
      let items =
        list.map(model.bell.items, fn(item) {
          case item.id == id {
            True -> Notification(..item, is_read: True)
            False -> item
          }
        })
      let unread =
        list.length(list.filter(items, fn(item) { item.is_read == False }))
      let model =
        Model(..model, bell: Bell(..model.bell, items: items, unread: unread))
      #(model, mark_read_effect(id))
    }
    // ---- Phase 7: request card ----
    CardLoaded(Ok(card)) -> #(
      Model(
        ..model,
        card_state: CardState(
          ..model.card_state,
          card: Some(card),
          loading: False,
          error: None,
        ),
        busy: False,
      ),
      effect.none(),
    )
    CardLoaded(Error(reason)) -> #(
      Model(
        ..model,
        card_state: CardState(
          ..model.card_state,
          loading: False,
          error: Some(reason),
        ),
        busy: False,
      ),
      effect.none(),
    )
    // ---- Phase 7: moderator queue ----
    QueueLoaded(Ok(loaded)) -> #(
      Model(
        ..model,
        queue_state: QueueState(
          ..model.queue_state,
          items: loaded.items,
          total: loaded.total,
          loading: False,
          error: None,
        ),
        busy: False,
      ),
      effect.none(),
    )
    QueueLoaded(Error(reason)) -> #(
      Model(
        ..model,
        queue_state: QueueState(
          ..model.queue_state,
          loading: False,
          error: Some(reason),
        ),
        busy: False,
      ),
      effect.none(),
    )
    QueueStatusFilterChanged(value) -> {
      let model = Model(
        ..model,
        queue_state: QueueState(..model.queue_state, status_filter: value),
      )
      #(model, load_queue_effect(model.queue_state))
    }
    QueueTypeFilterChanged(value) -> {
      let model = Model(
        ..model,
        queue_state: QueueState(..model.queue_state, type_filter: value),
      )
      #(model, load_queue_effect(model.queue_state))
    }
    QueueOverdueToggled -> {
      let model = Model(
        ..model,
        queue_state: QueueState(
          ..model.queue_state,
          only_overdue: !model.queue_state.only_overdue,
        ),
      )
      #(model, load_queue_effect(model.queue_state))
    }
    // ---- Phase 7: moderation transitions ----
    TransitionRequested(action, request_id) -> #(
      Model(
        ..model,
        busy: True,
        card_state: CardState(
          ..model.card_state,
          notice: None,
          notice_kind: "info",
        ),
      ),
      transition_effect(action, request_id, model.card_state.note),
    )
    TransitionFinished(request_id, Ok(outcome)) -> {
      let #(text, kind) = transition_notice(outcome)
      let model = Model(
        ..model,
        busy: False,
        card_state: CardState(
          ..model.card_state,
          notice: Some(text),
          notice_kind: kind,
        ),
      )
      // Refresh the card and the queue so both reflect the server state.
      let refresh = effect.batch([
        load_card_effect(request_id),
        load_queue_effect(model.queue_state),
        load_notifications_effect(),
      ])
      #(model, refresh)
    }
    TransitionFinished(_request_id, Error(reason)) -> #(
      Model(
        ..model,
        busy: False,
        card_state: CardState(
          ..model.card_state,
          notice: Some(reason),
          notice_kind: "error",
        ),
      ),
      effect.none(),
    )
    CardNoteChanged(text) -> #(
      Model(..model, card_state: CardState(..model.card_state, note: text)),
      effect.none(),
    )
    CardAnswerChanged(text) -> #(
      Model(..model, card_state: CardState(..model.card_state, answer: text)),
      effect.none(),
    )
    ClarificationSubmitted(request_id) -> {
      let answer = string.trim(model.card_state.answer)
      case answer == "" {
        True -> #(
          Model(
            ..model,
            card_state: CardState(
              ..model.card_state,
              notice: Some("Введите ответ на запрос уточнения."),
              notice_kind: "error",
            ),
          ),
          effect.none(),
        )
        False -> #(
          Model(..model, busy: True),
          clarification_effect(request_id, answer),
        )
      }
    }
    ClarificationFinished(Ok(_)) -> {
      let model = Model(
        ..model,
        busy: False,
        card_state: CardState(
          ..model.card_state,
          answer: "",
          notice: Some("Ответ отправлен модератору."),
          notice_kind: "success",
        ),
      )
      #(model, load_card_effect(card_request_id(model)))
    }
    ClarificationFinished(Error(reason)) -> #(
      Model(
        ..model,
        busy: False,
        card_state: CardState(
          ..model.card_state,
          notice: Some(reason),
          notice_kind: "error",
        ),
      ),
      effect.none(),
    )
    // ---- Phase 7: official response ----
    SaveResponseRequested(request_id) -> #(
      Model(
        ..model,
        busy: True,
        response_state: ResponseState(
          ..model.response_state,
          saving: True,
          error: None,
        ),
      ),
      save_response_effect(request_id, model.response_state.draft),
    )
    ApproveResponseRequested(request_id) -> #(
      Model(
        ..model,
        busy: True,
        response_state: ResponseState(
          ..model.response_state,
          saving: True,
          error: None,
        ),
      ),
      approve_response_effect(request_id),
    )
    ResponseFieldChanged(key, value) -> {
      let draft = draft_set(model.response_state.draft, key, value)
      #(
        Model(..model, response_state: ResponseState(..model.response_state, draft: draft)),
        effect.none(),
      )
    }
    ResponseSaved(Ok(response)) -> {
      let draft = draft_from_response(response)
      #(
        Model(
          ..model,
          busy: False,
          response_state: ResponseState(
            ..model.response_state,
            response: Some(response),
            draft: draft,
            saving: False,
            error: None,
            notice: Some("Черновик ответа сохранён."),
          ),
        ),
        effect.none(),
      )
    }
    ResponseSaved(Error(reason)) -> #(
      Model(
        ..model,
        busy: False,
        response_state: ResponseState(
          ..model.response_state,
          saving: False,
          error: Some(reason),
        ),
      ),
      effect.none(),
    )
    ResponseApproved(Ok(response)) -> {
      let model = Model(
        ..model,
        busy: False,
        response_state: ResponseState(
          ..model.response_state,
          response: Some(response),
          saving: False,
          error: None,
          notice: Some("Ответ утверждён."),
        ),
      )
      #(model, load_card_effect(card_request_id(model)))
    }
    ResponseApproved(Error(reason)) -> #(
      Model(
        ..model,
        busy: False,
        response_state: ResponseState(
          ..model.response_state,
          saving: False,
          error: Some(reason),
        ),
      ),
      effect.none(),
    )
    ResponsePreviewToggled -> #(
      Model(
        ..model,
        response_state: ResponseState(
          ..model.response_state,
          preview: !model.response_state.preview,
        ),
      ),
      effect.none(),
    )
    // ---- Phase 7: applicant feedback ----
    FeedbackSubmitted(request_id, is_clear) -> #(
      Model(..model, busy: True),
      feedback_effect(request_id, is_clear),
    )
    FeedbackFinished(request_id, Ok(_)) -> {
      let model = Model(
        ..model,
        busy: False,
        card_state: CardState(
          ..model.card_state,
          notice: Some("Спасибо за обратную связь."),
          notice_kind: "success",
        ),
      )
      #(model, load_card_effect(request_id))
    }
    FeedbackFinished(_request_id, Error(reason)) -> #(
      Model(
        ..model,
        busy: False,
        card_state: CardState(
          ..model.card_state,
          notice: Some(reason),
          notice_kind: "error",
        ),
      ),
      effect.none(),
    )
    // ---- Phase 7: metrics ----
    MetricsLoaded(Ok(items)) -> #(
      Model(
        ..model,
        metrics_state: MetricsState(
          items: items,
          loading: False,
          error: None,
        ),
        busy: False,
      ),
      effect.none(),
    )
    MetricsLoaded(Error(reason)) -> #(
      Model(
        ..model,
        metrics_state: MetricsState(
          items: model.metrics_state.items,
          loading: False,
          error: Some(reason),
        ),
        busy: False,
      ),
      effect.none(),
    )
    // ---- Phase 8: панель автоматизации ----
    AutomationPanelLoaded(Ok(panel)) -> {
      let metrics_state = model.automation_state.metrics
      let state = automation_state.AutomationState(
        settings: model.automation_state.settings,
        panel: panel,
        metrics: metrics_state,
        loading: False,
        error: None,
        last_action_notice: model.automation_state.last_action_notice,
        last_action_kind: model.automation_state.last_action_kind,
      )
      let model = Model(..model, automation_state: state, busy: False)
      #(
        model,
        effect.batch([
          load_settings_only_effect(),
          load_efficiency_metrics_effect(),
        ]),
      )
    }
    AutomationPanelLoaded(Error(reason)) -> #(
      Model(
        ..model,
        automation_state: automation_state.AutomationState(
          settings: model.automation_state.settings,
          panel: model.automation_state.panel,
          metrics: model.automation_state.metrics,
          loading: False,
          error: Some(reason),
          last_action_notice: model.automation_state.last_action_notice,
          last_action_kind: model.automation_state.last_action_kind,
        ),
        busy: False,
      ),
      effect.none(),
    )
    AutomationSettingsLoaded(Ok(settings)) -> #(
      Model(
        ..model,
        automation_state: automation_state.AutomationState(
          settings: settings,
          panel: model.automation_state.panel,
          metrics: model.automation_state.metrics,
          loading: model.automation_state.loading,
          error: model.automation_state.error,
          last_action_notice: model.automation_state.last_action_notice,
          last_action_kind: model.automation_state.last_action_kind,
        ),
        settings_state: automation_state.SettingsState(
          settings: settings,
          loading: False,
          saving: model.settings_state.saving,
          error: model.settings_state.error,
          notice: model.settings_state.notice,
        ),
        pending_mode: settings.mode,
        busy: False,
      ),
      effect.none(),
    )
    AutomationSettingsLoaded(Error(reason)) -> #(
      Model(
        ..model,
        settings_state: automation_state.SettingsState(
          settings: model.settings_state.settings,
          loading: False,
          saving: model.settings_state.saving,
          error: Some(reason),
          notice: model.settings_state.notice,
        ),
        busy: False,
      ),
      effect.none(),
    )
    AutomationModeSaved(Ok(settings)) -> #(
      Model(
        ..model,
        settings_state: automation_state.SettingsState(
          settings: settings,
          loading: False,
          saving: False,
          error: None,
          notice: Some(
            "Режим «"
            <> automation_state.mode_label(settings.mode)
            <> "» сохранён.",
          ),
        ),
        automation_state: automation_state.AutomationState(
          settings: settings,
          panel: model.automation_state.panel,
          metrics: model.automation_state.metrics,
          loading: model.automation_state.loading,
          error: model.automation_state.error,
          last_action_notice: Some("Режим сохранён в PostgreSQL."),
          last_action_kind: "success",
        ),
        pending_mode: settings.mode,
        busy: False,
      ),
      load_automation_panel_effect(),
    )
    AutomationModeSaved(Error(reason)) -> #(
      Model(
        ..model,
        settings_state: automation_state.SettingsState(
          settings: model.settings_state.settings,
          loading: False,
          saving: False,
          error: Some(reason),
          notice: model.settings_state.notice,
        ),
        busy: False,
      ),
      effect.none(),
    )
    EfficiencyMetricsLoaded(Ok(items)) -> #(
      Model(
        ..model,
        automation_state: automation_state.AutomationState(
          settings: model.automation_state.settings,
          panel: model.automation_state.panel,
          metrics: items,
          loading: model.automation_state.loading,
          error: model.automation_state.error,
          last_action_notice: model.automation_state.last_action_notice,
          last_action_kind: model.automation_state.last_action_kind,
        ),
        busy: False,
      ),
      effect.none(),
    )
    EfficiencyMetricsLoaded(Error(reason)) -> #(
      Model(
        ..model,
        automation_state: automation_state.AutomationState(
          settings: model.automation_state.settings,
          panel: model.automation_state.panel,
          metrics: model.automation_state.metrics,
          loading: model.automation_state.loading,
          error: Some(reason),
          last_action_notice: model.automation_state.last_action_notice,
          last_action_kind: model.automation_state.last_action_kind,
        ),
        busy: False,
      ),
      effect.none(),
    )
    AgentChecksLoaded(Ok(items)) -> #(
      Model(
        ..model,
        agent_checks_state: automation_state.AgentChecksState(
          checks: items,
          loading: False,
          error: None,
          rechecking: model.agent_checks_state.rechecking,
          notice: model.agent_checks_state.notice,
          filter_result: model.agent_checks_state.filter_result,
        ),
        busy: False,
      ),
      effect.none(),
    )
    AgentChecksLoaded(Error(reason)) -> #(
      Model(
        ..model,
        agent_checks_state: automation_state.AgentChecksState(
          checks: model.agent_checks_state.checks,
          loading: False,
          error: Some(reason),
          rechecking: model.agent_checks_state.rechecking,
          notice: model.agent_checks_state.notice,
          filter_result: model.agent_checks_state.filter_result,
        ),
        busy: False,
      ),
      effect.none(),
    )
    ExceptionsLoaded(Ok(items)) -> #(
      Model(
        ..model,
        exceptions_state: automation_state.ExceptionsState(
          items: items,
          loading: False,
          error: None,
          resolving: model.exceptions_state.resolving,
          notice: model.exceptions_state.notice,
        ),
        busy: False,
      ),
      effect.none(),
    )
    ExceptionsLoaded(Error(reason)) -> #(
      Model(
        ..model,
        exceptions_state: automation_state.ExceptionsState(
          items: model.exceptions_state.items,
          loading: False,
          error: Some(reason),
          resolving: model.exceptions_state.resolving,
          notice: model.exceptions_state.notice,
        ),
        busy: False,
      ),
      effect.none(),
    )
    JournalLoaded(Ok(items)) -> #(
      Model(
        ..model,
        journal_state: automation_state.JournalState(
          items: items,
          loading: False,
          error: None,
          filter_mode: model.journal_state.filter_mode,
        ),
        busy: False,
      ),
      effect.none(),
    )
    JournalLoaded(Error(reason)) -> #(
      Model(
        ..model,
        journal_state: automation_state.JournalState(
          items: model.journal_state.items,
          loading: False,
          error: Some(reason),
          filter_mode: model.journal_state.filter_mode,
        ),
        busy: False,
      ),
      effect.none(),
    )
    AutomationModeSelected(mode) -> #(
      Model(..model, pending_mode: mode),
      effect.none(),
    )
    AutomationModeSaveRequested -> {
      let mode = case model.pending_mode {
        "" -> model.settings_state.settings.mode
        other -> other
      }
      #(
        Model(
          ..model,
          settings_state: automation_state.SettingsState(
            settings: model.settings_state.settings,
            loading: model.settings_state.loading,
            saving: True,
            error: None,
            notice: model.settings_state.notice,
          ),
          busy: True,
        ),
        save_mode_effect(mode),
      )
    }
    AgentRecheckRequested(request_id) -> #(
      Model(
        ..model,
        agent_checks_state: automation_state.AgentChecksState(
          checks: model.agent_checks_state.checks,
          loading: False,
          error: model.agent_checks_state.error,
          rechecking: Some(request_id),
          notice: model.agent_checks_state.notice,
          filter_result: model.agent_checks_state.filter_result,
        ),
      ),
      recheck_effect(request_id),
    )
    AgentRecheckFinished(request_id, Ok(_)) -> {
      let notice_text = "Повторная проверка запущена для " <> request_id
      #(
        Model(
          ..model,
          agent_checks_state: automation_state.AgentChecksState(
            checks: model.agent_checks_state.checks,
            loading: False,
            error: model.agent_checks_state.error,
            rechecking: None,
            notice: Some(notice_text),
            filter_result: model.agent_checks_state.filter_result,
          ),
        ),
        load_agent_checks_effect(),
      )
    }
    AgentRecheckFinished(_request_id, Error(reason)) -> #(
      Model(
        ..model,
        agent_checks_state: automation_state.AgentChecksState(
          checks: model.agent_checks_state.checks,
          loading: False,
          error: Some(reason),
          rechecking: None,
          notice: Some("Не удалось запустить повторную проверку."),
          filter_result: model.agent_checks_state.filter_result,
        ),
      ),
      effect.none(),
    )
    AgentFilterChanged(value) -> #(
      Model(
        ..model,
        agent_checks_state: automation_state.AgentChecksState(
          checks: model.agent_checks_state.checks,
          loading: model.agent_checks_state.loading,
          error: model.agent_checks_state.error,
          rechecking: model.agent_checks_state.rechecking,
          notice: model.agent_checks_state.notice,
          filter_result: value,
        ),
      ),
      effect.none(),
    )
    ExceptionResolveRequested(exception_id) -> #(
      Model(
        ..model,
        exceptions_state: automation_state.ExceptionsState(
          items: model.exceptions_state.items,
          loading: False,
          error: model.exceptions_state.error,
          resolving: Some(exception_id),
          notice: model.exceptions_state.notice,
        ),
      ),
      resolve_exception_effect(exception_id),
    )
    ExceptionResolveFinished(exception_id, Ok(_)) -> {
      let notice_text = "Исключение " <> exception_id <> " разрешено."
      #(
        Model(
          ..model,
          exceptions_state: automation_state.ExceptionsState(
            items: model.exceptions_state.items,
            loading: False,
            error: None,
            resolving: None,
            notice: Some(notice_text),
          ),
        ),
        load_exceptions_effect(),
      )
    }
    ExceptionResolveFinished(_id, Error(reason)) -> #(
      Model(
        ..model,
        exceptions_state: automation_state.ExceptionsState(
          items: model.exceptions_state.items,
          loading: False,
          error: Some(reason),
          resolving: None,
          notice: Some("Не удалось разрешить исключение."),
        ),
      ),
      effect.none(),
    )
    JournalFilterChanged(mode) -> #(
      Model(
        ..model,
        journal_state: automation_state.JournalState(
          items: model.journal_state.items,
          loading: model.journal_state.loading,
          error: model.journal_state.error,
          filter_mode: mode,
        ),
      ),
      effect.none(),
    )
    AutomationRefreshRequested -> {
      let fx = case model.screen {
        screen_map.AutomationDashboard -> load_automation_panel_effect()
        screen_map.AgentChecks -> load_agent_checks_effect()
        screen_map.AgentExceptions -> load_exceptions_effect()
        screen_map.AutomationJournal -> load_journal_effect()
        screen_map.AutomationSettings -> load_settings_only_effect()
        _ -> effect.none()
      }
      #(model, fx)
    }
    Navigate(path) -> {
      let route = parse_route(path)
      let next_screen = route.screen
      // The page is already on the target path when the user clicks the
      // S0 button, so we only need to call navigate_to() when the path
      // is *different* from the current one. For F5 we just re-parse.
      let here = current_path(Nil)
      let fx = case path != here {
        True -> navigate_effect(path)
        False -> case next_screen {
          screen_map.Clarify(id) | screen_map.Result(id) ->
            load_request_effect(id)
          _ -> effect.none()
        }
      }
      let model = Model(..model, route: route, screen: next_screen)
      #(model, fx)
    }
  }
}

/// The id of the request currently shown in the card, or an empty string.
///
/// The card is the single source of the current request in the Phase-7
/// screens; the helper keeps the effects free of nested `case` blocks.
fn card_request_id(model: Model) -> String {
  case model.card_state.card {
    Some(card) -> card.id
    None -> ""
  }
}

/// Merge the server's `fields` with the values the user has typed.
///
/// Server values are the baseline; anything the user typed wins, so we do
/// not wipe their input on every refresh.
fn merge_values(
  server: dict.Dict(String, String),
  user: dict.Dict(String, String),
) -> dict.Dict(String, String) {
  list.fold(dict.to_list(server), user, fn(acc, pair) {
    case dict.get(acc, pair.0) {
      Ok(existing) if existing != "" -> acc
      _ -> dict.insert(acc, pair.0, pair.1)
    }
  })
}

// -------------------------------------------------------------
// Effects
// -------------------------------------------------------------

/// Wrap a callback-style API call into a Lustre effect.
///
/// `effect.from` takes `fn(fn(msg) -> Nil) -> Nil` and turns it into a
/// valid `Effect`. This is the supported way to bridge the FFI callbacks
/// into the Lustre runtime.
fn from_callback(run: fn(fn(Msg) -> Nil) -> Nil) -> Effect(Msg) {
  effect.from(run)
}

fn create_draft_effect(text: String, idempotency_key: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    create_draft(text, idempotency_key, fn(result) {
      dispatch(DraftCreated(result))
    })
  })
}

fn load_request_effect(request_id: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    load_request(request_id, fn(result) { dispatch(RequestLoaded(result)) })
  })
}

fn submit_request_effect(request_id: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    submit_request(request_id, fn(result) {
      dispatch(SubmitFinished(result))
    })
  })
}

/// Navigate to another path. The navigation is performed by the browser
/// (a full page load) so that the server-side route stays the source of
/// truth and F5 restores the same screen.
fn navigate_effect(path: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    navigate_to(path)
    dispatch(Navigate(path))
  })
}

// -------------------------------------------------------------
// Phase 7 effects
// -------------------------------------------------------------

fn login_effect(email: String, password: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    login(email, password, fn(result) { dispatch(LoginFinished(result)) })
  })
}

fn load_session_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    load_session(fn(result) { dispatch(SessionLoaded(result)) })
  })
}

fn load_my_requests_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    load_my_requests(fn(result) { dispatch(MyRequestsLoaded(result)) })
  })
}

fn load_notifications_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    load_notifications(fn(feed) {
      case feed {
        Ok(value) ->
          dispatch(NotificationsLoaded(Ok(#(value.items, value.unread))))
        Error(reason) -> dispatch(NotificationsLoaded(Error(reason)))
      }
    })
  })
}

fn mark_read_effect(notification_id: String) -> Effect(Msg) {
  from_callback(fn(_dispatch) {
    mark_notification_read(notification_id, fn(_result) { Nil })
  })
}

fn load_card_effect(request_id: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    load_request_card(request_id, fn(result) { dispatch(CardLoaded(result)) })
  })
}

fn load_queue_effect(state: QueueState) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    load_queue(
      state.status_filter,
      state.type_filter,
      "",
      state.only_overdue,
      50,
      0,
      fn(result) { dispatch(QueueLoaded(result)) },
    )
  })
}

fn transition_effect(
  action: String,
  request_id: String,
  note: String,
) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    apply_transition(request_id, action, note, fn(result) {
      dispatch(TransitionFinished(request_id, result))
    })
  })
}

fn clarification_effect(request_id: String, answer: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    submit_clarification(request_id, answer, fn(result) {
      dispatch(ClarificationFinished(result))
    })
  })
}

fn save_response_effect(
  request_id: String,
  draft: List(#(String, String)),
) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    save_response_draft(request_id, draft, fn(result) {
      dispatch(ResponseSaved(result))
    })
  })
}

fn approve_response_effect(request_id: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    approve_response(request_id, fn(result) { dispatch(ResponseApproved(result)) })
  })
}

fn feedback_effect(request_id: String, is_clear: Bool) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    submit_feedback(request_id, is_clear, "", fn(outcome) {
      case outcome {
        Ok(FeedbackStored) ->
          dispatch(FeedbackFinished(request_id, Ok(#(is_clear, ""))))
        Ok(FeedbackMissing) ->
          dispatch(FeedbackFinished(request_id, Error("Ответ не найден")))
        Error(reason) -> dispatch(FeedbackFinished(request_id, Error(reason)))
      }
    })
  })
}

fn load_metrics_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    load_metrics(fn(result) { dispatch(MetricsLoaded(result)) })
  })
}

// -------------------------------------------------------------
// Phase 8 effects
// -------------------------------------------------------------

fn load_automation_panel_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.load_panel(fn(result) {
      dispatch(AutomationPanelLoaded(result))
    })
  })
}

fn load_settings_only_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.load_settings(fn(result) {
      dispatch(AutomationSettingsLoaded(result))
    })
  })
}

fn load_efficiency_metrics_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.load_efficiency_metrics(fn(result) {
      dispatch(EfficiencyMetricsLoaded(result))
    })
  })
}

fn load_agent_checks_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.load_panel(fn(result) {
      case result {
        Ok(panel) -> dispatch(AgentChecksLoaded(Ok(panel.checks)))
        Error(reason) -> dispatch(AgentChecksLoaded(Error(reason)))
      }
    })
  })
}

fn load_exceptions_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.load_exceptions(True, fn(result) {
      dispatch(ExceptionsLoaded(result))
    })
  })
}

fn load_journal_effect() -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.load_journal(fn(result) {
      dispatch(JournalLoaded(result))
    })
  })
}

fn save_mode_effect(mode: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.save_mode(mode, fn(result) {
      dispatch(AutomationModeSaved(result))
    })
  })
}

fn recheck_effect(request_id: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.recheck_request(request_id, fn(result) {
      dispatch(AgentRecheckFinished(request_id, result))
    })
  })
}

fn resolve_exception_effect(exception_id: String) -> Effect(Msg) {
  from_callback(fn(dispatch) {
    phase8_client.resolve_exception(exception_id, "", fn(result) {
      dispatch(ExceptionResolveFinished(exception_id, result))
    })
  })
}

/// Load the data the current screen needs, once the session is confirmed.
fn load_screen_data_effect(model: Model) -> Effect(Msg) {
  case model.screen {
    screen_map.MyRequests -> load_my_requests_effect()
    screen_map.Notifications -> load_notifications_effect()
    screen_map.RequestCard(id) | screen_map.RequestHistory(id) ->
      load_card_effect(id)
    screen_map.ResponseEditor(id) -> load_card_effect(id)
    screen_map.ModerationQueue ->
      effect.batch([
        load_queue_effect(model.queue_state),
        load_notifications_effect(),
      ])
    screen_map.Metrics ->
      effect.batch([load_metrics_effect(), load_notifications_effect()])
    // ---- Phase 8 ----
    screen_map.AutomationDashboard -> load_automation_panel_effect()
    screen_map.AgentChecks -> load_agent_checks_effect()
    screen_map.AgentExceptions -> load_exceptions_effect()
    screen_map.AutomationJournal -> load_journal_effect()
    screen_map.AutomationSettings -> load_settings_only_effect()
    screen_map.ApplicantBell -> load_notifications_effect()
    _ -> load_notifications_effect()
  }
}

// -------------------------------------------------------------
// View
// -------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("app")], [
    view_top_header(model),
    view_body(model),
  ])
}

/// The unread counter of the bell.
fn view_bell_badge(unread: Int) -> Element(Msg) {
  case unread {
    0 -> html.span([], [])
    _ ->
      html.span(
        [attribute.class("bell__badge"), attribute.id("bell-count")],
        [html.text(int.to_string(unread))],
      )
  }
}

/// The top application header. Visible on every screen — wraps the
/// breadcrumb, the current automation mode pill and the notification bell.
/// The session is required to render the bell (otherwise the panel is
/// hidden — see `needs_session` in `screen.gleam`).
fn view_top_header(model: Model) -> Element(Msg) {
  let needs_session = screen_map.needs_session(model.screen)
  html.header([attribute.class("app-header")], [
    html.div([attribute.class("app-header__row")], [
      view_breadcrumb(model),
      html.div([attribute.class("app-header__center")], [view_mode_pill(model)]),
      html.div([attribute.class("app-header__actions")], [
        case needs_session {
          True -> view_bell(model)
          False -> html.span([], [])
        },
      ]),
    ]),
  ])
}

/// Breadcrumb of the current location. The first crumb is always the
/// product root ("Эффективность 360") and the last crumb is the current
/// screen title.
fn view_breadcrumb(model: Model) -> Element(Msg) {
  html.nav(
    [attribute.class("app-header__breadcrumbs"), attribute.aria_label("Хлебные крошки")],
    [
      html.span([attribute.class("app-header__breadcrumb")], [
        html.text("Эффективность 360"),
      ]),
      html.span([attribute.class("app-header__breadcrumb-sep")], [
        html.text("/"),
      ]),
      html.span([attribute.class("app-header__breadcrumb-current")], [
        html.text(screen_title(model.screen)),
      ]),
    ],
  )
}

/// Pill with the current automation mode. The pill is hidden on the
/// applicant funnel (S0–S4) where the mode is irrelevant.
fn view_mode_pill(model: Model) -> Element(Msg) {
  case screen_map.needs_session(model.screen) {
    False -> html.span([], [])
    True -> {
      let mode = model.automation_state.panel.mode
      let label = automation_state.mode_label(mode)
      html.span([attribute.class("app-header__pill")], [
        html.span([attribute.class("app-header__pill-dot")], []),
        html.text(label),
        html.text(" · правила v" <> model.automation_state.panel.rules_version),
      ])
    }
  }
}

/// The notification bell with the unread counter and the dropdown feed.
fn view_bell(model: Model) -> Element(Msg) {
  html.div([attribute.class("bell"), attribute.id("bell")], [
    html.button(
      [
        attribute.class("bell__button"),
        attribute.id("bell-button"),
        attribute.data("action", "toggle-bell"),
        attribute.data("unread", int.to_string(model.bell.unread)),
        attribute.aria_expanded(False),
        attribute.aria_label(
          "Уведомления, непрочитанных: " <> int.to_string(model.bell.unread),
        ),
      ],
      [
        html.span([attribute.class("bell__icon")], [html.text("🔔")]),
        view_bell_badge(model.bell.unread),
      ],
    ),
    html.div([attribute.class("bell__panel"), attribute.id("bell-panel")], [
      html.p([attribute.class("bell__panel-title")], [
        html.text("Уведомления"),
      ]),
      notification_feed(
        model.bell.items,
        model.bell.unread,
        fn(request_id) { Navigate("/request/" <> request_id <> "/detail") },
        fn(notification_id) { NotificationRead(notification_id) },
      ),
    ]),
  ])
}

/// A minimal breadcrumb. CustDev.md §5 requires that the interface does
/// NOT lead the user through a wizard, so this is an indicator, not a
/// navigation widget.
fn view_steps(model: Model) -> Element(Msg) {
  let current = step_number(model.screen)
  let steps =
    list.map(
      [#("Описание", 1), #("Уточнение", 2), #("Отправка", 3)],
      fn(entry) {
        let done = current > entry.1
        let active = current == entry.1
        html.li(
          [
            attribute.class(
              case done {
                True -> "step done"
                False -> {
                  case active {
                    True -> "step active"
                    False -> "step"
                  }
                }
              },
            ),
          ],
          [html.text(entry.0)],
        )
      },
    )
  html.ol([attribute.class("steps")], steps)
}

fn view_body(model: Model) -> Element(Msg) {
  case model.screen {
    screen_map.Start -> view_start(model)
    screen_map.Describe -> view_describe(model)
    screen_map.Clarify(_) -> view_clarify(model)
    screen_map.Result(_) -> view_result(model)
    _ -> view_phase7(model)
  }
}

// -------------------------------------------------------------
// The sign-in form
// -------------------------------------------------------------

/// The sign-in form.
///
/// The session lives in `sessionStorage` under `e360.session-token`, and
/// the token is read at call time, so a token obtained in another tab is
/// picked up as well. Without a form there would be no way to obtain a
/// token from the browser — the applicant cabinet, the moderation queue
/// and the notification feed are all behind the session.
fn view_login_form(model: Model) -> Element(Msg) {
  html.form(
    [
      attribute.class("login-form"),
      attribute.id("login-form"),
      event.on_submit(fn(_) { LoginSubmitted }),
    ],
    [
      html.h2([attribute.class("page__title")], [html.text("Вход")]),
      html.p([attribute.class("page__lead")], [
        html.text(
          "Введите e-mail и пароль, чтобы увидеть свои заявки и уведомления.",
        ),
      ]),
      html.label([attribute.class("form__field")], [
        html.span([attribute.class("form__label")], [html.text("E-mail")]),
        html.input(
          [
            attribute.class("form__input"),
            attribute.id("login-email"),
            attribute.attribute("type", "email"),
            attribute.attribute("autocomplete", "username"),
            attribute.placeholder("demo.applicant@example.invalid"),
            attribute.value(model.login_email),
            event.on_input(fn(value: String) { LoginEmailChanged(value) }),
          ],
        ),
      ]),
      html.label([attribute.class("form__field")], [
        html.span([attribute.class("form__label")], [html.text("Пароль")]),
        html.input(
          [
            attribute.class("form__input"),
            attribute.id("login-password"),
            attribute.attribute("type", "password"),
            attribute.attribute("autocomplete", "current-password"),
            attribute.value(model.login_password),
            event.on_input(fn(value: String) { LoginPasswordChanged(value) }),
          ],
        ),
      ]),
      case model.login_error {
        None -> html.span([], [])
        Some(text) ->
          html.span(
            [
              attribute.class("field__error"),
              attribute.id("login-error"),
              attribute.role("alert"),
            ],
            [html.text(text)],
          )
      },
      html.button(
        [
          attribute.class("btn btn--primary btn--block"),
          attribute.id("login-submit"),
          attribute.attribute("type", "submit"),
          attribute.disabled(model.busy),
        ],
        [html.text("Войти")],
      ),
      html.p([attribute.class("login-form__hint")], [
        html.text(
          "Демо-стенд: demo.applicant@example.invalid (заявитель), "
          <> "demo.moderator@example.invalid (модератор), "
          <> "demo.manager@example.invalid (руководитель). Пароль — demo.",
        ),
      ]),
    ],
  )
}

/// True when the current screen shows the sign-in form instead of the
/// content, because there is no session yet.
fn shows_login_form(model: Model) -> Bool {
  case screen_map.needs_session(model.screen) {
    False -> False
    True ->
      case model.session {
        None -> True
        Some(_) -> False
      }
  }
}

// -------------------------------------------------------------
// Phase 7: the shared layout and the screens
// -------------------------------------------------------------

/// The Phase-7 screens share one layout: a sidebar with the sections of the
/// closed loop and the content of the current screen.
fn view_phase7(model: Model) -> Element(Msg) {
  html.div([attribute.class("app-layout")], [
    view_sidebar(model),
    html.main([attribute.class("app-main")], [
      view_notice(model),
      view_phase7_content(model),
    ]),
  ])
}

/// The content of the current Phase-7 screen.
fn view_phase7_content(model: Model) -> Element(Msg) {
  // Without a session the screens behind the closed loop have nothing to
  // show — the sign-in form takes their place.
  case shows_login_form(model) {
    True -> view_login_form(model)
    False ->
      case model.screen {
        screen_map.MyRequests -> view_my_requests(model)
        screen_map.Notifications -> view_notifications(model)
        screen_map.RequestCard(id) -> view_request_card(model, id)
        screen_map.RequestHistory(id) -> view_request_history(model, id)
        screen_map.ResponseEditor(id) -> view_response_editor(model, id)
        screen_map.ModerationQueue -> view_moderation_queue(model)
        screen_map.Metrics -> view_metrics(model)
        // ---- Phase 8 ----
        screen_map.AutomationDashboard -> view_automation_dashboard(model)
        screen_map.AgentChecks -> view_agent_checks(model)
        screen_map.AgentExceptions -> view_exceptions(model)
        screen_map.AutomationJournal -> view_journal(model)
        screen_map.AutomationSettings -> view_settings(model)
        screen_map.ApplicantBell -> view_applicant_bell(model)
        _ -> html.div([], [])
      }
  }
}

/// The sidebar with the sections of the closed loop.
fn view_sidebar(model: Model) -> Element(Msg) {
  let exceptions_open = automation_state.open_exception_count(model.automation_state)
  html.nav([attribute.class("app-sidebar"), attribute.id("app-sidebar")], [
    html.a(
      [attribute.href("/"), attribute.class("app-sidebar__brand")],
      [
        html.span([attribute.class("app-sidebar__logo")], [html.text("Э360")]),
        html.div([], [
          html.h2([attribute.class("app-sidebar__brand-title")], [
            html.text("Эффективность 360"),
          ]),
          html.p([attribute.class("app-sidebar__brand-subtitle")], [
            html.text("Сервис внутренних заявок"),
          ]),
        ]),
      ],
    ),
    view_sidebar_group("Заявитель", [
      sidebar_link(model, "/my/requests", "Мои заявки", screen_map.MyRequests),
      sidebar_link(
        model,
        "/notifications",
        "Уведомления",
        screen_map.Notifications,
      ),
      sidebar_link(
        model,
        "/account/bell",
        "Колокольчик",
        screen_map.ApplicantBell,
      ),
    ]),
    view_sidebar_group("Исполнитель", [
      sidebar_link(
        model,
        "/moderation/queue",
        "Очередь модератора",
        screen_map.ModerationQueue,
      ),
      sidebar_link(
        model,
        "/moderation/metrics",
        "Метрики 360",
        screen_map.Metrics,
      ),
    ]),
    view_sidebar_group("Руководитель", [
      sidebar_link(
        model,
        "/automation",
        "Панель автоматизации",
        screen_map.AutomationDashboard,
      ),
      sidebar_link(
        model,
        "/automation/checks",
        "Цифровой модератор",
        screen_map.AgentChecks,
      ),
      sidebar_with_badge(
        model,
        "/automation/exceptions",
        "Исключения",
        screen_map.AgentExceptions,
        exceptions_open,
      ),
      sidebar_link(
        model,
        "/automation/journal",
        "Журнал действий",
        screen_map.AutomationJournal,
      ),
      sidebar_link(
        model,
        "/automation/settings",
        "Настройки режима",
        screen_map.AutomationSettings,
      ),
    ]),
    view_session_card(model),
  ])
}

fn view_sidebar_group(label: String, links: List(Element(Msg))) -> Element(Msg) {
  html.div([attribute.class("app-sidebar__group")], [
    html.h3([attribute.class("app-sidebar__group-label")], [html.text(label)]),
    html.ul([attribute.class("app-sidebar__nav")], links),
  ])
}

fn sidebar_with_badge(
  model: Model,
  path: String,
  label: String,
  screen: screen_map.Screen,
  badge: Int,
) -> Element(Msg) {
  let active = model.screen == screen
  html.li([], [
    html.a(
      [
        attribute.href(path),
        attribute.class(
          case active {
            True -> "app-sidebar__link app-sidebar__link--active"
            False -> "app-sidebar__link"
          },
        ),
        attribute.data("action", "navigate"),
        attribute.data("path", path),
      ],
      [
        html.text(label),
        case badge {
          0 -> html.span([], [])
          n -> html.span([attribute.class("app-sidebar__link-badge")], [html.text(int.to_string(n))])
        },
      ],
    ),
  ])
}

fn sidebar_link(
  model: Model,
  path: String,
  label: String,
  screen: screen_map.Screen,
) -> Element(Msg) {
  let active = model.screen == screen
  html.li([], [
    html.a(
      [
        attribute.href(path),
        attribute.class(
          case active {
            True -> "app-sidebar__link app-sidebar__link--active"
            False -> "app-sidebar__link"
          },
        ),
        attribute.data("action", "navigate"),
        attribute.data("path", path),
      ],
      [html.text(label)],
    ),
  ])
}

/// The session card: avatar, name and role of the signed-in user, with
/// an exit button if the session is missing.
fn view_session_card(model: Model) -> Element(Msg) {
  case model.session {
    None ->
      html.div([attribute.class("app-sidebar__session")], [
        html.div([attribute.class("app-sidebar__session-card")], [
          html.span([attribute.class("app-sidebar__session-avatar")], [
            html.text("?"),
          ]),
          html.div([attribute.class("app-sidebar__session-meta")], [
            html.p([attribute.class("app-sidebar__session-name")], [
              html.text("Вы не вошли в систему"),
            ]),
            html.p([attribute.class("app-sidebar__session-role")], [
              html.text(""),
            ]),
          ]),
        ]),
      ])
    Some(session) ->
      html.div([attribute.class("app-sidebar__session")], [
        html.div([attribute.class("app-sidebar__session-card")], [
          html.span([attribute.class("app-sidebar__session-avatar")], [
            html.text(initials(session.display_name)),
          ]),
          html.div([attribute.class("app-sidebar__session-meta")], [
            html.p([attribute.class("app-sidebar__session-name")], [
              html.text(session.display_name),
            ]),
            html.p([attribute.class("app-sidebar__session-role")], [
              html.text(role_label(session.role)),
            ]),
          ]),
        ]),
      ])
  }
}

/// Make two-letter initials out of a person's display name.
/// Falls back to a single letter if the name is empty.
fn initials(name: String) -> String {
  let trimmed = string.trim(name)
  case string.length(trimmed) {
    0 -> "?"
    _ -> {
      let first = case string.first(trimmed) {
        Ok(c) -> c
        Error(_) -> "?"
      }
      let last = case string.last(trimmed) {
        Ok(c) -> c
        Error(_) -> ""
      }
      string.uppercase(first) <> string.uppercase(last)
    }
  }
}

fn role_label(role: String) -> String {
  case role {
    "moderator" -> "Модератор"
    "applicant" -> "Заявитель"
    "admin" -> "Администратор"
    "" -> "Роль не определена"
    other -> other
  }
}

/// A dismissible notice (the verdict of the last action).
fn view_notice(model: Model) -> Element(Msg) {
  case model.card_state.notice {
    None -> html.span([], [])
    Some(text) ->
      html.div(
        [
          attribute.class("notice notice--" <> model.card_state.notice_kind),
          attribute.id("action-notice"),
          attribute.role("status"),
        ],
        [html.text(text)],
      )
  }
}

/// P7.1 — the applicant cabinet.
fn view_my_requests(model: Model) -> Element(Msg) {
  html.section([attribute.class("page")], [
    html.h2([attribute.class("page__title")], [html.text("Мои заявки")]),
    html.p([attribute.class("page__lead")], [
      html.text(
        "Здесь собраны только ваши заявки. Заявки других заявителей недоступны.",
      ),
    ]),
    view_error(model.cabinet.error),
    request_list(model.cabinet.requests),
  ])
}

/// P7.2 — the notification feed.
fn view_notifications(model: Model) -> Element(Msg) {
  html.section([attribute.class("page")], [
    html.h2([attribute.class("page__title")], [html.text("Уведомления")]),
    html.p([attribute.class("page__lead")], [
      html.text(
        "Лента событий по вашим заявкам: приём в работу, запрос уточнения, "
          <> "готовый ответ и завершение рассмотрения.",
      ),
    ]),
    view_error(model.bell.error),
    notification_feed(
      model.bell.items,
      model.bell.unread,
      fn(request_id) { Navigate("/request/" <> request_id <> "/detail") },
      fn(notification_id) { NotificationRead(notification_id) },
    ),
  ])
}

/// P7.3 — the request card.
fn view_request_card(model: Model, _request_id: String) -> Element(Msg) {
  case model.card_state.card {
    None ->
      html.section([attribute.class("page")], [
        view_error(model.card_state.error),
        html.p([attribute.class("page__lead")], [
          html.text("Загрузка карточки заявки…"),
        ]),
      ])
    Some(card) ->
      html.section([attribute.class("page")], [
        html.h2([attribute.class("page__title")], [
          html.text("Заявка " <> short_request_id(card.id)),
        ]),
        view_error(model.card_state.error),
        view_stepper(card.status),
        request_card(card, fn(action, id) { TransitionRequested(action, id) }),
        view_clarification_form(model, card),
        view_response_summary(card),
        view_feedback_widget(card),
        html.div([attribute.class("page__links")], [
          html.a(
            [
              attribute.href("/request/" <> card.id <> "/history"),
              attribute.data("action", "open-history"),
            ],
            [html.text("История заявки по этапам")],
          ),
        ]),
      ])
  }
}

fn view_stepper(status: String) -> Element(Msg) {
  html.div([attribute.class("page__stepper")], [stepper(status)])
}

/// The clarification form — only shown when the server says the applicant
/// may answer.
fn view_clarification_form(model: Model, card: RequestCard) -> Element(Msg) {
  case card.can_respond {
    False -> html.span([], [])
    True ->
      html.div([attribute.class("page__panel")], [
        html.h3([attribute.class("page__panel-title")], [
          html.text("Требуется ваш ответ"),
        ]),
        html.p([attribute.class("page__lead")], [
          html.text(card.clarification_note),
        ]),
        html.textarea(
          [
            attribute.class("form__textarea"),
            attribute.id("clarification-answer"),
            attribute.value(model.card_state.answer),
            attribute.placeholder("Ваш ответ на запрос уточнения"),
            event.on_input(fn(value: String) { CardAnswerChanged(value) }),
          ],
          "",
        ),
        html.button(
          [
            attribute.class("btn btn--primary"),
            attribute.id("btn-send-clarification"),
            attribute.data("action", "send-clarification"),
            attribute.data("request-id", card.id),
            event.on_click(ClarificationSubmitted(card.id)),
          ],
          [html.text("Отправить ответ")],
        ),
      ])
  }
}

/// The official response as the applicant sees it.
fn view_response_summary(card: RequestCard) -> Element(Msg) {
  case card.response {
    None -> html.span([], [])
    Some(response) ->
      html.div([attribute.class("page__panel")], [
        html.h3([attribute.class("page__panel-title")], [
          html.text("Официальный ответ"),
        ]),
        official_response(response, response.approved_at != None),
      ])
  }
}

/// The feedback widget of the applicant.
fn view_feedback_widget(card: RequestCard) -> Element(Msg) {
  html.div([attribute.class("page__panel")], [
    html.h3([attribute.class("page__panel-title")], [
      html.text("Обратная связь"),
    ]),
    html.p([attribute.class("page__lead")], [
      html.text(
        "Оценка понятности ответа не влияет на юридический статус заявки.",
      ),
    ]),
    feedback(card.feedback, fn(is_clear) {
      FeedbackSubmitted(card.id, is_clear)
    }),
  ])
}

/// P7.4 — the timeline of the request.
fn view_request_history(model: Model, _request_id: String) -> Element(Msg) {
  case model.card_state.card {
    None ->
      html.section([attribute.class("page")], [
        view_error(model.card_state.error),
      ])
    Some(card) ->
      html.section([attribute.class("page")], [
        html.h2([attribute.class("page__title")], [
          html.text("История заявки " <> short_request_id(card.id)),
        ]),
        html.p([attribute.class("page__lead")], [
          html.text(
            "Каждое изменение статуса зафиксировано сервером с указанием "
              <> "исполнителя и времени.",
          ),
        ]),
        timeline(card.timeline),
        html.div([attribute.class("page__links")], [
          html.a(
            [
              attribute.href("/request/" <> card.id <> "/detail"),
              attribute.data("action", "open-card"),
            ],
            [html.text("К карточке заявки")],
          ),
        ]),
      ])
  }
}

/// P7.5 — the moderator queue.
fn view_moderation_queue(model: Model) -> Element(Msg) {
  html.section([attribute.class("page")], [
    html.h2([attribute.class("page__title")], [
      html.text("Очередь модератора"),
    ]),
    html.p([attribute.class("page__lead")], [
      html.text(
        "Заявки, ожидающие действия. Переходы статусов проверяются сервером: "
          <> "недопустимый переход будет отклонён.",
      ),
    ]),
    view_queue_filters(model),
    view_error(model.queue_state.error),
    queue(model.queue_state.items, model.queue_state.total),
  ])
}

fn view_queue_filters(model: Model) -> Element(Msg) {
  html.div([attribute.class("filters")], [
    html.label([attribute.class("filters__field")], [
      html.span([], [html.text("Статус")]),
      html.select(
        [
          attribute.class("filters__select"),
          attribute.id("filter-status"),
          event.on_change(fn(value: String) {
            QueueStatusFilterChanged(value)
          }),
        ],
        [
          option("", "Все", model.queue_state.status_filter == ""),
          option("submitted", "Новые", model.queue_state.status_filter == "submitted"),
          option("accepted", "Принятые", model.queue_state.status_filter == "accepted"),
          option(
            "in_progress",
            "В работе",
            model.queue_state.status_filter == "in_progress",
          ),
          option(
            "clarification_requested",
            "Требуют уточнения",
            model.queue_state.status_filter == "clarification_requested",
          ),
          option(
            "answer_ready",
            "Ответ готов",
            model.queue_state.status_filter == "answer_ready",
          ),
          option(
            "completed",
            "Завершённые",
            model.queue_state.status_filter == "completed",
          ),
        ],
      ),
    ]),
    html.label([attribute.class("filters__field")], [
      html.span([], [html.text("Просроченные")]),
      html.input(
        [
          attribute.class("filters__checkbox"),
          attribute.id("filter-overdue"),
          attribute.type_("checkbox"),
          attribute.checked(model.queue_state.only_overdue),
          event.on_change(fn(_value: String) { QueueOverdueToggled }),
        ],
      ),
    ]),
  ])
}

fn option(value: String, label: String, selected: Bool) -> Element(Msg) {
  html.option(
    [attribute.value(value), attribute.selected(selected)],
    label,
  )
}

/// P7.6 — the response editor.
fn view_response_editor(model: Model, _request_id: String) -> Element(Msg) {
  case model.card_state.card {
    None ->
      html.section([attribute.class("page")], [
        view_error(model.card_state.error),
      ])
    Some(card) ->
      html.section([attribute.class("page")], [
        html.h2([attribute.class("page__title")], [
          html.text("Официальный ответ по заявке " <> short_request_id(card.id)),
        ]),
        html.p([attribute.class("page__lead")], [
          html.text(
            "Черновик письма. Обязательные реквизиты проверяет сервер: "
              <> "утвердить ответ без них нельзя.",
          ),
        ]),
        view_error(model.response_state.error),
        view_response_form(model, card),
        view_response_preview(model),
      ])
  }
}

fn view_response_form(model: Model, card: RequestCard) -> Element(Msg) {
  html.div([attribute.class("page__panel")], [
    html.div([attribute.class("response-form")], [
      html.div(
        [],
        list.map(response_requisites(), fn(requisite) {
          view_response_field(model, requisite.0, requisite.1)
        }),
      ),
    ]),
    html.div([attribute.class("btn-group")], [
      html.button(
        [
          attribute.class("btn btn--secondary"),
          attribute.id("btn-save-response"),
          attribute.data("action", "save-response"),
          attribute.data("request-id", card.id),
          event.on_click(SaveResponseRequested(card.id)),
        ],
        [html.text("Сохранить черновик")],
      ),
      html.button(
        [
          attribute.class("btn btn--ghost"),
          attribute.id("btn-toggle-preview"),
          attribute.data("action", "toggle-preview"),
          event.on_click(ResponsePreviewToggled),
        ],
        [html.text("Предпросмотр")],
      ),
      html.button(
        [
          attribute.class("btn btn--primary"),
          attribute.id("btn-approve-response"),
          attribute.data("action", "approve-response"),
          attribute.data("request-id", card.id),
          event.on_click(ApproveResponseRequested(card.id)),
        ],
        [html.text("Утвердить ответ")],
      ),
    ]),
  ])
}

fn view_response_field(model: Model, key: String, label: String) -> Element(Msg) {
  html.label([attribute.class("form__field")], [
    html.span([attribute.class("form__label")], [html.text(label)]),
    html.input(
      [
        attribute.class("form__input"),
        attribute.id("response-" <> key),
        attribute.data("requisite", key),
        attribute.value(draft_value(model.response_state.draft, key)),
        event.on_input(fn(value: String) {
          ResponseFieldChanged(key, value)
        }),
      ],
    ),
  ])
}

fn view_response_preview(model: Model) -> Element(Msg) {
  case model.response_state.preview {
    False -> html.span([], [])
    True ->
      case model.response_state.response {
        None ->
          html.div([attribute.class("page__panel")], [
            html.p([attribute.class("page__lead")], [
              html.text(
                "Предпросмотр появится после сохранения черновика.",
              ),
            ]),
          ])
        Some(response) ->
          html.div(
            [attribute.class("page__panel"), attribute.id("response-preview")],
            [
              official_response(response, response.approved_at != None),
            ],
          )
      }
  }
}

/// P7.7 — the metrics.
fn view_metrics(model: Model) -> Element(Msg) {
  html.section([attribute.class("page")], [
    html.h2([attribute.class("page__title")], [
      html.text("Метрики эффективности 360"),
    ]),
    html.p([attribute.class("page__lead")], [
      html.text(
        "Показатели считаются по реальным событиям в базе. Там, где данных "
          <> "недостаточно, выводится «Недостаточно данных».",
      ),
    ]),
    view_error(model.metrics_state.error),
    metrics(model.metrics_state.items),
  ])
}

/// An error block.
fn view_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> html.span([], [])
    Some(text) ->
      html.div(
        [attribute.class("notice notice--error"), attribute.role("alert")],
        [html.text(text)],
      )
  }
}

/// A short form of a request id for the headings.
fn short_request_id(id: String) -> String {
  string.slice(id, 0, 8)
}

/// S0 — Старт.
fn view_start(model: Model) -> Element(Msg) {
  html.div([attribute.id("screen-start")], [
    view_hero(),
    view_capabilities(),
    view_maturity(model),
    view_how(),
    view_demo_result(),
    view_proof(),
    view_faq(model),
    view_final_cta(),
  ])
}

/// HERO — ценность для корпоративного пользователя.
fn view_hero() -> Element(Msg) {
  html.section([attribute.id("hero"), attribute.class("hero")], [
    html.h1([], [html.text("Внутренние заявки — без возвратов")]),
    html.p([attribute.class("subtitle")], [
      html.text(
        "Сотрудник описывает запрос своими словами, сервис уточняет недостающее "
          <> "и указывает пункт положения, на который опирается каждое требование. "
          <> "Руководитель видит причины возвратов и узкие места регламента.",
      ),
    ]),
    html.div([attribute.class("hero-cta")], [
      html.button(
        [
          attribute.id("btn-start"),
          attribute.class("primary"),
          event.on_click(Navigate("/describe")),
        ],
        [html.text("Начать оценку")],
      ),
      html.a(
        [
          attribute.href("#how"),
          attribute.class("secondary-link"),
        ],
        [html.text("Как это работает ↓")],
      ),
    ]),
    html.p([attribute.class("demo-note")], [
      html.text(
        "Демо-стенд: положение синтетическое, не действующий нормативный акт.",
      ),
    ]),
  ])
}

/// CAPABILITIES — 4 подтверждённых сценария.
fn view_capabilities() -> Element(Msg) {
  html.section([attribute.id("capabilities"), attribute.class("cards")], [
    html.h2([], [html.text("Что умеет сервис")]),
    html.div([attribute.class("card-grid")], [
      html.article([attribute.class("card")], [
        html.h3([], [html.text("Классификация запроса")]),
        html.p([], [html.text("Заявитель пишет свободным текстом — сервис определяет тип заявки и подсказывает, какие поля обязательны.")]),
      ]),
      html.article([attribute.class("card")], [
        html.h3([], [html.text("Извлечение полей")]),
        html.p([], [html.text("Город, даты, источник финансирования, номер гранта — автоматически подставляются из текста.")]),
      ]),
      html.article([attribute.class("card")], [
        html.h3([], [html.text("Полнота с основанием")]),
        html.p([], [html.text("Каждое требование ссылается на конкретный пункт положения. Неполную заявку отправить нельзя.")]),
      ]),
      html.article([attribute.class("card")], [
        html.h3([], [html.text("Прозрачные возвраты")]),
        html.p([], [html.text("Исполнитель возвращает заявку с причиной и пунктом регламента. Заявитель видит, что исправить.")]),
      ]),
    ]),
  ])
}

/// MATURITY — интерактивная мини-оценка с прозрачной формулой.
fn view_maturity(model: Model) -> Element(Msg) {
  let score = compute_maturity(model.maturity_inputs)
  let level = maturity_label(score)
  html.section([attribute.id("maturity"), attribute.class("maturity")], [
    html.h2([], [html.text("Мини-оценка зрелости процесса")]),
    html.p([attribute.class("hint")], [
      html.text(
        "Передвиньте ползунки под ваш текущий процесс. Оценка считается по среднему "
          <> "трёх параметров. Это наглядный ориентир, а не анализ реальных данных.",
      ),
    ]),
    maturity_slider(model, "completeness", "Полнота первой заявки"),
    maturity_slider(model, "returns", "Доля возвратов"),
    maturity_slider(model, "speed", "Скорость прохождения"),
    html.div([attribute.id("maturity-result"), attribute.class("maturity-result")], [
      html.p([], [
        html.strong([], [html.text("Средний балл: ")]),
        html.text(string.inspect(score) <> " / 5 — " <> level),
      ]),
    ]),
  ])
}

fn maturity_slider(model: Model, name: String, label: String) -> Element(Msg) {
  let current = case dict.get(model.maturity_inputs, name) {
    Ok(v) -> v
    Error(_) -> 3
  }
  html.div([attribute.class("slider-row")], [
    html.label([attribute.for("slider-" <> name)], [html.text(label)]),
    html.input(
      [
        attribute.id("slider-" <> name),
        attribute.type_("range"),
        attribute.min("1"),
        attribute.max("5"),
        attribute.value(string.inspect(current)),
        event.on_input(fn(v: String) { MaturityChanged(name, int.parse(v) |> result.unwrap(current)) }),
      ],
    ),
    html.span([attribute.class("slider-value")], [
      html.text(string.inspect(current)),
    ]),
  ])
}

/// HOW — путь по CJM.
fn view_how() -> Element(Msg) {
  html.section([attribute.id("how"), attribute.class("how")], [
    html.h2([], [html.text("Как это работает")]),
    html.ol([attribute.class("how-steps")], [
      html.li([], [html.strong([], [html.text("Опишите запрос.")]), html.text(" Свободным текстом, без заученных формулировок.")]),
      html.li([], [html.strong([], [html.text("Заполните недостающее.")]), html.text(" Сервис покажет, какие поля требуются и на каком основании.")]),
      html.li([], [html.strong([], [html.text("Отправьте заявку.")]), html.text(" Полнота проверяется автоматически, отправить неполную нельзя.")]),
      html.li([], [html.strong([], [html.text("Получите результат.")]), html.text(" Статус виден исполнителю и заявителю, при возврате — причина с пунктом положения.")]),
    ]),
  ])
}

/// DEMO RESULT — реалистичный демонстрационный экран Result с пометкой.
fn view_demo_result() -> Element(Msg) {
  html.section([attribute.id("demo-result"), attribute.class("demo-result")], [
    html.h2([], [html.text("Как выглядит результат")]),
    html.p([attribute.class("demo-note")], [
      html.text("Демонстрационные данные. Реальный заявитель видит свой экран после отправки.")],
    ),
    html.div([attribute.class("result-card")], [
      html.p([], [html.strong([], [html.text("Заявка №demo-trip-001")]), html.text(" · статус: submitted")]),
      html.p([], [html.text("Командировка в Казань, 12–14 ноября 2026, источник — бюджет.")]),
      html.ul([], [
        html.li([], [html.text("✓ destination_city = Казань")]),
        html.li([], [html.text("✓ purpose = конференция")]),
        html.li([], [html.text("✓ start_date = 2026-11-12")]),
        html.li([], [html.text("✓ end_date = 2026-11-14")]),
        html.li([], [html.text("✓ funding_source = budget")]),
        html.li([], [html.text("✓ approver_id = user-1")]),
      ]),
    ]),
  ])
}

/// PROOF — прозрачные ограничения и методология.
fn view_proof() -> Element(Msg) {
  html.section([attribute.id("proof"), attribute.class("proof")], [
    html.h2([], [html.text("Что подтверждено, а что — нет")]),
    html.div([attribute.class("proof-grid")], [
      html.div([attribute.class("proof-yes")], [
        html.h3([], [html.text("Подтверждено")]),
        html.ul([], [
          html.li([], [html.text("Gleam + Lustre 5.x фронтенд собирается в Docker (32/32 unit-тестов проходят).")]),
          html.li([], [html.text("Gleam API + PostgreSQL: создание черновика работает через nginx proxy.")]),
          html.li([], [html.text("Сценарий заявитель → API → БД проверен на синтетическом DEMO-положении.")]),
          html.li([], [html.text("Прозрачная формула мини-оценки (среднее трёх параметров).")]),
        ]),
      ]),
      html.div([attribute.class("proof-no")], [
        html.h3([], [html.text("Не подтверждено / вне демо")]),
        html.ul([], [
          html.li([], [html.text("Цитаты из ПП РФ № 501 — файл положения не загружен, citation validation не пройдена.")]),
          html.li([], [html.text("Замеры живой LLM — endpoint Mellum/Ollama не подключён, цифры даны для эвристики.")]),
          html.li([], [html.text("Production CSRF/auth и панель исполнителя — отдельные задачи.")]),
          html.li([], [html.text("Реальные CustDev-интервью — не проводились, есть только desk research.")]),
        ]),
      ]),
    ]),
  ])
}

/// FAQ — честный MVP-виджет без живого AI.
fn view_faq(model: Model) -> Element(Msg) {
  html.section([attribute.id("faq"), attribute.class("faq")], [
    html.h2([], [html.text("Задать вопрос о продукте")]),
    html.p([attribute.class("hint")], [
      html.text(
        "В демо-стенде виджет фиксирует сообщение локально — "
          <> "это не ответ живого ассистента.",
      ),
    ]),
    case model.faq_sent {
      True ->
        html.div([attribute.id("faq-sent"), attribute.class("faq-sent")], [
          html.p([], [html.text("Спасибо. В демо-стенде сообщение сохранено в памяти браузера. В production будет отправлено в канал поддержки.")]),
        ])
      False ->
        html.form(
          [
            attribute.id("faq-form"),
            event.on_submit(fn(_form_data) { FaqSubmitted }),
          ],
          [
            html.textarea(
              [
                attribute.id("faq-input"),
                attribute.placeholder("Например: можно ли отправить заявку без номера гранта?"),
              ],
              "",
            ),
            html.button(
              [attribute.id("faq-submit"), attribute.type_("submit"), attribute.class("primary")],
              [html.text("Отправить вопрос")],
            ),
          ],
        )
    },
  ])
}

/// FINAL CTA — переход к существующему CJM.
fn view_final_cta() -> Element(Msg) {
  html.section([attribute.id("final-cta"), attribute.class("final-cta")], [
    html.h2([], [html.text("Готовы попробовать?")]),
    html.button(
      [
        attribute.id("btn-start-final"),
        attribute.class("primary"),
        event.on_click(Navigate("/describe")),
      ],
      [html.text("Начать оценку")],
    ),
  ])
}

fn compute_maturity(inputs) -> Float {
  let total = dict.fold(inputs, 0, fn(acc, _k, v) { acc + v })
  let n = dict.size(inputs)
  case n {
    0 -> 0.0
    _ -> {
      let as_float = case float.parse(int.to_string(total)) {
        Ok(f) -> f
        Error(_) -> 0.0
      }
      let n_float = case float.parse(int.to_string(n)) {
        Ok(f) -> f
        Error(_) -> 1.0
      }
      as_float /. n_float
    }
  }
}

fn maturity_label(score: Float) -> String {
  case score {
    s if s >=. 4.5 -> "процесс зрелый"
    s if s >=. 3.5 -> "хорошая база"
    s if s >=. 2.5 -> "есть что улучшить"
    _ -> "требует внимания"
  }
}


/// S1 — Описание запроса.
fn view_describe(model: Model) -> Element(Msg) {
  html.section([attribute.id("screen-describe"), attribute.class("screen")], [
    html.h2([], [html.text("Опишите запрос")]),
    html.p([], [
      html.text(
        "Напишите, что вам нужно, своими словами. Требования к заявке "
          <> "подскажем сами.",
      ),
    ]),
    html.form([event.on_submit(fn(_form_data: List(#(String, String))) { CreateDraft })], [
      html.label([attribute.attribute("for", "text")], [
        html.text("Свободный текст заявки"),
      ]),
      html.textarea(
        [
          attribute.id("text"),
          attribute.name("text"),
          attribute.rows(5),
          attribute.placeholder(
            "Например: Прошу учебную поездку в Казань 12-14 ноября 2026, "
              <> "цель — конференция.",
          ),
          attribute.value(model.text),
          event.on_input(fn(value: String) { TextChanged(value) }),
        ],
        model.text,
      ),
      html.p([attribute.id("status-1"), attribute.class("status")], [
        html.text(error_or(model.error_text, "")),
      ]),
      html.button(
        [
          attribute.id("btn-create"),
          attribute.type_("submit"),
          attribute.class("primary"),
          attribute.disabled(model.busy),
        ],
        [html.text("Создать черновик")],
      ),
    ]),
  ])
}

/// S2 — Уточнения: извлечённые поля, недостающее, основания требований.
fn view_clarify(model: Model) -> Element(Msg) {
  html.section([attribute.id("screen-clarify"), attribute.class("screen")], [
    html.h2([], [html.text("Проверьте заявку")]),
    view_request_summary(model),
    html.h3([], [html.text("Поля заявки")]),
    html.ul([attribute.id("fields-list")], render_field_inputs(model)),
    html.p([attribute.id("complete-msg"), attribute.class("hint")], [
      html.text(local_completion_hint(model)),
    ]),
    html.button(
      [
        attribute.id("btn-submit"),
        attribute.type_("button"),
        attribute.class("primary"),
        attribute.disabled(model.busy),
        event.on_click(SubmitRequest),
      ],
      [html.text("Отправить заявку")],
    ),
    view_server_hard_stops(model),
    view_server_missing(model),
    view_status(model),
  ])
}

/// S4 — Результат.
fn view_result(model: Model) -> Element(Msg) {
  html.section([attribute.id("screen-result"), attribute.class("screen")], [
    html.h2([], [html.text("Заявка отправлена")]),
    view_request_summary(model),
    html.p([attribute.id("result-note")], [
      html.text(
        "Заявка принята и передана исполнителю. Дальнейшая обработка "
          <> "ведётся исполнителем.",
      ),
    ]),
    html.p([attribute.id("status-2"), attribute.class("status")], [
      html.text(status_text(model)),
    ]),
  ])
}

/// The id / status / type summary block, shared by S2 and S4.
fn view_request_summary(model: Model) -> Element(Msg) {
  let request_id = case model.request {
    Some(request) -> request.id
    None -> "—"
  }
  let status = case model.request {
    Some(request) -> status_to_string(request.status)
    None -> "—"
  }
  let request_type = case model.request {
    Some(request) ->
      case request.request_type {
        Some(name) -> name
        None -> "—"
      }
    None -> "—"
  }
  html.div([attribute.class("summary")], [
    html.p([], [
      html.text("ID заявки: "),
      html.code([attribute.id("request-id")], [html.text(request_id)]),
    ]),
    html.p([], [
      html.text("Статус: "),
      html.code([attribute.id("request-status")], [html.text(status)]),
    ]),
    html.p([], [
      html.text("Тип заявки: "),
      html.code([attribute.id("request-type")], [html.text(request_type)]),
    ]),
  ])
}

/// The editable field inputs.
fn render_field_inputs(model: Model) -> List(Element(Msg)) {
  list.map(field_specs(), fn(spec) {
    let value = case dict.get(model.values, spec.name) {
      Ok(value) -> value
      Error(_) -> ""
    }
    let missing = is_in_server_missing(model.server_missing, spec.name)
    html.li(
      [
        attribute.class(
          case missing {
            True -> "field missing"
            False -> "field"
          },
        ),
        attribute.attribute("data-field", spec.name),
      ],
      [
        html.label([], [html.text(spec.label <> required_marker(spec))]),
        html.input([
          attribute.id("field-" <> spec.name),
          attribute.type_("text"),
          attribute.placeholder(spec.placeholder),
          attribute.value(value),
          event.on_input(fn(new_value: String) { FieldEdited(spec.name, new_value) }),
        ]),
      ],
    )
  })
}

/// The authoritative `missing[]` from the server, with the clause and the
/// literal quote. Nothing here is generated by the client.
fn view_server_missing(model: Model) -> Element(Msg) {
  case model.server_missing {
    [] ->
      html.div([attribute.id("server-missing")], [
        html.p([attribute.class("hint")], [
          html.text(
            "Сервер не сообщил о недостающих полях. Если отправка будет "
              <> "отклонена, основания появятся здесь.",
          ),
        ]),
      ])
    items ->
      html.div([attribute.id("server-missing")], [
        html.h3([], [html.text("Что требуется по положению")]),
        html.ul([], render_missing_items(items)),
      ])
  }
}

/// The blocking rules from the server.
///
/// Rendered as a separate, prominent block: a hard stop is NOT a missing
/// field. The applicant filled the field in, and the value itself is
/// prohibited by a regulation — so the submission is refused, not
/// postponed. The quote of the norm comes from the server, never from
/// the client.
fn view_server_hard_stops(model: Model) -> Element(Msg) {
  case model.server_hard_stops {
    [] ->
      html.div(
        [attribute.id("server-hard-stops"), attribute.class("hidden")],
        [],
      )
    hits ->
      html.div([attribute.id("server-hard-stops")], [
        html.h3([], [html.text("Отправка запрещена по требованиям законодательства")]),
        html.ul([], render_hard_stop_items(hits)),
      ])
  }
}

fn render_hard_stop_items(items: List(HardStopField)) -> List(Element(Msg)) {
  list.map(items, fn(item) {
    html.li(
      [
        attribute.attribute("data-field", item.field_name),
        attribute.attribute("data-action", item.action),
        attribute.class("hard-stop-item"),
      ],
      [
        html.strong([], [html.text(hard_stop_title(item))]),
        html.br([]),
        html.span([attribute.class("reason")], [html.text(item.reason)]),
        html.br([]),
        html.span([attribute.class("quote")], [html.text(item.quote)]),
        html.br([]),
        html.span([attribute.class("clause")], [
          html.text("Пункт положения: " <> hard_stop_clause_ref(item)),
        ]),
      ],
    )
  })
}

/// The human-readable normative reference of a blocking rule.
///
/// The server sends `clause_ref` ("Ст. 259 ч. 1 ТК РФ") since migration
/// 010. On an older server the field is absent and we fall back to the
/// raw clause id rather than showing an empty line.
fn hard_stop_clause_ref(item: HardStopField) -> String {
  case item.clause_ref {
    Some(ref) if ref != "" -> ref
    _ -> item.clause_id
  }
}

fn hard_stop_title(item: HardStopField) -> String {
  case item.action {
    "needs_employer_review" -> "Требуется подтверждение работодателя"
    _ -> "Отправка невозможна"
  }
}

fn render_missing_items(items: List(MissingField)) -> List(Element(Msg)) {
  list.map(items, fn(item) {
    html.li([attribute.attribute("data-field", item.field_name)], [
      html.strong([], [html.text(item.field_name <> required_marker_for(item))]),
      html.br([]),
      html.span([attribute.class("quote")], [html.text(item.quote)]),
      html.br([]),
      html.span([attribute.class("clause")], [
        html.text("Пункт положения: " <> missing_clause_ref(item)),
      ]),
    ])
  })
}

/// The human-readable normative reference of a missing requirement.
///
/// The server sends `clause_ref` ("Ст. 259 ч. 1 ТК РФ") since migration
/// 010. On an older server the field is absent and we fall back to the
/// raw clause id rather than showing an empty line.
fn missing_clause_ref(item: MissingField) -> String {
  case item.clause_ref {
    Some(ref) if ref != "" -> ref
    _ -> item.clause_id
  }
}

fn required_marker(spec: FieldSpec) -> String {
  case spec.required {
    True -> " *"
    False -> ""
  }
}

fn required_marker_for(item: MissingField) -> String {
  case item.required {
    True ->
      case item.conditional {
        True -> " (условное обязательное)"
        False -> " (обязательное)"
      }
    False -> ""
  }
}

fn is_in_server_missing(items: List(MissingField), name: String) -> Bool {
  list.any(items, fn(item) { item.field_name == name })
}

/// The status line under the submit button.
fn view_status(model: Model) -> Element(Msg) {
  html.p([attribute.id("status-2"), attribute.class("status")], [
    html.text(status_text(model)),
  ])
}

fn status_text(model: Model) -> String {
  case model.error_text {
    Some(reason) -> reason
    None ->
      case model.outcome {
        Some(outcome) -> outcome_text(outcome)
        None -> ""
      }
  }
}

fn outcome_text(outcome: SubmitOutcome) -> String {
  case outcome {
    SubmitSucceeded(timestamp) ->
      case timestamp {
        "" -> "Заявка отправлена."
        _ -> "Заявка отправлена: " <> timestamp
      }
    SubmitIncomplete(items) ->
      "Заявка неполная. Не хватает полей: "
      <> int.to_string(list.length(items))
      <> ". Основания — ниже."
    SubmitBlocked(hits) ->
      "Отправка запрещена: сработал запрет по требованиям законодательства ("
      <> int.to_string(list.length(hits))
      <> "). Основания — ниже."
    SubmitAlreadyDone -> "Заявка уже была отправлена ранее."
    SubmitNotFound -> "Заявка не найдена."
    SubmitConflict(current_status) ->
      "Отправка невозможна: текущий статус — " <> current_status <> "."
    SubmitServerError(status, _) ->
      "Ошибка сервера: HTTP " <> int.to_string(status) <> "."
    SubmitInvalid(reason) -> reason
  }
}

/// A hint about locally-detected empty fields. It is a hint, not the
/// authority — the server decides.
fn local_completion_hint(model: Model) -> String {
  let missing = locally_missing(field_specs(), model.values)
  case missing {
    [] -> "Все обязательные поля заполнены. Можно отправлять."
    items ->
      "Не хватает "
      <> int.to_string(list.length(items))
      <> " обязательных полей: "
      <> list.map(items, fn(spec) { spec.label })
      |> join_with(", ")
      <> "."
  }
}

fn error_or(error: Option(String), fallback: String) -> String {
  case error {
    Some(reason) -> reason
    None -> fallback
  }
}

/// Join a list of strings with a separator. `gleam/list` has no `join`
/// in gleam_stdlib 1.x, so we fold manually.
fn join_with(items: List(String), separator: String) -> String {
  list.fold(items, "", fn(acc, item) {
    case acc {
      "" -> item
      _ -> acc <> separator <> item
    }
  })
}


// -------------------------------------------------------------
// JS interop
// -------------------------------------------------------------

/// The current URL path. The app flag is ignored — the path always comes
/// from `window.location`, which is the server-side route.
@external(javascript, "./nav.mjs", "current_path")
fn current_path(flags: Nil) -> String

/// Navigate the browser to another path. A full page load is intentional:
/// it keeps the server-side routing model and makes F5 restore the screen.
@external(javascript, "./nav.mjs", "navigate_to")
fn navigate_to(path: String) -> Nil

// -------------------------------------------------------------
// App
// -------------------------------------------------------------

pub fn root() -> lustre.App(Nil, Model, Msg) {
  lustre.application(init, update, view)
}
pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

// -------------------------------------------------------------
// Phase 8 view wrappers
// -------------------------------------------------------------

fn view_automation_dashboard(model: Model) -> Element(Msg) {
  phase8_view.dashboard(
    model.automation_state.panel,
    model.automation_state.metrics,
    model.automation_state.settings,
    model.automation_state.loading,
    model.automation_state.error,
  )
  |> map(phase8_view_to_msg)
}

fn view_agent_checks(model: Model) -> Element(Msg) {
  phase8_view.agent_checks(model.agent_checks_state)
  |> map(phase8_view_to_msg)
}

fn view_exceptions(model: Model) -> Element(Msg) {
  phase8_view.exceptions(model.exceptions_state)
  |> map(phase8_view_to_msg)
}

fn view_journal(model: Model) -> Element(Msg) {
  phase8_view.journal(model.journal_state)
  |> map(phase8_view_to_msg)
}

fn view_settings(model: Model) -> Element(Msg) {
  let state = case model.pending_mode {
    "" -> model.settings_state
    _ ->
      automation_state.SettingsState(
        settings: phase8_client.AutomationSettings(
          ..model.settings_state.settings,
          mode: model.pending_mode,
        ),
        loading: model.settings_state.loading,
        saving: model.settings_state.saving,
        error: model.settings_state.error,
        notice: model.settings_state.notice,
      )
  }
  phase8_view.settings(state)
  |> map(phase8_view_to_msg)
}

/// Конвертирует внутренний `phase8_view.Msg` в строку-команду и затем
/// в `app.Msg`. Это разрывает циклическую зависимость между view и app.
fn phase8_view_to_msg(vmsg: phase8_view.Msg) -> Msg {
  case phase8_view.view_msg(vmsg) {
    "refresh" -> AutomationRefreshRequested
    "save" -> AutomationModeSaveRequested
    cmd ->
      case string.pop_grapheme(cmd) {
        Ok(#("n", rest)) ->
          case string.starts_with(rest, "av:") {
            True -> Navigate(string.drop_start(rest, 3))
            False -> AutomationRefreshRequested
          }
        Ok(#(verb, rest)) -> {
          case string.starts_with(rest, ":") {
            True -> {
              let arg = string.drop_start(rest, 1)
              case verb {
                "recheck" -> AgentRecheckRequested(arg)
                "resolve" -> ExceptionResolveRequested(arg)
                "filter" -> JournalFilterChanged(arg)
                "agent-filter" -> AgentFilterChanged(arg)
                "pick" -> AutomationModeSelected(arg)
                _ -> AutomationRefreshRequested
              }
            }
            False -> AutomationRefreshRequested
          }
        }
        Error(_) -> AutomationRefreshRequested
      }
  }
}

fn view_applicant_bell(model: Model) -> Element(Msg) {
  // Переиспользуем существующий notification feed и оборачиваем в Phase-8 layout.
  let button_label = case model.bell.loading {
    True -> "Загрузка..."
    False -> "Обновить"
  }
  html.div([attribute.class("page page-bell")], [
    html.header([attribute.class("page-header")], [
      html.h1([], [html.text("Колокольчик заявителя")]),
      html.button(
        [attribute.class("btn btn-secondary"), event.on_click(AutomationRefreshRequested)],
        [html.text(button_label)],
      ),
    ]),
    html.p([attribute.class("hint")], [
      html.text(
        "Непрочитанных: "
        <> int.to_string(model.bell.unread)
        <> " · в реальном времени от ИИ-агента сопровождения.",
      ),
    ]),
    notification_feed(
      model.bell.items,
      model.bell.unread,
      fn(request_id) { Navigate("/request/" <> request_id <> "/detail") },
      fn(notification_id) { NotificationRead(notification_id) },
    ),
  ])
}
