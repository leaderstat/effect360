// services/web-demo/composables/useMockData.ts
//
// Слой мок-данных демо-контура.
//
// Принципы:
//   * Все данные синтетические. Ни одно поле не ссылается на реальных
//     людей, организации или номера заявок.
//   * Метки и тексты соответствуют реальным сущностям Lustre-приложения
//     (типы заявок, статусы, причины возвратов), но не претендуют на
//     статистику.
//   * Реализация в виде composable, чтобы любой компонент мог вызвать
//     useMockData() и получить согласованные данные, не повторяя
//     литобъекты на каждой странице.
//   * Мутации (например, добавление заявки в черновик) делаются через
//     useState, чтобы все страницы видели одно и то же состояние в
//     рамках сессии (HMR-safe).

import type {
  JournalEntry,
  MetricTile,
  ModerationQueueItem,
  NotificationItem,
  RequestItem,
  ReturnReason,
  SettingsMode
} from '~/types/domain'

const STATUS_LABELS: Record<string, string> = {
  draft: 'Черновик',
  clarification: 'Уточнения',
  submitted: 'Отправлена',
  in_review: 'На проверке',
  returned: 'Возвращена',
  approved: 'Согласована',
  rejected: 'Отклонена',
  completed: 'Исполнена'
}

const TYPE_LABELS: Record<string, string> = {
  business_trip: 'Командировка',
  reference: 'Справка',
  access: 'Доступ',
  equipment: 'Оборудование',
  training: 'Обучение'
}

const PRIORITY_LABELS: Record<string, string> = {
  low: 'Низкий',
  normal: 'Обычный',
  high: 'Высокий',
  overdue: 'Просрочен'
}

function nowMinus(hours: number): string {
  return new Date(Date.now() - hours * 3600 * 1000).toISOString()
}

const SEED_REQUESTS: RequestItem[] = [
  {
    id: 'demo-7c1a',
    title: 'Командировка Казань 12–14.11 на конференцию',
    type: 'business_trip',
    status: 'clarification',
    priority: 'normal',
    applicant: 'Иванов И.',
    assigneeRole: 'Кадры',
    createdAt: nowMinus(48),
    updatedAt: nowMinus(2),
    body: 'Нужно оформить командировку в Казань на конференцию по финтеху с 12 по 14 ноября. Финансирование — грант РНФ №24-18-00345. Будут билеты, проживание и суточные.',
    fields: {
      'Город': 'Казань',
      'Дата начала': '2026-11-12',
      'Дата окончания': '2026-11-14',
      'Цель': 'Конференция по финтеху',
      'Источник финансирования': 'Грант'
    },
    missingFields: ['Номер гранта', 'Программа конференции', 'Приглашение'],
    citations: [
      { label: 'п. 11 Положения о командировках', snippet: 'При грантовом финансировании указывается номер гранта.' },
      { label: 'п. 18 Положения о командировках', snippet: 'К заявке прикладывается программа мероприятия или приглашение.' }
    ],
    timeline: [
      { at: nowMinus(48), actor: 'Заявитель', label: 'Создан черновик', status: 'draft' },
      { at: nowMinus(46), actor: 'Сервис', label: 'Извлечены поля', status: 'draft' },
      { at: nowMinus(2), actor: 'Сервис', label: 'Запрошены недостающие поля', status: 'clarification' }
    ]
  },
  {
    id: 'demo-b302',
    title: 'Справка 2-НДФЛ для банка',
    type: 'reference',
    status: 'submitted',
    priority: 'low',
    applicant: 'Петрова А.',
    assigneeRole: 'Кадры',
    createdAt: nowMinus(72),
    updatedAt: nowMinus(12),
    body: 'Прошу подготовить справку 2-НДФЛ за 2025 год для ипотеки.',
    fields: { 'Вид справки': '2-НДФЛ', 'Период': '2025' },
    missingFields: [],
    citations: [
      { label: 'п. 3 Порядка выдачи справок', snippet: 'Справка 2-НДФЛ выдаётся по заявлению сотрудника.' }
    ],
    timeline: [
      { at: nowMinus(72), actor: 'Заявитель', label: 'Создан черновик', status: 'draft' },
      { at: nowMinus(70), actor: 'Сервис', label: 'Заявка отправлена', status: 'submitted' },
      { at: nowMinus(12), actor: 'Кадры', label: 'Принято в работу', status: 'in_review' }
    ]
  },
  {
    id: 'demo-9d44',
    title: 'Доступ к BI-отчётам',
    type: 'access',
    status: 'returned',
    priority: 'high',
    applicant: 'Сидоров К.',
    assigneeRole: 'ИТ-служба',
    createdAt: nowMinus(120),
    updatedAt: nowMinus(6),
    body: 'Нужен доступ к BI-отчётам по продажам для подготовки квартальной презентации.',
    fields: { 'Система': 'BI Sales', 'Роль': 'viewer' },
    missingFields: ['Обоснование руководителя'],
    citations: [
      { label: 'п. 5 Регламента доступа', snippet: 'Доступ к BI-отчётам предоставляется по согласованию с руководителем.' }
    ],
    timeline: [
      { at: nowMinus(120), actor: 'Заявитель', label: 'Создан черновик', status: 'draft' },
      { at: nowMinus(118), actor: 'Сервис', label: 'Заявка отправлена', status: 'submitted' },
      { at: nowMinus(12), actor: 'ИТ-служба', label: 'Принято в работу', status: 'in_review' },
      { at: nowMinus(6), actor: 'ИТ-служба', label: 'Возврат: требуется обоснование руководителя', description: 'Без согласования руководителя доступ к BI не выдаётся.', status: 'returned' }
    ]
  },
  {
    id: 'demo-1aa8',
    title: 'Заявка на ноутбук',
    type: 'equipment',
    status: 'approved',
    priority: 'normal',
    applicant: 'Кузнецова О.',
    assigneeRole: 'АХО',
    createdAt: nowMinus(240),
    updatedAt: nowMinus(48),
    body: 'Прошу выдать ноутбук для работы из дома. Старый вышел из строя.',
    fields: { 'Тип оборудования': 'Ноутбук', 'Обоснование': 'Замена вышедшего из строя' },
    missingFields: [],
    citations: [],
    timeline: [
      { at: nowMinus(240), actor: 'Заявитель', label: 'Создан черновик', status: 'draft' },
      { at: nowMinus(238), actor: 'Сервис', label: 'Заявка отправлена', status: 'submitted' },
      { at: nowMinus(96), actor: 'АХО', label: 'Принято в работу', status: 'in_review' },
      { at: nowMinus(48), actor: 'АХО', label: 'Согласовано', status: 'approved' }
    ]
  },
  {
    id: 'demo-55fe',
    title: 'Обучение: курс по продуктовому дизайну',
    type: 'training',
    status: 'completed',
    priority: 'low',
    applicant: 'Морозов Д.',
    assigneeRole: 'HR',
    createdAt: nowMinus(360),
    updatedAt: nowMinus(72),
    body: 'Заявка на оплату курса по продуктовому дизайну для развития компетенций.',
    fields: { 'Курс': 'Product Design Foundations', 'Провайдер': 'Skillbox', 'Стоимость': '64 000 ₽' },
    missingFields: [],
    citations: [],
    timeline: [
      { at: nowMinus(360), actor: 'Заявитель', label: 'Создан черновик', status: 'draft' },
      { at: nowMinus(358), actor: 'Сервис', label: 'Заявка отправлена', status: 'submitted' },
      { at: nowMinus(200), actor: 'HR', label: 'Принято в работу', status: 'in_review' },
      { at: nowMinus(96), actor: 'HR', label: 'Согласовано', status: 'approved' },
      { at: nowMinus(72), actor: 'HR', label: 'Исполнено', status: 'completed' }
    ]
  }
]

const SEED_QUEUE: ModerationQueueItem[] = [
  {
    id: 'demo-7c1a',
    title: 'Командировка Казань 12–14.11',
    type: 'business_trip',
    status: 'clarification',
    priority: 'normal',
    applicant: 'Иванов И.',
    submittedAt: nowMinus(48),
    ageHours: 48,
    flags: ['уточнения', 'грант']
  },
  {
    id: 'demo-9d44',
    title: 'Доступ к BI-отчётам',
    type: 'access',
    status: 'returned',
    priority: 'high',
    applicant: 'Сидоров К.',
    submittedAt: nowMinus(120),
    ageHours: 120,
    flags: ['возврат', 'согласование руководителя']
  },
  {
    id: 'demo-2cd6',
    title: 'Командировка Самара 20.11',
    type: 'business_trip',
    status: 'submitted',
    priority: 'overdue',
    applicant: 'Николаева Т.',
    submittedAt: nowMinus(72),
    ageHours: 72,
    flags: ['просрочено']
  },
  {
    id: 'demo-90ab',
    title: 'Справка о стаже работы',
    type: 'reference',
    status: 'in_review',
    priority: 'normal',
    applicant: 'Захаров С.',
    submittedAt: nowMinus(8),
    ageHours: 8,
    flags: ['плановая']
  },
  {
    id: 'demo-c0f1',
    title: 'Доступ к CRM',
    type: 'access',
    status: 'submitted',
    priority: 'normal',
    applicant: 'Соколова И.',
    submittedAt: nowMinus(20),
    ageHours: 20,
    flags: ['новая']
  }
]

const SEED_METRICS: MetricTile[] = [
  { label: 'Заявок за неделю', value: '128', trend: 'up' },
  { label: 'Доля возвратов', value: '17%', hint: 'Эвристика, не измерено', trend: 'flat' },
  { label: 'Среднее время согласования', value: '2.4 дн', trend: 'down' },
  { label: 'Обработано автоматически', value: '64%', hint: 'Эвристика, не измерено', trend: 'up' }
]

const SEED_RETURN_REASONS: ReturnReason[] = [
  { reason: 'Не указан номер гранта', count: 18, share: 0.32 },
  { reason: 'Нет программы мероприятия', count: 14, share: 0.25 },
  { reason: 'Не приложено обоснование руководителя', count: 9, share: 0.16 },
  { reason: 'Не заполнено поле «источник финансирования»', count: 7, share: 0.12 },
  { reason: 'Несоответствие сроков в заявке и приказе', count: 5, share: 0.09 },
  { reason: 'Прочее', count: 4, share: 0.07 }
]

const SEED_SETTINGS: SettingsMode[] = [
  {
    id: 'manual',
    label: 'Ручной режим',
    description: 'Исполнитель проверяет каждую заявку вручную. Сервис только структурирует и хранит.',
    status: 'active'
  },
  {
    id: 'confirm',
    label: 'Подтверждение модератора',
    description: 'Сервис предлагает черновик, исполнитель подтверждает или правит.',
    status: 'available'
  },
  {
    id: 'auto',
    label: 'Полная автоматизация',
    description: 'Сервис обрабатывает заявки автоматически по утверждённым правилам. Бета.',
    status: 'beta'
  }
]

const SEED_NOTIFICATIONS: NotificationItem[] = [
  {
    id: 'n-1',
    title: 'Заявка возвращена',
    message: '«Доступ к BI-отчётам» — требуется обоснование руководителя.',
    at: nowMinus(2),
    unread: true,
    level: 'warning'
  },
  {
    id: 'n-2',
    title: 'Запрошены уточнения',
    message: '«Командировка Казань 12–14.11» — нужно добавить номер гранта.',
    at: nowMinus(6),
    unread: true,
    level: 'info'
  },
  {
    id: 'n-3',
    title: 'Заявка согласована',
    message: '«Заявка на ноутбук» — согласовано АХО.',
    at: nowMinus(48),
    unread: false,
    level: 'success'
  },
  {
    id: 'n-4',
    title: 'Новое уведомление',
    message: 'Сервис автоматически подобрал основание для справки 2-НДФЛ.',
    at: nowMinus(72),
    unread: false,
    level: 'info'
  }
]

const SEED_JOURNAL: JournalEntry[] = [
  { id: 'j-1', at: nowMinus(1), actor: 'agent', action: 'Проверка комплектности', subject: 'demo-7c1a', result: 'pass' },
  { id: 'j-2', at: nowMinus(2), actor: 'system', action: 'Извлечение полей', subject: 'demo-7c1a', result: 'pass' },
  { id: 'j-3', at: nowMinus(5), actor: 'agent', action: 'Сопоставление с положением', subject: 'demo-9d44', result: 'fail' },
  { id: 'j-4', at: nowMinus(8), actor: 'human', action: 'Ручная правка', subject: 'demo-90ab', result: 'pending' },
  { id: 'j-5', at: nowMinus(12), actor: 'system', action: 'Публикация события', subject: 'demo-b302', result: 'pass' },
  { id: 'j-6', at: nowMinus(24), actor: 'agent', action: 'Авто-проверка цитаты', subject: 'demo-55fe', result: 'dismissed' }
]

export const useMockData = () => {
  const requests = useState<RequestItem[]>('demo:requests', () => SEED_REQUESTS)
  const queue = useState<ModerationQueueItem[]>('demo:queue', () => SEED_QUEUE)
  const metrics = useState<MetricTile[]>('demo:metrics', () => SEED_METRICS)
  const returnReasons = useState<ReturnReason[]>('demo:returnReasons', () => SEED_RETURN_REASONS)
  const settings = useState<SettingsMode[]>('demo:settings', () => SEED_SETTINGS)
  const notifications = useState<NotificationItem[]>('demo:notifications', () => SEED_NOTIFICATIONS)
  const journal = useState<JournalEntry[]>('demo:journal', () => SEED_JOURNAL)

  const findRequest = (id: string): RequestItem | undefined =>
    requests.value.find((r) => r.id === id)

  const statusLabel = (status: string): string => STATUS_LABELS[status] ?? status
  const typeLabel = (type: string): string => TYPE_LABELS[type] ?? type
  const priorityLabel = (priority: string): string => PRIORITY_LABELS[priority] ?? priority

  return {
    requests,
    queue,
    metrics,
    returnReasons,
    settings,
    notifications,
    journal,
    findRequest,
    statusLabel,
    typeLabel,
    priorityLabel
  }
}
