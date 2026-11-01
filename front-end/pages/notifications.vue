<script setup lang="ts">
// services/web-demo/pages/notifications.vue
//
// Лента уведомлений заявителя. Соответствует P7.2 (Лента уведомлений)
// и P8.6 (Уведомления колокольчика) из Lustre.

const { notifications } = useMockData()
</script>

<template>
  <div class="notifications">
    <PageHeader
      title="Уведомления"
      lead="Здесь все события по вашим заявкам: возвраты, уточнения, согласования."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Уведомления' }]"
    >
      <template #actions>
        <UButton variant="ghost" icon="i-lucide-check-check">Прочитать все</UButton>
      </template>
    </PageHeader>

    <div class="feed">
      <div
        v-for="n in notifications"
        :key="n.id"
        class="item"
        :class="[`level-${n.level}`, { unread: n.unread }]"
      >
        <div class="icon">
          <UIcon
            :name="n.level === 'warning' ? 'i-lucide-alert-triangle' : n.level === 'success' ? 'i-lucide-check-circle-2' : 'i-lucide-info'"
            class="size-4"
          />
        </div>
        <div class="body">
          <p class="title">{{ n.title }}</p>
          <p class="message">{{ n.message }}</p>
          <p class="time">{{ formatRelative(n.at) }}</p>
        </div>
        <span v-if="n.unread" class="dot" />
      </div>
    </div>
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

.notifications {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.feed {
  background: $color-surface-overlay;
  border: 1px solid $color-border;
  border-radius: $radius-md;
  padding: $spacing-2;
  display: flex;
  flex-direction: column;
  gap: $spacing-1;
}

.item {
  display: flex;
  align-items: flex-start;
  gap: $spacing-3;
  padding: $spacing-3;
  border-radius: $radius-md;
  cursor: pointer;

  &:hover {
    background: $color-surface-raised;
  }

  &.unread {
    background: rgba(45, 212, 191, 0.08);
  }
}

.icon {
  flex-shrink: 0;
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  border-radius: $radius-sm;
  background: $color-surface-raised;
  color: $color-text-muted;
}

.item.level-warning .icon {
  color: $color-warning;
  background: rgba(251, 191, 36, 0.10);
}

.item.level-success .icon {
  color: $color-success;
  background: rgba(74, 222, 128, 0.10);
}

.item.level-danger .icon {
  color: $color-danger;
  background: rgba(248, 113, 113, 0.10);
}

.body {
  flex: 1;
  min-width: 0;
}

.title {
  margin: 0;
  font-size: 0.875rem;
  font-weight: 600;
}

.message {
  margin: 2px 0 0;
  color: $color-text-muted;
  font-size: 0.8125rem;
  line-height: 1.5;
}

.time {
  margin: $spacing-1 0 0;
  color: $color-text-subtle;
  font-size: 0.75rem;
}

.dot {
  flex-shrink: 0;
  align-self: center;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: $color-primary;
}
</style>
