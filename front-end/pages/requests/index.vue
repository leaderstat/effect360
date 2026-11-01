<script setup lang="ts">
// services/web-demo/pages/requests/index.vue
//
// Экран «Мои заявки»: список всех заявок текущего пользователя с
// фильтрами по статусу и типу. Соответствует P7.1 (Кабинет заявителя)
// из Lustre.

const { requests, typeLabel } = useMockData()

const filterType = ref<string>('all')
const filterStatus = ref<string>('all')

const filtered = computed(() => {
  return [...requests.value]
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    .filter((r) => filterType.value === 'all' || r.type === filterType.value)
    .filter((r) => filterStatus.value === 'all' || r.status === filterStatus.value)
})
</script>

<template>
  <div class="my-requests">
    <PageHeader
      title="Мои заявки"
      lead="Здесь все ваши заявки: черновики, отправленные, возвращённые и исполненные."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Мои заявки' }]"
    >
      <template #actions>
        <UButton to="/requests/new" color="primary" icon="i-lucide-plus-circle">Новая заявка</UButton>
      </template>
    </PageHeader>

    <div class="filters">
      <label class="filter">
        <span class="filter-label">Тип</span>
        <select v-model="filterType" class="select">
          <option value="all">Все</option>
          <option value="business_trip">{{ typeLabel('business_trip') }}</option>
          <option value="reference">{{ typeLabel('reference') }}</option>
          <option value="access">{{ typeLabel('access') }}</option>
          <option value="equipment">{{ typeLabel('equipment') }}</option>
          <option value="training">{{ typeLabel('training') }}</option>
        </select>
      </label>
      <label class="filter">
        <span class="filter-label">Статус</span>
        <select v-model="filterStatus" class="select">
          <option value="all">Все</option>
          <option value="draft">Черновик</option>
          <option value="clarification">Уточнения</option>
          <option value="submitted">Отправлена</option>
          <option value="in_review">На проверке</option>
          <option value="returned">Возвращена</option>
          <option value="approved">Согласована</option>
          <option value="completed">Исполнена</option>
        </select>
      </label>
    </div>

    <div v-if="filtered.length === 0" class="empty">Нет заявок по выбранным фильтрам.</div>
    <ul v-else class="list">
      <li v-for="r in filtered" :key="r.id">
        <NuxtLink :to="`/requests/${r.id}`" class="row">
          <div class="row-main">
            <p class="row-title">{{ r.title }}</p>
            <p class="row-meta">
              {{ typeLabel(r.type) }} · обновлено {{ formatRelative(r.updatedAt) }}
            </p>
          </div>
          <StatusBadge :status="r.status" />
          <UIcon name="i-lucide-chevron-right" class="size-4 text-subtle" />
        </NuxtLink>
      </li>
    </ul>
  </div>
</template>

<script lang="ts">
function formatRelative(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime()
  const h = Math.round(diff / 3600_000)
  if (h < 1) return 'только что'
  if (h < 24) return `${h} ч назад`
  return `${Math.round(h / 24)} д назад`
}
</script>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;
@use '~/assets/scss/mixins' as *;

.my-requests {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.filters {
  display: flex;
  gap: $spacing-3;
  flex-wrap: wrap;
}

.filter {
  display: flex;
  flex-direction: column;
  gap: $spacing-1;
}

.filter-label {
  font-size: 0.75rem;
  color: $color-text-subtle;
}

.select {
  padding: $spacing-2 $spacing-3;
  border-radius: $radius-md;
  border: 1px solid $color-border;
  background: $color-surface-inset;
  color: $color-text;
  font-family: inherit;
  font-size: 0.8125rem;
  min-width: 180px;
}

.list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: $spacing-3;
}

.row {
  display: flex;
  align-items: center;
  gap: $spacing-3;
  padding: $spacing-4;
  background: $color-surface;
  border: 1px solid $color-border-subtle;
  border-radius: $radius-md;
  text-decoration: none;
  color: inherit;
  transition: background-color 120ms ease, border-color 120ms ease;

  &:hover {
    background: $color-surface-raised;
    border-color: $color-border-strong;
  }

  &-main {
    flex: 1;
    min-width: 0;
  }

  &-title {
    margin: 0;
    font-size: 0.9375rem;
    font-weight: 500;
    @include truncate;
  }

  &-meta {
    margin: 2px 0 0;
    color: $color-text-subtle;
    font-size: 0.75rem;
  }
}

.empty {
  padding: $spacing-12 $spacing-5;
  text-align: center;
  color: $color-text-muted;
  font-size: 0.8125rem;
  background: $color-surface-overlay;
  border: 1px dashed $color-border-strong;
  border-radius: $radius-md;
}

.text-subtle {
  color: $color-text-subtle;
}
</style>
