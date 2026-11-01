<script setup lang="ts">
// services/web-demo/pages/moderation/index.vue
//
// Очередь модерации исполнителя. Соответствует P7.5 (Очередь модератора)
// из Lustre: список заявок с фильтрами по типу, статусу и приоритету.

const { queue, typeLabel } = useMockData()

const filterType = ref<string>('all')
const filterStatus = ref<string>('all')

const filtered = computed(() => {
  return queue.value
    .filter((r) => filterType.value === 'all' || r.type === filterType.value)
    .filter((r) => filterStatus.value === 'all' || r.status === filterStatus.value)
})
</script>

<template>
  <div class="queue">
    <PageHeader
      title="Очередь модерации"
      lead="Заявки, ожидающие проверки. Используйте фильтры, чтобы быстро найти нужное."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Очередь модерации' }]"
    >
      <template #actions>
        <UButton variant="ghost" icon="i-lucide-download">Экспорт CSV</UButton>
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
        </select>
      </label>
      <label class="filter">
        <span class="filter-label">Статус</span>
        <select v-model="filterStatus" class="select">
          <option value="all">Все</option>
          <option value="submitted">Отправлена</option>
          <option value="in_review">На проверке</option>
          <option value="returned">Возвращена</option>
          <option value="clarification">Уточнения</option>
        </select>
      </label>
    </div>

    <p class="summary">Всего в очереди: {{ filtered.length }} · просрочено: {{ filtered.filter((r) => r.priority === 'overdue').length }}</p>

    <ul class="list">
      <li v-for="r in filtered" :key="r.id">
        <NuxtLink :to="`/moderation/${r.id}`" class="row">
          <div class="row-main">
            <p class="row-title">
              {{ r.title }}
              <span v-for="f in r.flags" :key="f" class="flag">{{ f }}</span>
            </p>
            <p class="row-meta">
              {{ typeLabel(r.type) }} · {{ r.applicant }} · {{ r.ageHours }} ч в очереди
            </p>
          </div>
          <StatusBadge :status="r.status" />
          <UIcon name="i-lucide-chevron-right" class="size-4 text-subtle" />
        </NuxtLink>
      </li>
    </ul>
  </div>
</template>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;
@use '~/assets/scss/mixins' as *;

.queue {
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

.summary {
  margin: 0;
  color: $color-text-subtle;
  font-size: 0.8125rem;
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
  border-left-width: 3px;
  border-radius: $radius-md;
  text-decoration: none;
  color: inherit;
  transition: background-color 120ms ease, border-color 120ms ease;

  &:hover {
    background: $color-surface-raised;
    border-color: $color-border-strong;
    border-left-color: $color-primary;
  }

  &-main {
    flex: 1;
    min-width: 0;
  }

  &-title {
    margin: 0;
    font-size: 0.9375rem;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: $spacing-2;
    flex-wrap: wrap;
  }

  &-meta {
    margin: 2px 0 0;
    color: $color-text-subtle;
    font-size: 0.75rem;
  }
}

.flag {
  display: inline-flex;
  align-items: center;
  padding: 2px 8px;
  border-radius: 999px;
  background: $color-surface-overlay;
  color: $color-text-muted;
  font-size: 11px;
  font-weight: 500;
}

.text-subtle {
  color: $color-text-subtle;
}
</style>
