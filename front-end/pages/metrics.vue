<script setup lang="ts">
// services/web-demo/pages/metrics.vue
//
// Метрики руководителя. Соответствует P7.7 (Метрики эффективности 360)
// из Lustre: операционные показатели + причины возвратов.

const { metrics, returnReasons } = useMockData()

const max = computed(() => Math.max(...returnReasons.value.map((r) => r.count), 1))
</script>

<template>
  <div class="metrics">
    <PageHeader
      title="Метрики эффективности 360"
      lead="Сводные показатели процесса за неделю. Данные демонстрационные."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Метрики' }]"
    >
      <template #actions>
        <UButton variant="ghost" icon="i-lucide-download">Экспорт CSV</UButton>
      </template>
    </PageHeader>

    <section class="grid">
      <div v-for="m in metrics" :key="m.label" class="tile">
        <p class="label">{{ m.label }}</p>
        <p class="value" :class="`trend-${m.trend}`">{{ m.value }}</p>
        <p v-if="m.hint" class="hint">{{ m.hint }}</p>
      </div>
    </section>

    <section class="panel">
      <h2>Топ причин возвратов</h2>
      <ul class="reasons">
        <li v-for="r in returnReasons" :key="r.reason">
          <div class="reason-row">
            <span class="reason-label">{{ r.reason }}</span>
            <span class="reason-count">{{ r.count }} · {{ Math.round(r.share * 100) }}%</span>
          </div>
          <div class="bar">
            <div class="bar-fill" :style="{ width: `${(r.count / max) * 100}%` }" />
          </div>
        </li>
      </ul>
    </section>

    <section class="panel">
      <h2>Что пока не измерено</h2>
      <p class="note">Эти показатели требуют реальных данных пилота. Без пилота они остаются гипотезами.</p>
      <ul class="missing-list">
        <li>Доля возвратов от общего числа заявок (нужен журнал).</li>
        <li>Среднее время одного цикла уточнения (нужен хронометраж).</li>
        <li>Стоимость обработки одной заявки (нужен ФОТ).</li>
        <li>LTV, CAC, ARPA, churn (нужны продажи).</li>
      </ul>
    </section>
  </div>
</template>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;
@use '~/assets/scss/mixins' as *;

.metrics {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.grid {
  display: grid;
  gap: $spacing-4;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
}

.tile {
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
  gap: $spacing-3;

  h2 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
  }
}

.reasons {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: $spacing-3;
}

.reason-row {
  display: flex;
  justify-content: space-between;
  gap: $spacing-3;
  font-size: 0.8125rem;
}

.reason-label {
  color: $color-text;
}

.reason-count {
  color: $color-text-muted;
  @include tabular-numbers;
}

.bar {
  height: 6px;
  border-radius: 3px;
  background: $color-surface-inset;
  overflow: hidden;
}

.bar-fill {
  height: 100%;
  background: $color-primary;
  border-radius: 3px;
}

.note {
  margin: 0;
  color: $color-text-muted;
  font-size: 0.8125rem;
}

.missing-list {
  margin: 0;
  padding: 0 0 0 $spacing-5;
  display: flex;
  flex-direction: column;
  gap: $spacing-2;
  color: $color-text-muted;
  font-size: 0.8125rem;
}
</style>
