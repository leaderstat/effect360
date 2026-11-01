// services/api/src/effectivnost_360/automation.gleam
//
// Фаза 8 — доменная модель режима автоматизации.
//
// Модуль PURE: ни одного SQL-вызова и ни одного HTTP-вызова. Здесь
// описаны только правила, а их применение живёт в `automation_repo.gleam`
// (данные) и `automation_router.gleam` (HTTP).
//
// ## РЕЖИМЫ АВТОМАТИЗАЦИИ
// ----------------------
//   manual   — агент только анализирует и предлагает; статусы не меняются.
//   confirm  — агент готовит переход, модератор утверждает (режим по умолчанию).
//   auto     — агент сам выполняет ТОЛЬКО заранее разрешённые, обратимые и
//              не имеющие юридических последствий переходы.
//
// ## ГРАНИЦА ОТВЕТСТВЕННОСТИ
// --------------------------
//   * Gleam — источник истины для статусов, прав доступа и бизнес-правил.
//   * LLM НИКОГДА не меняет статус. LLM только классифицирует, объясняет
//     ошибки и предлагает уточняющие вопросы.
//   * Юридически значимые переходы (`answer_ready`, `completed`) не имеют
//     автоматического варианта в принципе: их готовит агент, но применяет
//     уполномоченный человек.
//   * Автоматический режим разрешает только переход `submitted -> accepted`.
//     Этот переход обратим (заявку можно вернуть в `returned`), не меняет
//     правовой статус заявителя и не требует подписи.
//   * Правило «автоматический переход разрешён» проверяется ЗДЕСЬ, на сервере,
//     и не может быть обойдено агентом или интерфейсом.
//
// ## ЗАПРЕТ БЕСКОНЕЧНЫХ ЦИКЛОВ
// -----------------------------
// Автоматический переход `submitted -> accepted` ведёт в состояние, из
// которого автоматический переход невозможен. Кроме того, агент не
// обрабатывает заявку, которая уже не в статусе `submitted` — это
// отсекает повторную обработку при повторной доставке события.
import gleam/option.{type Option, None, Some}
import effectivnost_360/state_machine.{
  type Action, type Status, ActionAccept, ActionApplicantAnswered,
  ActionAnswerReady, ActionComplete, ActionRequestClarification, ActionStart,
  Submitted, action_to_string, is_allowed, parse_status, status_to_string,
  target_status,
}

/// The automation mode of the service.
///
/// Mirrors the `automation_settings.mode` CHECK constraint.
pub type AutomationMode {
  /// Агент анализирует и предлагает, но не меняет статусы.
  Manual
  /// Агент готовит переход, модератор утверждает. Режим по умолчанию.
  Confirm
  /// Агент сам выполняет только разрешённые обратимые переходы.
  Auto
  UnknownMode(String)
}

pub fn parse_mode(s: String) -> AutomationMode {
  case s {
    "manual" -> Manual
    "confirm" -> Confirm
    "auto" -> Auto
    other -> UnknownMode(other)
  }
}

pub fn mode_to_string(mode: AutomationMode) -> String {
  case mode {
    Manual -> "manual"
    Confirm -> "confirm"
    Auto -> "auto"
    UnknownMode(other) -> other
  }
}

/// A human-readable label of the mode for the interface.
pub fn mode_label(mode: AutomationMode) -> String {
  case mode {
    Manual -> "Ручной"
    Confirm -> "С подтверждением"
    Auto -> "Автоматический"
    UnknownMode(other) -> other
  }
}

/// A short description of what the mode means, shown next to the switch.
pub fn mode_description(mode: AutomationMode) -> String {
  case mode {
    Manual ->
      "Агенты анализируют заявки и предлагают действия, но не меняют статусы."
    Confirm ->
      "Агент готовит переход, модератор утверждает его вручную."
    Auto ->
      "Система сама выполняет только заранее разрешённые, обратимые и не имеющие юридических последствий переходы."
    UnknownMode(_) -> ""
  }
}

/// The default mode when nothing is stored yet: `confirm`.
///
/// Это безопасный режим: агент готовит решение, человек применяет.
pub fn default_mode() -> AutomationMode {
  Confirm
}

/// The default version of the automation rules.
pub fn default_rules_version() -> String {
  "v1"
}

// -------------------------------------------------------------
// The decision of the digital moderator
// -------------------------------------------------------------

/// The result of the deterministic check of a request.
pub type CheckResult {
  /// Проверка пройдена — заявка соответствует требованиям.
  Passed
  /// Данных недостаточно — нужен запрос уточнения заявителю.
  NeedsInfo
  /// Обнаружено противоречие или неопределённость — нужен человек.
  Ambiguous
  /// Проверка не завершилась (например, LLM недоступен).
  Failed
  /// Автоматизация выключена или режим не допускает действий.
  Skipped
}

pub fn check_result_to_string(result: CheckResult) -> String {
  case result {
    Passed -> "passed"
    NeedsInfo -> "needs_info"
    Ambiguous -> "ambiguous"
    Failed -> "error"
    Skipped -> "skipped"
  }
}

pub fn parse_check_result(s: String) -> CheckResult {
  case s {
    "passed" -> Passed
    "needs_info" -> NeedsInfo
    "ambiguous" -> Ambiguous
    "error" -> Failed
    "skipped" -> Skipped
    _ -> Failed
  }
}

/// A human-readable label of the check result.
pub fn check_result_label(result: CheckResult) -> String {
  case result {
    Passed -> "Проверка пройдена"
    NeedsInfo -> "Требуется уточнение"
    Ambiguous -> "Требуется решение человека"
    Failed -> "Проверка не завершена"
    Skipped -> "Автоматизация не применялась"
  }
}

/// One problem found by the check.
pub type Problem {
  Problem(
    /// The field the problem belongs to.
    field_name: String,
    /// A short machine-readable reason code.
    reason: String,
    /// A human-readable explanation.
    message: String,
    /// The clause (основание) the requirement comes from, if any.
    clause_id: String,
    /// The literal quote of the clause, if any.
    quote: String,
  )
}

/// One action the agent proposes (or performs).
pub type ProposedAction {
  ProposedAction(
    /// The state-machine action, e.g. "accept".
    action: String,
    /// The status the action leads to.
    target_status: String,
    /// Why the agent proposes it.
    reason: String,
    /// The rule that produced the proposal.
    rule_code: String,
  )
}

/// A single named check the agent performed.
pub type CheckItem {
  CheckItem(name: String, ok: Bool, detail: String)
}

/// The full result of the digital moderator's pass over a request.
pub type Decision {
  Decision(
    result: CheckResult,
    checks: List(CheckItem),
    problems: List(Problem),
    proposed_actions: List(ProposedAction),
    /// The clarification request text for the applicant (needs_info).
    clarification_request: String,
    /// A human-readable explanation of the result.
    reason: String,
    /// The rule that produced the decision.
    rule_code: String,
  )
}

// -------------------------------------------------------------
// Rules
// -------------------------------------------------------------

/// The rule identifiers. They are stored in `automation_actions.rule_code`
/// and `agent_checks.rule_code`, so they are part of the audit contract.
pub type Rule {
  /// Заявка прошла проверку полностью.
  RuleComplete
  /// Не хватает обязательных полей — запрос уточнения.
  RuleMissingFields
  /// Противоречие или неопределённость — человеку.
  RuleAmbiguous
  /// Проверка не завершилась (ошибка LLM) — человеку, статус не меняем.
  RuleLlmFailure
  /// Автоматизация выключена или режим не допускает действий.
  RuleModeBlocked
}

pub fn rule_to_string(rule: Rule) -> String {
  case rule {
    RuleComplete -> "complete"
    RuleMissingFields -> "missing_fields"
    RuleAmbiguous -> "ambiguous"
    RuleLlmFailure -> "llm_failure"
    RuleModeBlocked -> "mode_blocked"
  }
}

/// The rule that corresponds to a check result.
pub fn rule_for_result(result: CheckResult) -> Rule {
  case result {
    Passed -> RuleComplete
    NeedsInfo -> RuleMissingFields
    Ambiguous -> RuleAmbiguous
    Failed -> RuleLlmFailure
    Skipped -> RuleModeBlocked
  }
}

// -------------------------------------------------------------
// The automation policy
// -------------------------------------------------------------

/// Which actions MAY be executed automatically in the `auto` mode.
///
/// This is the whitelist of «заранее разрешённые, обратимые и не имеющие
/// юридических последствий» переходов. Everything outside the whitelist
/// requires a human — always, in every mode.
pub fn automatically_allowed_actions() -> List(Action) {
  // `ActionAccept` (submitted -> accepted):
  //   - обратим: модератор может вернуть заявку в `returned`;
  //   - не имеет юридических последствий: заявка ещё не рассмотрена;
  //   - не требует подписи.
  //
  // `ActionRequestClarification` (accepted|in_progress -> returned) НЕ входит
  // в список: он требует формулировки вопроса заявителю, то есть решения
  // человека. Вместо этого агент готовит ТЕКСТ запроса уточнения, а переход
  // выполняет модератор.
  [ActionAccept]
}

/// May the given action be executed automatically in the given mode?
///
/// `mode` matters only for `auto`: in `manual` and `confirm` nothing is
/// executed automatically, by definition.
pub fn may_execute_automatically(mode: AutomationMode, action: Action) -> Bool {
  case mode {
    Auto ->
      list_contains_action(
        action,
        automatically_allowed_actions(),
      )
    Manual | Confirm | UnknownMode(_) -> False
  }
}

/// May the agent change the status of a request that is currently in
/// `from_status` to `to_status` automatically?
///
/// Two conditions must hold:
///   1. The transition itself is legal (`is_allowed`).
///   2. The action leading to it is in the automatic whitelist.
pub fn may_transition_automatically(
  mode: AutomationMode,
  from_status: Status,
  to_status: Status,
) -> Bool {
  case find_action_to(from_status, to_status) {
    Some(action) ->
      is_allowed(from_status, to_status)
      && may_execute_automatically(mode, action)
    None -> False
  }
}

/// The action that leads from `from_status` to `to_status`, if any.
pub fn find_action_to(from_status: Status, to_status: Status) -> Option(Action) {
  list_find(
    fn(action) { target_status(action) == to_status },
    [
      ActionAccept,
      ActionStart,
      ActionRequestClarification,
      ActionApplicantAnswered,
      ActionAnswerReady,
      ActionComplete,
    ],
  )
}

/// The outcome of the agent's attempt to act on a request.
pub type AutomationDecision {
  /// The transition was executed automatically.
  TransitionApplied(action: String, from_status: String, to_status: String)
  /// The transition was prepared but a human must approve it.
  TransitionProposed(action: String, from_status: String, to_status: String)
  /// The agent is not allowed to act in this mode.
  TransitionBlocked(reason: String)
  /// The request is not in a state the agent may process.
  TransitionNotApplicable(reason: String)
}

/// Decide what the agent may do with a request that passed the check.
///
/// This is the decision function of the whole phase: it is PURE and is
/// unit-tested. The repository applies the result.
pub fn decide(
  mode: AutomationMode,
  current_status: Status,
  decision: Decision,
) -> AutomationDecision {
  // 1. A failed or skipped check never changes the status.
  case decision.result {
    Failed | Skipped ->
      TransitionBlocked(
        "Проверка не дала положительного результата — статус не изменён.",
      )
    Passed | NeedsInfo | Ambiguous -> {
      // 2. Only `submitted` is processed by the digital moderator. Any other
      //    status means the request was already handled — this is what stops
      //    duplicate processing on redelivery and infinite event loops.
      case current_status {
        Submitted -> {
          case decision.result {
            Passed -> {
              // 3. A complete request may be accepted automatically, but
              //    ONLY in the `auto` mode and only for a whitelisted action.
              case find_action_to(Submitted, target_status(ActionAccept)) {
                Some(action) ->
                  case may_execute_automatically(mode, action) {
                    True ->
                      TransitionApplied(
                        action: action_to_string(action),
                        from_status: status_to_string(current_status),
                        to_status: status_to_string(target_status(action)),
                      )
                    False ->
                      TransitionProposed(
                        action: action_to_string(action),
                        from_status: status_to_string(current_status),
                        to_status: status_to_string(target_status(action)),
                      )
                  }
                None -> TransitionNotApplicable("Нет допустимого действия для статуса.")
              }
            }
            NeedsInfo ->
              // A request for clarification is prepared by the agent but
              // applied by a human: the applicant must receive a wording
              // that a person has seen.
              TransitionProposed(
                action: action_to_string(ActionRequestClarification),
                from_status: status_to_string(current_status),
                to_status: status_to_string(target_status(ActionRequestClarification)),
              )
            Ambiguous ->
              // An ambiguous request goes to a human. No transition is
              // proposed at all.
              TransitionBlocked(
                "Обнаружена неопределённость — заявка передана человеку-модератору.",
              )
            Failed | Skipped ->
              TransitionBlocked("Проверка не дала положительного результата.")
          }
        }
        _ ->
          TransitionNotApplicable(
            "Заявка не в статусе «Отправлена» — повторная обработка не выполняется.",
          )
      }
    }
  }
}

/// Whether the mode allows the agent to run its check at all.
///
/// In every mode the agent ANALYSES (it may run the check and prepare a
/// proposal); only the automatic EXECUTION is mode-dependent. The check
/// itself is allowed in all modes — otherwise the panel would be empty in
/// manual mode, which contradicts the requirement «ручной: агенты анализируют
/// заявки и предлагают действия».
pub fn may_run_check(_mode: AutomationMode) -> Bool {
  True
}

/// Whether the agent may send notifications / prepare drafts in this mode.
///
/// Preparation of drafts and notifications is allowed in every mode: it does
/// not change the legal status of the request.
pub fn may_prepare_drafts(_mode: AutomationMode) -> Bool {
  True
}

// -------------------------------------------------------------
// Small list helpers (kept local to avoid an extra dependency)
// -------------------------------------------------------------

fn list_contains(target: String, items: List(String)) -> Bool {
  case items {
    [] -> False
    [first, ..rest] ->
      case first == target {
        True -> True
        False -> list_contains(target, rest)
      }
  }
}

fn list_contains_action(target: Action, items: List(Action)) -> Bool {
  case items {
    [] -> False
    [first, ..rest] ->
      case action_to_string(first) == action_to_string(target) {
        True -> True
        False -> list_contains_action(target, rest)
      }
  }
}

fn list_find(predicate: fn(Action) -> Bool, items: List(Action)) -> Option(Action) {
  case items {
    [] -> None
    [first, ..rest] ->
      case predicate(first) {
        True -> Some(first)
        False -> list_find(predicate, rest)
      }
  }
}

/// The list of modes, in the order they are shown in the interface.
pub fn all_modes() -> List(AutomationMode) {
  [Manual, Confirm, Auto]
}

/// Parse a mode from a query parameter, tolerating unknown values by falling
/// back to the default (safe) mode.
pub fn parse_mode_or_default(s: String) -> AutomationMode {
  case parse_mode(s) {
    UnknownMode(_) -> default_mode()
    other -> other
  }
}

/// The status a request must be in for the digital moderator to process it.
pub fn is_processable_status(status: Status) -> Bool {
  case status {
    Submitted -> True
    _ -> False
  }
}

/// Build the standard clarification request text from the missing fields.
///
/// The text is deterministic and built from the actual requirements — the
/// agent never invents a legal basis.
pub fn build_clarification_request(problems: List(Problem)) -> String {
  case problems {
    [] -> "Для продолжения рассмотрения нужны дополнительные сведения."
    _ -> {
      let fields =
        problems
        |> list_map(fn(problem) { problem.field_name })
        |> list_unique()
      "Для продолжения рассмотрения уточните, пожалуйста: "
      <> string_join(fields, ", ")
      <> ". Заявка вернётся в работу сразу после уточнения."
    }
  }
}

/// Build the reason text for a decision.
pub fn build_reason(result: CheckResult, problems: List(Problem)) -> String {
  case result {
    Passed -> "Все обязательные поля заполнены, противоречий не обнаружено."
    NeedsInfo -> {
      let count = list_length(problems)
      "Не заполнены обязательные поля: " <> int_to_string(count) <> "."
    }
    Ambiguous -> "Обнаружено противоречие или неопределённость в данных заявки."
    Failed -> "Проверка не завершилась из-за ошибки внешнего сервиса."
    Skipped -> "Автоматизация не применялась в текущем режиме."
  }
}

// -------------------------------------------------------------
// Local helpers
// -------------------------------------------------------------

fn list_map(items: List(a), fun: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [first, ..rest] -> [fun(first), ..list_map(rest, fun)]
  }
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn list_unique(items: List(String)) -> List(String) {
  case items {
    [] -> []
    [first, ..rest] ->
      case list_contains(first, rest) {
        True -> list_unique(rest)
        False -> [first, ..list_unique(rest)]
      }
  }
}

fn string_join(items: List(String), separator: String) -> String {
  case items {
    [] -> ""
    [first] -> first
    [first, ..rest] -> first <> separator <> string_join(rest, separator)
  }
}

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> int_to_string_positive(n)
  }
}

fn int_to_string_positive(n: Int) -> String {
  case n {
    0 -> ""
    _ ->
      case n / 10 {
        0 -> single_digit(n)
        rest -> int_to_string_positive(rest) <> single_digit(n - rest * 10)
      }
  }
}

fn single_digit(n: Int) -> String {
  case n {
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
}

/// The status of a request as parsed from the database.
pub fn status_of(raw: String) -> Status {
  parse_status(raw)
}
