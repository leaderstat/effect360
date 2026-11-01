<script setup lang="ts">
// services/web-demo/pages/requests/[id].vue
//
// Карточка заявки: сведения, таймлайн, ответственные, цитаты оснований.
// Соответствует P7.3 (Карточка заявки) и P7.4 (История) из Lustre.

const route = useRoute()
const { findRequest, typeLabel } = useMockData()

const id = computed(() => String(route.params.id))
const request = computed(() => findRequest(id.value))

const tab = ref<'overview' | 'history' | 'citations'>('overview')
</script>

<template>
  <div v-if="!request" class="not-found">
    <PageHeader title="Заявка не найдена" :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Мои заявки', to: '/requests' }, { label: id }]" />
    <div class="empty">Заявка с идентификатором «{{ id }}» не найдена в демо-наборе.</div>
  </div>
  <div v-else class="request-card">
    <PageHeader
      :title="request.title"
      :lead="request.body"
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Мои заявки', to: '/requests' }, { label: request.id }]"
    >
      <template #actions>
        <StatusBadge :status="request.status" />
        <UButton v-if="request.status === 'returned'" color="primary" icon="i-lucide-pencil">Исправить и отправить</UButton>
        <UButton v-if="request.status === 'clarification'" color="primary" icon="i-lucide-plus">Добавить поля</UButton>
      </template>
    </PageHeader>

    <nav class="tabs">
      <button :class="{ active: tab === 'overview' }" @click="tab = 'overview'">Сведения</button>
      <button :class="{ active: tab === 'history' }" @click="tab = 'history'">История</button>
      <button :class="{ active: tab === 'citations' }" @click="tab = 'citations'">Основания</button>
    </nav>

    <div v-if="tab === 'overview'" class="grid">
      <section class="panel">
        <h2>Параметры</h2>
        <dl class="kv-list">
          <div v-for="(value, key) in request.fields" :key="key" class="kv-row">
            <dt>{{ key }}</dt>
            <dd>{{ value }}</dd>
          </div>
        </dl>
        <div v-if="request.missingFields.length" class="missing">
          <p class="section-label">Не заполнено</p>
          <ul>
            <li v-for="m in request.missingFields" :key="m">
              <UIcon name="i-lucide-alert-triangle" class="size-4" />
              {{ m }}
            </li>
          </ul>
        </div>
      </section>
      <section class="panel">
        <h2>Маршрут</h2>
        <dl class="kv-list">
          <div class="kv-row"><dt>Тип</dt><dd>{{ typeLabel(request.type) }}</dd></div>
          <div class="kv-row"><dt>Заявитель</dt><dd>{{ request.applicant }}</dd></div>
          <div class="kv-row"><dt>Исполнитель</dt><dd>{{ request.assigneeRole }}</dd></div>
          <div class="kv-row"><dt>Создана</dt><dd>{{ formatDate(request.createdAt) }}</dd></div>
          <div class="kv-row"><dt>Обновлена</dt><dd>{{ formatDate(request.updatedAt) }}</dd></div>
        </dl>
      </section>
    </div>

    <div v-else-if="tab === 'history'" class="timeline">
      <div v-for="(e, i) in request.timeline" :key="i" class="timeline-item">
        <span class="dot" />
        <div class="timeline-body">
          <p class="timeline-title">{{ e.label }}</p>
          <p class="timeline-meta">{{ e.actor }} · {{ formatDate(e.at) }}</p>
          <p v-if="e.description" class="timeline-desc">{{ e.description }}</p>
        </div>
      </div>
    </div>

    <div v-else-if="tab === 'citations'" class="citations">
      <div v-for="c in request.citations" :key="c.label" class="citation">
        <p class="citation-label">{{ c.label }}</p>
        <p class="citation-snippet">«{{ c.snippet }}»</p>
      </div>
      <div v-if="!request.citations.length" class="empty">Для этой заявки нет привязанных цитат.</div>
    </div>
  </div>
</template>

<script lang="ts">
function formatDate(iso: string): string {
  return new Date(iso).toLocaleString('ru-RU', { dateStyle: 'short', timeStyle: 'short' })
}
</script>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;

.request-card {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.not-found {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.empty {
  padding: $spacing-6;
  text-align: center;
  color: $color-text-muted;
  background: $color-surface-overlay;
  border: 1px dashed $color-border-strong;
  border-radius: $radius-md;
}

.tabs {
  display: flex;
  gap: $spacing-1;
  border-bottom: 1px solid $color-border;

  button {
    padding: $spacing-3 $spacing-4;
    border: none;
    border-bottom: 2px solid transparent;
    background: transparent;
    color: $color-text-muted;
    font-family: inherit;
    font-size: 0.9375rem;
    font-weight: 500;
    cursor: pointer;
    margin-bottom: -1px;

    &:hover {
      color: $color-text;
    }

    &.active {
      color: $color-primary;
      border-bottom-color: $color-primary;
    }
  }
}

.grid {
  display: grid;
  grid-template-columns: minmax(0, 2fr) minmax(0, 1fr);
  gap: $spacing-4;

  @media (max-width: #{$breakpoint-lg - 1px}) {
    grid-template-columns: 1fr;
  }
}

.panel {
  background: $color-surface-overlay;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  padding: $spacing-5;
  display: flex;
  flex-direction: column;
  gap: $spacing-3;

  h2 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
  }
}

.section-label {
  margin: $spacing-3 0 $spacing-2;
  color: $color-text-subtle;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.kv-list {
  margin: 0;
  display: grid;
  gap: $spacing-2;
}

.kv-row {
  display: grid;
  grid-template-columns: minmax(160px, auto) minmax(0, 1fr);
  gap: $spacing-3;
  padding: $spacing-2 0;
  border-bottom: 1px solid $color-border-subtle;

  &:last-child {
    border-bottom: none;
  }

  dt {
    color: $color-text-muted;
    font-size: 0.8125rem;
  }

  dd {
    margin: 0;
    color: $color-text;
    word-break: break-word;
  }
}

.missing ul {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: $spacing-2;
}

.missing li {
  display: flex;
  align-items: center;
  gap: $spacing-2;
  color: $color-warning;
  font-size: 0.8125rem;
}

.timeline {
  display: flex;
  flex-direction: column;
  gap: $spacing-4;
  background: $color-surface-overlay;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  padding: $spacing-5;
}

.timeline-item {
  display: flex;
  gap: $spacing-3;
}

.dot {
  flex-shrink: 0;
  margin-top: 6px;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: $color-primary;
}

.timeline-title {
  margin: 0;
  font-size: 0.9375rem;
  font-weight: 500;
}

.timeline-meta {
  margin: 2px 0 0;
  color: $color-text-subtle;
  font-size: 0.75rem;
}

.timeline-desc {
  margin: $spacing-2 0 0;
  color: $color-text-muted;
  font-size: 0.8125rem;
}

.citations {
  display: flex;
  flex-direction: column;
  gap: $spacing-3;
}

.citation {
  background: $color-surface-overlay;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  padding: $spacing-4;
}

.citation-label {
  margin: 0 0 $spacing-1;
  color: $color-primary;
  font-size: 0.8125rem;
  font-weight: 600;
}

.citation-snippet {
  margin: 0;
  color: $color-text-muted;
  font-size: 0.9375rem;
  font-style: italic;
  line-height: 1.55;
}
</style>
