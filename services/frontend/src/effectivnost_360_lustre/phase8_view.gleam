// services/frontend/src/effectivnost_360_lustre/phase8_view.gleam
//
// View-функции для экранов Фазы 8. Только отображение данных, которые
// уже лежат в `phase8_state` — никаких прямых HTTP-вызовов.
//
// Сообщения Phase 8 определены прямо здесь (`pub type Msg`) и
// используются `app.gleam`'s update через этот тип. Это согласовано
// с реальной сигнатурой Lustre 5.x: `event.on_click(Msg)`.

import effectivnost_360_lustre/phase8_client.{
  type AgentCheck, type AgentException, type AutomationAction,
  type AutomationPanel, type AutomationSettings, type EfficiencyMetric,
  type ModeOption, mode_label, result_label,
}
import effectivnost_360_lustre/phase8_state as s
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/event
import lustre/element.{type Element}
import lustre/element/html

/// Собственные сообщения экранов Phase 8. `app.gleam` конвертирует их в
/// свои `Msg` через `view_msg` ниже — это разрывает циклическую зависимость
/// между `phase8_view.gleam` и `app.gleam`.
pub type Msg {
  PanelRefresh
  PanelOpenChecks
  PanelOpenExceptions
  PanelOpenJournal
  PanelOpenSettings
  AgentRecheck(String)
  AgentFilterChanged(String)
  ExceptionResolve(String)
  JournalFilterChanged(String)
  SettingsModePicked(String)
  SettingsSave
}

/// Преобразует `phase8_view.Msg` в строку-команду. `app.gleam` маппит
/// строки в свой `Msg`. Таблица соответствия — одна точка правды.
pub fn view_msg(msg: Msg) -> String {
  case msg {
    PanelRefresh -> "refresh"
    PanelOpenChecks -> "nav:/automation/checks"
    PanelOpenExceptions -> "nav:/automation/exceptions"
    PanelOpenJournal -> "nav:/automation/journal"
    PanelOpenSettings -> "nav:/automation/settings"
    AgentRecheck(id) -> "recheck:" <> id
    AgentFilterChanged(filter) -> "agent-filter:" <> filter
    ExceptionResolve(id) -> "resolve:" <> id
    JournalFilterChanged(mode) -> "filter:" <> mode
    SettingsModePicked(mode) -> "pick:" <> mode
    SettingsSave -> "save"
  }
}

// -------------------------------------------------------------
// Helpers
// -------------------------------------------------------------

fn chip(value: String, kind: String) -> Element(Msg) {
  html.span([attribute.class("chip chip-" <> kind)], [html.text(value)])
}

fn empty_state(message: String) -> Element(Msg) {
  html.div([attribute.class("empty-state")], [
    html.p([], [html.text(message)]),
  ])
}

fn metric_card(label: String, value: String) -> Element(Msg) {
  html.div([attribute.class("metric-card")], [
    html.div([attribute.class("metric-value")], [html.text(value)]),
    html.div([attribute.class("metric-label")], [html.text(label)]),
  ])
}

fn section_title(title: String, hint: String) -> Element(Msg) {
  html.div([attribute.class("section-head")], [
    html.h2([], [html.text(title)]),
    html.p([attribute.class("hint")], [html.text(hint)]),
  ])
}

// -------------------------------------------------------------
// Панель автоматизации — общая сводка
// -------------------------------------------------------------

pub fn dashboard(
  panel: AutomationPanel,
  metrics: List(EfficiencyMetric),
  settings: AutomationSettings,
  loading: Bool,
  error: Option(String),
) -> Element(Msg) {
  let checks_count = list.length(panel.checks)
  let actions_count = list.length(panel.actions)
  let exceptions_open = s.open_exception_count(s.AutomationState(
    settings: settings,
    panel: panel,
    metrics: metrics,
    loading: loading,
    error: error,
    last_action_notice: None,
    last_action_kind: "info",
  ))
  let tasks_count = list.length(panel.tasks)
  html.div([attribute.class("page page-automation")], [
    html.header([attribute.class("page-header")], [
      html.div([attribute.class("page-title")], [
        html.div([attribute.class("breadcrumb")], [
          html.span([], [html.text("Эффективность 360")]),
          html.span([attribute.class("current")], [html.text("Панель автоматизации")]),
        ]),
        html.h1([], [html.text("Панель автоматизации")]),
        html.p([], [
          html.span([attribute.class("page-mode-pill")], [
            html.span([attribute.class("page-mode-pill__dot")], []),
            html.text("Режим «" <> mode_label(panel.mode) <> "» · правила v" <> panel.rules_version),
          ]),
        ]),
      ]),
      html.div([attribute.class("page-actions")], [
        html.button(
          [attribute.class("btn btn-secondary"), event.on_click(PanelRefresh)],
          [html.text(case loading { True -> "Загрузка..." False -> "Обновить" })],
        ),
      ]),
    ]),
    case error {
      Some(reason) ->
        html.div([attribute.class("banner banner-error")], [html.text(reason)])
      None -> html.div([], [])
    },
    html.nav([attribute.class("subnav")], [
      html.button(
        [attribute.class("subnav-link active")],
        [html.text("Сводка")],
      ),
      html.button(
        [attribute.class("subnav-link"), event.on_click(PanelOpenChecks)],
        [html.text("Цифровой модератор")],
      ),
      html.button(
        [attribute.class("subnav-link"), event.on_click(PanelOpenExceptions)],
        [
          html.text("Исключения"),
          case exceptions_open {
            0 -> html.span([], [])
            n -> html.span([attribute.class("subnav-link__badge")], [html.text(int.to_string(n))])
          },
        ],
      ),
      html.button(
        [attribute.class("subnav-link"), event.on_click(PanelOpenJournal)],
        [html.text("Журнал действий")],
      ),
      html.button(
        [attribute.class("subnav-link"), event.on_click(PanelOpenSettings)],
        [html.text("Настройки")],
      ),
    ]),
    html.section([attribute.class("grid-4")], [
      metric_card("Проверок агента", int.to_string(checks_count)),
      metric_card(
        "Переходов выполнено",
        int.to_string(panel.actions |> count_transitions),
      ),
      metric_card(
        "Исключений открыто",
        int.to_string(exceptions_open),
      ),
      metric_card(
        "Задач модератору",
        int.to_string(tasks_count),
      ),
    ]),
    case metrics {
      [] -> empty_state("Метрики пока не посчитаны.")
      items ->
        html.section([attribute.class("grid-3")], list.map(items, metric_from_api))
    },
    html.section([attribute.class("grid grid--split")], [
      html.div([attribute.class("card")], [
        section_title(
          "Результаты проверок",
          "Агрегат по всем записям agent_checks.",
        ),
        results_summary(panel.checks),
      ]),
      html.div([attribute.class("card")], [
        section_title(
          "Последние действия",
          "Свежие записи automation_actions.",
        ),
        case panel.actions {
          [] -> empty_state("Действий ещё нет.")
          items -> actions_table(list.take(items, 5))
        },
      ]),
    ]),
    html.footer([attribute.class("page-footer")], [
      html.text("Всего автоматических действий: " <> int.to_string(actions_count)),
    ]),
  ])
}

/// Сводная диаграмма результатов проверок: полоска с зелёным, жёлтым
/// и красным сегментами, а также список «passed/needs_info/ambiguous».
fn results_summary(items: List(AgentCheck)) -> Element(Msg) {
  let total = list.length(items)
  let passed = list.count(items, fn(c) { c.result == "passed" })
  let needs = list.count(items, fn(c) { c.result == "needs_info" })
  let ambig = list.count(items, fn(c) { c.result == "ambiguous" })
  let other = total - passed - needs - ambig
  let pct = fn(n: Int) -> String {
    case total {
      0 -> "0%"
      _ -> {
        let scaled = n * 10000 / total
        let whole = scaled / 100
        let frac = scaled % 100
        int.to_string(whole) <> "." <> int_to_string_padded(frac) <> "%"
      }
    }
  }
  let total_label = case total {
    0 -> "Нет данных"
    n -> int.to_string(n) <> " заявок"
  }
  html.div([attribute.class("results-summary")], [
    html.p([attribute.class("results-summary__total")], [
      html.text(total_label),
      html.span([attribute.class("results-summary__hint")], [
        html.text("Разбивка по результатам проверок"),
      ]),
    ]),
    html.div([attribute.class("results-summary__bar")], [
      case total {
        0 -> html.span([], [])
        _ -> {
          let segs = [
            #("passed", passed),
            #("needs_info", needs),
            #("ambiguous", ambig),
            #("other", other),
          ]
          html.div(
            [attribute.class("results-summary__segments")],
            list.map(list.filter(segs, fn(seg) {
              let #(_, n) = seg
              n > 0
            }), fn(seg) {
              let #(kind, n) = seg
              html.span(
                [
                  attribute.class(
                    "results-summary__segment results-summary__segment--" <> kind,
                  ),
                  attribute.style("width", pct(n)),
                  attribute.title(kind <> ": " <> int.to_string(n)),
                ],
                [],
              )
            }),
          )
        }
      },
    ]),
    html.ul([attribute.class("results-summary__legend")], [
      html.li([], [
        html.span([attribute.class("legend-dot legend-dot--passed")], []),
        html.text("Пройдены автоматически: " <> int.to_string(passed)),
      ]),
      html.li([], [
        html.span([attribute.class("legend-dot legend-dot--needs_info")], []),
        html.text("Нужны уточнения: " <> int.to_string(needs)),
      ]),
      html.li([], [
        html.span([attribute.class("legend-dot legend-dot--ambiguous")], []),
        html.text("Переданы человеку: " <> int.to_string(ambig)),
      ]),
    ]),
  ])
}

fn int_to_string_padded(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn metric_from_api(metric: EfficiencyMetric) -> Element(Msg) {
  let kind = case metric.delta {
    "" -> "neutral"
    other ->
      case string.starts_with(other, "-") {
        True -> "down"
        False -> "up"
      }
  }
  html.div([attribute.class("metric-card metric-" <> kind)], [
    html.div([attribute.class("metric-value")], [html.text(metric.value)]),
    html.div([attribute.class("metric-label")], [html.text(metric.label)]),
  ])
}

fn count_transitions(items: List(AutomationAction)) -> Int {
  list.count(items, fn(a) { a.action == "transition" })
}

fn recent_checks_table(items: List(AgentCheck)) -> Element(Msg) {
  html.table([attribute.class("data-table")], [
    html.thead([], [
      html.tr([], [
        html.th([], [html.text("Заявка")]),
        html.th([], [html.text("Результат")]),
        html.th([], [html.text("Правило")]),
        html.th([], [html.text("Версия")]),
        html.th([], [html.text("LLM")]),
        html.th([], [html.text("Длительность, мс")]),
        html.th([], [html.text("Обновлено")]),
      ]),
    ]),
    html.tbody([], list.map(items, fn(check) { html.tr([], [
          html.td([], [html.code([], [html.text(check.request_id)])]),
          html.td([], [chip(result_label(check.result), check.result)]),
          html.td([], [html.text(check.rule_code)]),
          html.td([], [html.text(check.rules_version)]),
          html.td([], [
            html.text(case check.llm_used {
              True -> "да"
              False -> "нет"
            }),
          ]),
          html.td([], [html.text(int.to_string(check.duration_ms))]),
          html.td([], [html.text(check.updated_at)]),
        ])
      }),
    ),
  ])
}

fn exceptions_table(items: List(AgentException)) -> Element(Msg) {
  html.table([attribute.class("data-table")], [
    html.thead([], [
      html.tr([], [
        html.th([], [html.text("Заявка")]),
        html.th([], [html.text("Тип")]),
        html.th([], [html.text("Статус")]),
        html.th([], [html.text("Основание")]),
        html.th([], [html.text("Создано")]),
      ]),
    ]),
    html.tbody([], list.map(items, fn(ex) {
        html.tr([], [
          html.td([], [html.code([], [html.text(ex.request_id)])]),
          html.td([], [chip(s.exception_kind_label(ex.kind), "kind")]),
          html.td([], [
            chip(s.exception_status_label(ex.status), ex.status),
          ]),
          html.td([], [html.text(ex.reason)]),
          html.td([], [html.text(ex.created_at)]),
        ])
      }),
    ),
  ])
}

fn actions_table(items: List(AutomationAction)) -> Element(Msg) {
  html.table([attribute.class("data-table")], [
    html.thead([], [
      html.tr([], [
        html.th([], [html.text("Заявка")]),
        html.th([], [html.text("Действие")]),
        html.th([], [html.text("Из")]),
        html.th([], [html.text("В")]),
        html.th([], [html.text("Режим")]),
        html.th([], [html.text("Инициатор")]),
        html.th([], [html.text("Создано")]),
      ]),
    ]),
    html.tbody([], list.map(items, fn(a) {
        html.tr([], [
          html.td([], [html.code([], [html.text(a.request_id)])]),
          html.td([], [chip(s.action_label(a.action), a.action)]),
          html.td([], [html.text(option_or(a.from_status_label, "—"))]),
          html.td([], [html.text(option_or(a.to_status_label, "—"))]),
          html.td([], [chip(a.automation_mode, a.automation_mode)]),
          html.td([], [html.text(a.initiated_by)]),
          html.td([], [html.text(a.created_at)]),
        ])
      }),
    ),
  ])
}

fn option_or(value: Option(String), fallback: String) -> String {
  case value {
    Some(v) -> v
    None -> fallback
  }
}

// -------------------------------------------------------------
// Экран цифрового модератора
// -------------------------------------------------------------

pub fn agent_checks(state: s.AgentChecksState) -> Element(Msg) {
  let total = list.length(state.checks)
  let passed = list.count(state.checks, fn(c) { c.result == "passed" })
  let needs = list.count(state.checks, fn(c) { c.result == "needs_info" })
  let ambig = list.count(state.checks, fn(c) { c.result == "ambiguous" })
  let items = case state.filter_result {
    "all" -> state.checks
    "passed" -> list.filter(state.checks, fn(c) { c.result == "passed" })
    "needs_info" -> list.filter(state.checks, fn(c) { c.result == "needs_info" })
    "ambiguous" -> list.filter(state.checks, fn(c) { c.result == "ambiguous" })
    other -> list.filter(state.checks, fn(c) { c.result == other })
  }
  html.div([attribute.class("page page-checks")], [
    html.header([attribute.class("page-header")], [
      html.div([attribute.class("page-title")], [
        html.div([attribute.class("breadcrumb")], [
          html.span([], [html.text("Эффективность 360")]),
          html.span([attribute.class("current")], [html.text("Цифровой модератор")]),
        ]),
        html.h1([], [html.text("Цифровой модератор")]),
        html.p([], [html.text("Каждая строка — реальная запись таблицы agent_checks.")]),
      ]),
      html.div([attribute.class("page-actions")], [
        html.button(
          [attribute.class("btn btn-secondary"), event.on_click(PanelRefresh)],
          [html.text(case state.loading { True -> "Загрузка..." False -> "Обновить" })],
        ),
      ]),
    ]),
    case state.error {
      Some(reason) ->
        html.div([attribute.class("banner banner-error")], [html.text(reason)])
      None -> html.div([], [])
    },
    case state.notice {
      Some(text) ->
        html.div([attribute.class("banner banner-info")], [html.text(text)])
      None -> html.div([], [])
    },
    html.nav([attribute.class("subnav")], [
      filter_tab(state.filter_result == "all", "Все", int.to_string(total), AgentFilterChanged("all")),
      filter_tab(state.filter_result == "passed", "Пройдены", int.to_string(passed), AgentFilterChanged("passed")),
      filter_tab(state.filter_result == "needs_info", "Нужны уточнения", int.to_string(needs), AgentFilterChanged("needs_info")),
      filter_tab(state.filter_result == "ambiguous", "Переданы человеку", int.to_string(ambig), AgentFilterChanged("ambiguous")),
    ]),
    case items {
      [] -> empty_state("Проверок ещё нет — отправьте заявку.")
      rows ->
        html.table([attribute.class("data-table")], [
          html.thead([], [
            html.tr([], [
              html.th([], [html.text("Заявка")]),
              html.th([], [html.text("Результат")]),
              html.th([], [html.text("Причина")]),
              html.th([], [html.text("Правило")]),
              html.th([], [html.text("Версия")]),
              html.th([], [html.text("Действие")]),
            ]),
          ]),
          html.tbody([], list.map(rows, fn(check) { html.tr([], [
                html.td([], [html.code([], [html.text(check.request_id)])]),
                html.td([], [chip(s.check_result_label(check.result), check.result)]),
                html.td([], [html.text(check.reason)]),
                html.td([], [html.text(check.rule_code)]),
                html.td([], [html.text(check.rules_version)]),
                html.td([], [
                  html.button(
                    [
                      attribute.class("btn btn-small"),
                      event.on_click(AgentRecheck(check.request_id)),
                      case state.rechecking {
                        Some(id) if id == check.request_id ->
                          attribute.disabled(True)
                        _ -> attribute.attribute("data-active", "")
                      },
                    ],
                    [
                      html.text(case state.rechecking {
                        Some(id) if id == check.request_id -> "Запущено..."
                        _ -> "Перепроверить"
                      }),
                    ],
                  ),
                ]),
              ])
            })
          ),
        ])
    },
  ])
}

fn filter_tab(active: Bool, label: String, count: String, on_pick: Msg) -> Element(Msg) {
  let class = case active {
    True -> "subnav-link active"
    False -> "subnav-link"
  }
  html.button([attribute.class(class), event.on_click(on_pick)], [
    html.text(label),
    html.span([attribute.class("subnav-link__badge")], [html.text(count)]),
  ])
}

// -------------------------------------------------------------
// Очередь исключений
// -------------------------------------------------------------

pub fn exceptions(state: s.ExceptionsState) -> Element(Msg) {
  html.div([attribute.class("page page-exceptions")], [
    html.header([attribute.class("page-header")], [
      html.div([attribute.class("page-title")], [
        html.div([attribute.class("breadcrumb")], [
          html.span([], [html.text("Эффективность 360")]),
          html.span([attribute.class("current")], [html.text("Исключения")]),
        ]),
        html.h1([], [html.text("Исключения — требуется решение человека")]),
        html.p([], [html.text("Реальные заявки, которые агент не смог обработать автоматически.")]),
      ]),
      html.div([attribute.class("page-actions")], [
        html.button(
          [attribute.class("btn btn-secondary"), event.on_click(PanelRefresh)],
          [html.text(case state.loading { True -> "Загрузка..." False -> "Обновить" })],
        ),
      ]),
    ]),
    case state.error {
      Some(reason) ->
        html.div([attribute.class("banner banner-error")], [html.text(reason)])
      None -> html.div([], [])
    },
    case state.notice {
      Some(text) ->
        html.div([attribute.class("banner banner-info")], [html.text(text)])
      None -> html.div([], [])
    },
    case state.items {
      [] -> empty_state("Очередь пуста — агенты обработали все исключения.")
      items ->
        html.table([attribute.class("data-table")], [
          html.thead([], [
            html.tr([], [
              html.th([], [html.text("Заявка")]),
              html.th([], [html.text("Тип")]),
              html.th([], [html.text("Статус")]),
              html.th([], [html.text("Основание")]),
              html.th([], [html.text("Инициатор")]),
              html.th([], [html.text("Создано")]),
              html.th([], [html.text("Действие")]),
            ]),
          ]),
          html.tbody([], list.map(items, fn(ex) {
              html.tr([], [
                html.td([], [html.code([], [html.text(ex.request_id)])]),
                html.td([], [chip(s.exception_kind_label(ex.kind), "kind")]),
                html.td([], [
                  chip(s.exception_status_label(ex.status), ex.status),
                ]),
                html.td([], [html.text(ex.reason)]),
                html.td([], [html.text(ex.initiated_by)]),
                html.td([], [html.text(ex.created_at)]),
                html.td([], [
                  case ex.status {
                    "open" ->
                      html.button(
                        [
                          attribute.class("btn btn-small btn-primary"),
                          event.on_click(ExceptionResolve(ex.id)),
                          case state.resolving {
                            Some(id) if id == ex.id -> attribute.disabled(True)
                            _ -> attribute.attribute("data-active", "")
                          },
                        ],
                        [
                          html.text(case state.resolving {
                            Some(id) if id == ex.id -> "Решаем..."
                            _ -> "Разрешить"
                          }),
                        ],
                      )
                    _ -> html.span([], [html.text("—")])
                  },
                ]),
              ])
            })
          ),
        ])
    },
  ])
}

// -------------------------------------------------------------
// Журнал автоматических действий
// -------------------------------------------------------------

pub fn journal(state: s.JournalState) -> Element(Msg) {
  let items = case state.filter_mode {
    "all" -> state.items
    mode -> list.filter(state.items, fn(a) { a.automation_mode == mode })
  }
  let total = list.length(state.items)
  let count_for = fn(mode: String) -> String {
    int.to_string(list.count(state.items, fn(a) { a.automation_mode == mode }))
  }
  html.div([attribute.class("page page-journal")], [
    html.header([attribute.class("page-header")], [
      html.div([attribute.class("page-title")], [
        html.div([attribute.class("breadcrumb")], [
          html.span([], [html.text("Эффективность 360")]),
          html.span([attribute.class("current")], [html.text("Журнал действий")]),
        ]),
        html.h1([], [html.text("Журнал автоматических действий")]),
        html.p([], [html.text("История всех действий, выполненных автоматическими агентами.")]),
      ]),
      html.div([attribute.class("page-actions")], [
        html.button(
          [attribute.class("btn btn-secondary"), event.on_click(PanelRefresh)],
          [html.text(case state.loading { True -> "Загрузка..." False -> "Обновить" })],
        ),
      ]),
    ]),
    case state.error {
      Some(reason) ->
        html.div([attribute.class("banner banner-error")], [html.text(reason)])
      None -> html.div([], [])
    },
    html.nav([attribute.class("subnav")], [
      filter_tab(state.filter_mode == "all", "Все", int.to_string(total), JournalFilterChanged("all")),
      filter_tab(state.filter_mode == "auto", "Автоматический", count_for("auto"), JournalFilterChanged("auto")),
      filter_tab(state.filter_mode == "confirm", "С подтверждением", count_for("confirm"), JournalFilterChanged("confirm")),
      filter_tab(state.filter_mode == "manual", "Ручной", count_for("manual"), JournalFilterChanged("manual")),
    ]),
    case items {
      [] -> empty_state("Журнал пуст.")
      _ -> actions_table(items)
    },
  ])
}

fn option_attr(active: Bool) -> String {
  case active {
    True -> "filter-chip mode-card filter-chip-active"
    False -> "filter-chip mode-card"
  }
}

fn mode_cards(
  modes: List(ModeOption),
  current_mode: String,
  saving: Bool,
) -> List(Element(Msg)) {
  case modes {
    [] -> []
    [mode, ..rest] -> [
      render_mode_card(mode, current_mode, saving),
      ..mode_cards(rest, current_mode, saving)
    ]
  }
}

fn render_mode_card(
  mode: ModeOption,
  current_mode: String,
  saving: Bool,
) -> Element(Msg) {
  let active = mode.value == current_mode
  let action = case active {
    True -> "Активно"
    False -> "Выбрать"
  }
  html.div(
    [attribute.class(option_attr(active))],
    [
      html.div([attribute.class("mode-title")], [
        html.h3([], [html.text(mode.label)]),
        chip(mode.value, mode.value),
      ]),
      html.p([], [html.text(mode.description)]),
      case active {
        True -> html.span([attribute.class("mode-status")], [html.text(action)])
        False ->
          html.button(
            [
              attribute.class("btn btn-primary"),
              attribute.disabled(saving),
              event.on_click(SettingsModePicked(mode.value)),
            ],
            [
              html.text(case saving {
                True -> "Сохранение..."
                False -> action
              }),
            ],
          )
      },
    ],
  )
}

// -------------------------------------------------------------
// Настройки режима автоматизации
// -------------------------------------------------------------

pub fn settings(state: s.SettingsState) -> Element(Msg) {
  let modes = state.settings.available_modes
  html.div([attribute.class("page page-settings")], [
    html.header([attribute.class("page-header")], [
      html.div([attribute.class("page-title")], [
        html.div([attribute.class("breadcrumb")], [
          html.span([], [html.text("Эффективность 360")]),
          html.span([attribute.class("current")], [html.text("Настройки режима")]),
        ]),
        html.h1([], [html.text("Режим автоматизации")]),
        html.p([], [html.text("Выберите, как агенты будут обрабатывать заявки. Изменения сохраняются в PostgreSQL.")]),
      ]),
      html.div([attribute.class("page-actions")], [
        html.button(
          [attribute.class("btn btn-secondary"), event.on_click(PanelRefresh)],
          [html.text(case state.loading { True -> "Загрузка..." False -> "Обновить" })],
        ),
      ]),
    ]),
    case state.error {
      Some(reason) ->
        html.div([attribute.class("banner banner-error")], [html.text(reason)])
      None -> html.div([], [])
    },
    case state.notice {
      Some(text) ->
        html.div([attribute.class("banner banner-success")], [html.text(text)])
      None -> html.div([], [])
    },
    html.section([attribute.class("settings-card")], [
      html.p([attribute.class("hint")], [
        html.text("Текущий режим: "),
        chip(state.settings.mode_label, state.settings.mode),
        html.text(" · правила v" <> state.settings.rules_version),
      ]),
      html.div([attribute.class("mode-grid")], mode_cards(modes, state.settings.mode, state.saving)),
      html.div([attribute.class("settings-actions")], [
        html.button(
          [
            attribute.class("btn btn-primary btn-large"),
            attribute.disabled(state.saving),
            event.on_click(SettingsSave),
          ],
          [
            html.text(case state.saving {
              True -> "Сохранение..."
              False -> "Сохранить режим"
            }),
          ],
        ),
      ]),
    ]),
  ])
}
