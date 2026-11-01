<script setup lang="ts">
// services/web-demo/pages/journal.vue
//
// Журнал событий автоматизации. Соответствует P8.4 (Журнал
// автоматических действий) из Lustre.

const { journal } = useMockData()
</script>

<template>
  <div class="journal">
    <PageHeader
      title="Журнал событий"
      lead="История автоматических и ручных действий сервиса. Данные демонстрационные."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Журнал событий' }]"
    >
      <template #actions>
        <UButton variant="ghost" icon="i-lucide-download">Экспорт CSV</UButton>
      </template>
    </PageHeader>

    <div class="table-wrap">
      <table class="data-table">
        <thead>
          <tr>
            <th>Когда</th>
            <th>Актор</th>
            <th>Действие</th>
            <th>Объект</th>
            <th>Результат</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="e in journal" :key="e.id">
            <td class="mono">{{ formatDate(e.at) }}</td>
            <td>
              <span class="actor" :class="`actor-${e.actor}`">{{ actorLabel(e.actor) }}</span>
            </td>
            <td>{{ e.action }}</td>
            <td class="mono">{{ e.subject }}</td>
            <td>
              <span class="result" :class="`result-${e.result}`">{{ resultLabel(e.result) }}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<script lang="ts">
function formatDate(iso: string): string {
  return new Date(iso).toLocaleString('ru-RU', { dateStyle: 'short', timeStyle: 'short' })
}

function actorLabel(a: string): string {
  return ({ system: 'Система', agent: 'Цифровой модератор', human: 'Сотрудник' } as Record<string, string>)[a] ?? a
}

function resultLabel(r: string): string {
  return ({ pass: 'успех', fail: 'ошибка', pending: 'ожидание', dismissed: 'отклонено' } as Record<string, string>)[r] ?? r
}
</script>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;

.journal {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.table-wrap {
  background: $color-surface-overlay;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  overflow: hidden;
  overflow-x: auto;
}

.data-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.8125rem;
}

.data-table th {
  text-align: left;
  padding: $spacing-3 $spacing-4;
  background: $color-surface-inset;
  color: $color-text-muted;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  border-bottom: 1px solid $color-border;
  white-space: nowrap;
}

.data-table td {
  padding: $spacing-3 $spacing-4;
  border-bottom: 1px solid $color-border-subtle;
}

.data-table tbody tr:last-child td {
  border-bottom: none;
}

.data-table tbody tr:hover {
  background: $color-surface;
}

.mono {
  font-family: $font-family-mono;
  font-size: 11px;
}

.actor {
  display: inline-flex;
  align-items: center;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 500;
  background: $color-surface-raised;
  color: $color-text-muted;
}

.actor-system {
  background: rgba(96, 165, 250, 0.10);
  color: $color-info;
}

.actor-agent {
  background: rgba(45, 212, 191, 0.12);
  color: $color-primary;
}

.actor-human {
  background: rgba(154, 169, 184, 0.10);
  color: $color-text-muted;
}

.result {
  display: inline-flex;
  align-items: center;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 500;
}

.result-pass {
  background: rgba(74, 222, 128, 0.12);
  color: $color-success;
}

.result-fail {
  background: rgba(248, 113, 113, 0.12);
  color: $color-danger;
}

.result-pending {
  background: rgba(251, 191, 36, 0.12);
  color: $color-warning;
}

.result-dismissed {
  background: $color-surface-overlay;
  color: $color-text-muted;
}
</style>
