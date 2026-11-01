<script setup lang="ts">
// services/web-demo/pages/settings.vue
//
// Настройки режима автоматизации. Соответствует P8.5 (Переключатель
// режима автоматизации) из Lustre.

const { settings } = useMockData()

const activeMode = ref<string>('manual')

function save(): void {
  // В демо просто подтверждаем визуально.
  alert(`Режим «${activeMode.value}» сохранён (демо).`)
}
</script>

<template>
  <div class="settings">
    <PageHeader
      title="Настройки автоматизации"
      lead="Выберите режим работы цифрового модератора. Изменения вступают в силу сразу."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Настройки' }]"
    />

    <section class="panel">
      <h2>Режим работы</h2>
      <div class="modes">
        <button
          v-for="m in settings"
          :key="m.id"
          :class="['mode', { active: activeMode === m.id }]"
          @click="activeMode = m.id"
        >
          <div class="mode-head">
            <h3>{{ m.label }}</h3>
            <span class="status" :class="`status-${m.status}`">{{ statusLabel(m.status) }}</span>
          </div>
          <p>{{ m.description }}</p>
        </button>
      </div>
      <div class="footer">
        <UButton variant="ghost" @click="activeMode = 'manual'">Сбросить</UButton>
        <UButton color="primary" icon="i-lucide-save" @click="save">Сохранить</UButton>
      </div>
    </section>

    <section class="panel">
      <h2>Что нужно сделать перед изменением режима</h2>
      <ol class="checklist">
        <li>Проверить действующее положение и подтвердить требования (Гульнара).</li>
        <li>Запустить eval на реальном провайдере LLM (см. Backlog-LLM.md).</li>
        <li>Согласовать с владельцем процесса изменение уровня автоматизации.</li>
        <li>Обновить документацию и инструкции для сотрудников.</li>
      </ol>
    </section>
  </div>
</template>

<script lang="ts">
function statusLabel(s: string): string {
  return ({ active: 'активен', available: 'доступен', beta: 'бета' } as Record<string, string>)[s] ?? s
}
</script>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;

.settings {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
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

.footer {
  display: flex;
  justify-content: flex-end;
  gap: $spacing-2;
  padding-top: $spacing-3;
  border-top: 1px solid $color-border-subtle;
}

.checklist {
  margin: 0;
  padding: 0 0 0 $spacing-5;
  display: flex;
  flex-direction: column;
  gap: $spacing-2;
  color: $color-text-muted;
  font-size: 0.8125rem;
  line-height: 1.55;
}
</style>
