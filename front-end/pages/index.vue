<script setup lang="ts">
// services/web-demo/pages/index.vue
//
// Главный рабочий кабинет заявителя. Соответствует экрану S0
// (Старт) из Lustre + дашборд-виджет с метриками и быстрыми действиями.

const { metrics, requests } = useMockData()

const upcoming = computed(() => requests.value.filter((r) => r.status === 'clarification' || r.status === 'submitted').slice(0, 3))
const recent = computed(() => [...requests.value].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)).slice(0, 4))
</script>

<template>
  <div class="home">
    <PageHeader
      title="Добро пожаловать"
      lead="Здесь начинается работа с внутренними заявками. Сервис помогает собрать комплект документов и указывает основания требований."
      :crumbs="[{ label: 'Главная' }]"
    >
      <template #actions>
        <UButton to="/requests/new" icon="i-lucide-plus-circle" color="primary">Новая заявка</UButton>
        <UButton to="/requests" variant="ghost" icon="i-lucide-inbox">Мои заявки</UButton>
      </template>
    </PageHeader>

    <section class="grid">
      <div v-for="m in metrics" :key="m.label" class="metric-tile">
        <p class="label">{{ m.label }}</p>
        <p class="value" :class="`trend-${m.trend}`">{{ m.value }}</p>
        <p v-if="m.hint" class="hint">{{ m.hint }}</p>
      </div>
    </section>

    <section class="grid two-col">
      <div class="panel">
        <div class="panel-head">
          <h2>Требуют внимания</h2>
          <NuxtLink to="/requests" class="link">Все мои заявки →</NuxtLink>
        </div>
        <div v-if="upcoming.length === 0" class="empty">Нет заявок, требующих внимания.</div>
        <div v-for="r in upcoming" :key="r.id" class="row">
          <div class="row-main">
            <p class="row-title">{{ r.title }}</p>
            <p class="row-meta">Заявитель: {{ r.applicant }} · обновлено {{ formatRelative(r.updatedAt) }}</p>
          </div>
          <StatusBadge :status="r.status" />
          <NuxtLink :to="`/requests/${r.id}`" class="row-link">
            <UIcon name="i-lucide-chevron-right" class="size-4" />
          </NuxtLink>
        </div>
      </div>
      <div class="panel">
        <div class="panel-head">
          <h2>Недавние</h2>
        </div>
        <div v-for="r in recent" :key="r.id" class="row">
          <div class="row-main">
            <p class="row-title">{{ r.title }}</p>
            <p class="row-meta">{{ r.assigneeRole }} · {{ formatRelative(r.updatedAt) }}</p>
          </div>
          <StatusBadge :status="r.status" />
        </div>
      </div>
    </section>

    <section class="panel">
      <div class="panel-head">
        <h2>Что умеет сервис</h2>
      </div>
      <div class="features">
        <div class="feature">
          <div class="feature-icon"><UIcon name="i-lucide-sparkles" class="size-5" /></div>
          <h3>Распознавание по тексту</h3>
          <p>Опишите запрос свободным текстом — сервис сам определит тип заявки и подтянет требования.</p>
        </div>
        <div class="feature">
          <div class="feature-icon"><UIcon name="i-lucide-check-circle-2" class="size-5" /></div>
          <h3>Проверка комплектности</h3>
          <p>Сервис проверяет заявку до отправки и подсвечивает недостающие поля с основаниями.</p>
        </div>
        <div class="feature">
          <div class="feature-icon"><UIcon name="i-lucide-history" class="size-5" /></div>
          <h3>Прозрачная история</h3>
          <p>Все изменения статуса и комментарии исполнителей сохраняются в таймлайне заявки.</p>
        </div>
      </div>
    </section>
  </div>
</template>

<script lang="ts">
function formatRelative(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime()
  const h = Math.round(diff / 3600_000)
  if (h < 1) return 'только что'
  if (h < 24) return `${h} ч назад`
  const d = Math.round(h / 24)
  return `${d} д назад`
}
</script>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;
@use '~/assets/scss/mixins' as *;

.home {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.grid {
  display: grid;
  gap: $spacing-4;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
}

.grid.two-col {
  grid-template-columns: minmax(0, 2fr) minmax(0, 1fr);

  @media (max-width: #{$breakpoint-lg - 1px}) {
    grid-template-columns: 1fr;
  }
}

.metric-tile {
  background: $color-surface-overlay;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  padding: $spacing-4;
  display: flex;
  flex-direction: column;
  gap: $spacing-1;

  .label {
    margin: 0;
    color: $color-text-muted;
    font-size: 0.8125rem;
  }
  .value {
    margin: 0;
    font-size: 1.75rem;
    font-weight: 700;
    line-height: 1.25;
    @include tabular-numbers;
  }
  .value.trend-up {
    color: $color-success;
  }
  .value.trend-down {
    color: $color-danger;
  }
  .value.trend-flat {
    color: $color-text;
  }
  .hint {
    margin: 0;
    color: $color-text-subtle;
    font-size: 0.75rem;
  }
}

.panel {
  background: $color-surface-overlay;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  padding: $spacing-5;
  display: flex;
  flex-direction: column;
  gap: $spacing-4;
}

.panel-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: $spacing-3;

  h2 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
  }

  .link {
    font-size: 0.8125rem;
    color: $color-primary;
  }
}

.row {
  display: flex;
  align-items: center;
  gap: $spacing-3;
  padding: $spacing-3 $spacing-4;
  background: $color-surface;
  border: 1px solid $color-border-subtle;
  border-radius: $radius-sm;

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

  &-link {
    color: $color-text-subtle;
    text-decoration: none;

    &:hover {
      color: $color-primary;
    }
  }
}

.empty {
  padding: $spacing-6;
  text-align: center;
  color: $color-text-muted;
  font-size: 0.8125rem;
}

.features {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: $spacing-4;
}

.feature {
  background: $color-bg-subtle;
  border: 1px solid $color-border-subtle;
  border-radius: $radius-md;
  padding: $spacing-4;
  display: flex;
  flex-direction: column;
  gap: $spacing-2;

  h3 {
    margin: 0;
    font-size: 0.9375rem;
    font-weight: 600;
  }

  p {
    margin: 0;
    color: $color-text-muted;
    font-size: 0.8125rem;
    line-height: 1.55;
  }
}

.feature-icon {
  display: grid;
  place-items: center;
  width: 38px;
  height: 38px;
  border-radius: $radius-md;
  background: rgba(45, 212, 191, 0.12);
  color: $color-primary;
}
</style>
