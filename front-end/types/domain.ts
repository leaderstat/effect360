// services/web-demo/types/domain.ts
//
// Типы доменных сущностей демо-контура. Не повторяют API контракт
// backend один-к-одному: упрощены под демонстрационные сценарии и
// снабжены комментариями для тех, кто будет сопоставлять мок с реальным
// контрактом.

export type RequestStatus =
  | 'draft'
  | 'clarification'
  | 'submitted'
  | 'in_review'
  | 'returned'
  | 'approved'
  | 'rejected'
  | 'completed'

export type RequestType =
  | 'business_trip'
  | 'reference'
  | 'access'
  | 'equipment'
  | 'training'

export type RequestPriority = 'low' | 'normal' | 'high' | 'overdue'

export interface RequestActor {
  /** Обезличенный идентификатор, например "R-001". */
  id: string
  /** Российская должность. */
  role: string
  /** Обезличенный тип организации. */
  orgType: 'commercial' | 'government' | 'university' | 'ngo'
}

export interface RequestTimelineEvent {
  /** ISO-строка. */
  at: string
  /** Кто инициировал событие. */
  actor: string
  /** Короткое название события. */
  label: string
  /** Описание, видимое пользователю. */
  description?: string
  /** Статус запроса после события. */
  status: RequestStatus
}

export interface RequestItem {
  id: string
  /** Короткое название, например "Командировка Казань 12–14.11". */
  title: string
  type: RequestType
  status: RequestStatus
  priority: RequestPriority
  /** Обезличенное ФИО заявителя, например "Иванов И." */
  applicant: string
  /** Назначенный исполнитель (роль). */
  assigneeRole: string
  /** Дата создания (ISO). */
  createdAt: string
  /** Последнее обновление (ISO). */
  updatedAt: string
  /** Свободный текст обращения. */
  body: string
  /** Извлечённые поля (ключ → значение). */
  fields: Record<string, string>
  /** Незаполненные обязательные поля. */
  missingFields: string[]
  /** Список ссылок на пункты положения. */
  citations: Array<{ label: string, snippet: string }>
  /** Хронология событий. */
  timeline: RequestTimelineEvent[]
}

export interface ModerationQueueItem {
  id: string
  title: string
  type: RequestType
  status: RequestStatus
  priority: RequestPriority
  applicant: string
  submittedAt: string
  ageHours: number
  flags: string[]
}

export interface MetricTile {
  label: string
  value: string
  unit?: string
  hint?: string
  trend?: 'up' | 'down' | 'flat'
}

export interface ReturnReason {
  reason: string
  count: number
  share: number
}

export interface SettingsMode {
  id: 'manual' | 'confirm' | 'auto'
  label: string
  description: string
  status: 'active' | 'available' | 'beta'
}

export interface NotificationItem {
  id: string
  title: string
  message: string
  /** ISO-строка. */
  at: string
  unread: boolean
  level: 'info' | 'warning' | 'danger' | 'success'
}

export interface JournalEntry {
  id: string
  at: string
  actor: 'system' | 'agent' | 'human'
  action: string
  subject: string
  result: 'pass' | 'fail' | 'pending' | 'dismissed'
}
