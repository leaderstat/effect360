<script setup lang="ts">
// services/web-demo/pages/automation.vue
//
// Панель автоматизации: сводка по цифровому модератору и очереди
// исключений. Соответствует P8.1 (Панель автоматизации) из Lustre.

const { settings } = useMockData()

const activeMode = ref('manual')

function activate(id: string): void {
  activeMode.value = id
}

const modeLabels: Record<string, string> = {
  manual: 'Ручной',
  confirm: 'Подтверждение',
  auto: 'Полная автоматизация'
}

const activeModeLabel = computed(() => modeLabels[activeMode.value] ?? activeMode.value)

function statusLabel(s: string): string {
  return ({ active: 'активен', available: 'доступен', beta: 'бета' } as Record<string, string>)[s] ?? s
}
</script>

<template>
  <div class="automation">
    <PageHeader
      title="Панель автоматизации"
      lead="Сводка по работе цифрового модератора: проверки, исключения, режим."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Панель автоматизации' }]"
    >
      <template #actions>
        <UButton to="/journal" variant="ghost" icon="i-lucide-scroll">Журнал событий</UButton>
        <UButton to="/settings" color="primary" icon="i-lucide-sliders-horizontal">Настройки режима</UButton>
      </template>
    </PageHeader>

    <section class="grid">
      <div class="tile">
        <p class="label">Проверок за час</p>
        <p class="value">42</p>
        <p class="hint">успешных: 38 · ошибок: 4</p>
      </div>
      <div class="tile">
        <p class="label">Очередь исключений</p>
        <p class="value trend-down">7</p>
        <p class="hint">требуется решение человека</p>
      </div>
      <div class="tile">
        <p class="label">Текущий режим</p>
        <p class="value">{{ activeModeLabel }}</p>
        <p class="hint">переключается в Настройках</p>
      </div>
      <div class="tile">
        <p class="label">Цитаты проверены</p>
        <p class="value">128</p>
        <p class="hint">из 128 в этом периоде</p>
      </div>
    </section>

    <section class="panel">
      <h2>Режимы работы</h2>
      <div class="modes">
        <button
          v-for="m in settings"
          :key="m.id"
          :class="['mode', { active: activeMode === m.id }]"
          @click="activate(m.id)"
        >
          <div class="mode-head">
            <h3>{{ m.label }}</h3>
            <span class="status" :class="`status-${m.status}`">{{ statusLabel(m.status) }}</span>
          </div>
          <p>{{ m.description }}</p>
        </button>
      </div>
    </section>

    <section class="panel">
      <h2>Что показывает панель</h2>
      <ul class="explain">
        <li>Проверки комплектности по последним 128 заявкам.</li>
        <li>Очередь исключений — заявки, которые цифровой модератор не может обработать автоматически.</li>
        <li>Текущий режим автоматизации (ручной / подтверждение / полный).</li>
        <li>Дословная проверка цитат на соответствие основаниям.</li>
      </ul>
    </section>
  </div>
</template>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;
@use '~/assets/scss/mixins' as *;

.automation {
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
    color: $color-text;
  }
  .value.trend-down {
    color: $color-danger;
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

  h2 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
  }
}

.modes {
  display: grid;
  gap: $spacing-4;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
}

.mode {
  display: flex;
  flex-direction: column;
  gap: $spacing-2;
  padding: $spacing-4;
  background: $color-surface;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  text-align: left;
  cursor: pointer;
  font-family: inherit;
  color: inherit;
  font-size: inherit;

  &:hover {
    background: $color-surface-raised;
    border-color: $color-border-strong;
  }

  &.active {
    border-color: $color-primary;
    background: rgba(45, 212, 191, 0.08);
  }

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

.mode-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: $spacing-3;
}

.status {
  font-size: 11px;
  font-weight: 500;
  padding: 2px 8px;
  border-radius: 999px;
}

.status-active {
  background: rgba(74, 222, 128, 0.12);
  color: $color-success;
}

.status-available {
  background: rgba(96, 165, 250, 0.10);
  color: $color-info;
}

.status-beta {
  background: rgba(251, 191, 36, 0.12);
  color: $color-warning;
}

.explain {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: $spacing-2;

  li {
    padding-left: $spacing-4;
    position: relative;
    color: $color-text-muted;
    font-size: 0.8125rem;

    &::before {
      content: '·';
      position: absolute;
      left: 0;
      color: $color-primary;
      font-weight: 700;
    }
  }
}
</style>
