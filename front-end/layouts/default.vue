<script setup lang="ts">
// services/web-demo/layouts/default.vue
//
// Слой приложения: боковая навигация + верхний header + основная зона.
// Дизайн перенесён из Lustre (services/frontend/styles/_layout.sass):
//   * сайдбар 240px с группами и активным состоянием,
//   * sticky-header 60px с заголовком и уведомлениями,
//   * основная зона с заголовком страницы и demo-баннером.

const route = useRoute()
const config = useRuntimeConfig()

const groups = [
  {
    label: 'Заявитель',
    items: [
      { label: 'Главная', to: '/', icon: 'i-lucide-home' },
      { label: 'Новая заявка', to: '/requests/new', icon: 'i-lucide-plus-circle' },
      { label: 'Мои заявки', to: '/requests', icon: 'i-lucide-inbox' },
      { label: 'Уведомления', to: '/notifications', icon: 'i-lucide-bell' }
    ]
  },
  {
    label: 'Исполнитель',
    items: [
      { label: 'Очередь модерации', to: '/moderation', icon: 'i-lucide-list-checks' },
      { label: 'Карточка обработки', to: '/moderation/demo-9d44', icon: 'i-lucide-file-text' }
    ]
  },
  {
    label: 'Руководитель',
    items: [
      { label: 'Метрики', to: '/metrics', icon: 'i-lucide-bar-chart-3' },
      { label: 'Журнал событий', to: '/journal', icon: 'i-lucide-scroll' },
      { label: 'Автоматизация', to: '/automation', icon: 'i-lucide-cog' },
      { label: 'Настройки', to: '/settings', icon: 'i-lucide-sliders-horizontal' }
    ]
  }
]

function isActive(to: string): boolean {
  if (to === '/') return route.path === '/'
  return route.path === to || route.path.startsWith(to + '/')
}

const pageTitle = computed(() => {
  const all = groups.flatMap((g) => g.items)
  const match = all.find((i) => isActive(i.to))
  return match?.label ?? 'Демонстрационный контур'
})
</script>

<template>
  <div class="app-banner demo-banner">
    <span class="demo-banner__dot" />
    <span>Демо-режим · v{{ config.public.version }} · данные синтетические, backend не подключён</span>
  </div>
  <div class="app-layout">
    <aside class="app-sidebar">
      <NuxtLink to="/" class="app-sidebar__brand">
        <div class="app-sidebar__logo">Э360</div>
        <div>
          <p class="app-sidebar__brand-title">Эффективность 360</p>
          <p class="app-sidebar__brand-subtitle">Сервис внутренних заявок</p>
        </div>
      </NuxtLink>
      <div v-for="group in groups" :key="group.label" class="app-sidebar__group">
        <p class="app-sidebar__group-label">{{ group.label }}</p>
        <nav class="app-sidebar__nav">
          <NuxtLink
            v-for="item in group.items"
            :key="item.to"
            :to="item.to"
            class="app-sidebar__link"
            :class="{ 'app-sidebar__link--active': isActive(item.to) }"
          >
            <UIcon :name="item.icon" class="size-4" />
            <span>{{ item.label }}</span>
          </NuxtLink>
        </nav>
      </div>
      <div class="app-sidebar__session">
        <div class="app-sidebar__session-card">
          <div class="app-sidebar__session-avatar">ИИ</div>
          <div class="app-sidebar__session-meta">
            <p class="app-sidebar__session-name">Иванов И.</p>
            <p class="app-sidebar__session-role">Заявитель · Демо</p>
          </div>
        </div>
      </div>
    </aside>
    <div class="app">
      <header class="app-header">
        <div class="app-header__row">
          <p class="app-header__title">{{ pageTitle }}</p>
        </div>
        <div class="app-header__center">
          <span class="app-header__pill">
            <span class="app-header__pill-dot" />
            demo · mok
          </span>
        </div>
        <div class="app-header__actions">
          <NuxtLink to="/notifications" class="app-header__pill">
            <UIcon name="i-lucide-bell" class="size-4" />
            2 новых
          </NuxtLink>
        </div>
      </header>
      <main class="app-main">
        <slot />
      </main>
    </div>
  </div>
</template>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;
@use '~/assets/scss/mixins' as *;

.app-layout {
  display: grid;
  grid-template-columns: 240px minmax(0, 1fr);
  min-height: 100vh;
  background: $color-bg;
  color: $color-text;

  @media (max-width: #{$breakpoint-lg - 1px}) {
    grid-template-columns: 200px minmax(0, 1fr);
  }
  @media (max-width: #{$breakpoint-md - 1px}) {
    grid-template-columns: 1fr;
  }
}

.app {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}

.app-sidebar {
  background: $color-surface;
  border-right: 1px solid $color-border;
  padding: $spacing-5 $spacing-3;
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
  position: sticky;
  top: 0;
  height: 100vh;
  overflow-y: auto;
  @include scrollbar-thin;

  @media (max-width: #{$breakpoint-md - 1px}) {
    position: static;
    height: auto;
    border-right: 0;
    border-bottom: 1px solid $color-border;
    padding: $spacing-3 $spacing-4;
  }

  &__brand {
    display: flex;
    align-items: center;
    gap: $spacing-3;
    padding: 0 $spacing-2;
    color: inherit;
    text-decoration: none;
  }

  &__logo {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border-radius: $radius-md;
    background: rgba(45, 212, 191, 0.12);
    border: 1px solid rgba(45, 212, 191, 0.35);
    color: $color-primary;
    font-weight: 700;
    font-size: 0.8125rem;
  }

  &__brand-title {
    margin: 0;
    font-size: 0.8125rem;
    font-weight: 600;
    line-height: 1.25;
    @include truncate;
  }

  &__brand-subtitle {
    margin: 0;
    font-size: 11px;
    color: $color-text-subtle;
    line-height: 1.25;
  }

  &__group {
    display: flex;
    flex-direction: column;
    gap: $spacing-1;
  }

  &__group-label {
    margin: 0 $spacing-2 $spacing-1;
    padding: 0 0 $spacing-1;
    border-bottom: 1px solid $color-border-subtle;
    color: $color-text-subtle;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }

  &__nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
    list-style: none;
    margin: 0;
    padding: 0;
  }

  &__link {
    display: flex;
    align-items: center;
    gap: $spacing-2;
    padding: $spacing-2 $spacing-3;
    border-radius: $radius-sm;
    color: $color-text-muted;
    font-size: 0.8125rem;
    text-decoration: none;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  &__link:hover {
    background: $color-surface-raised;
    color: $color-text;
  }

  &__link--active {
    background: rgba(45, 212, 191, 0.12);
    color: $color-primary;
    font-weight: 500;
  }

  &__session {
    margin-top: auto;
    padding-top: $spacing-3;
    padding-inline: $spacing-2;
    border-top: 1px solid $color-border;
    font-size: 0.8125rem;
  }

  &__session-card {
    display: flex;
    align-items: center;
    gap: $spacing-3;
    padding: $spacing-2;
    border-radius: $radius-sm;
    background: $color-surface-raised;
    border: 1px solid $color-border-subtle;
  }

  &__session-avatar {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: rgba(45, 212, 191, 0.12);
    color: $color-primary;
    font-size: 0.75rem;
    font-weight: 700;
  }

  &__session-name {
    margin: 0;
    font-size: 0.8125rem;
    font-weight: 500;
    color: $color-text;
  }

  &__session-role {
    margin: 0;
    font-size: 11px;
    color: $color-text-subtle;
  }
}

.app-header {
  display: flex;
  align-items: center;
  gap: $spacing-4;
  min-height: $layout-header-height;
  padding: $spacing-3 $spacing-5;
  background: $color-bg-subtle;
  border-bottom: 1px solid $color-border;
  position: sticky;
  top: 30px;
  z-index: $z-sticky;
  backdrop-filter: blur(8px);

  @media (max-width: #{$breakpoint-md - 1px}) {
    padding: $spacing-3 $spacing-4;
    gap: $spacing-2;
  }

  &__row {
    flex: 1;
    min-width: 0;
  }

  &__title {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    line-height: 1.25;
  }

  &__center {
    flex: 1;
    display: flex;
    justify-content: center;
    min-width: 0;
  }

  &__pill {
    display: inline-flex;
    align-items: center;
    gap: $spacing-2;
    padding: 4px $spacing-3;
    border-radius: $radius-full;
    border: 1px solid $color-border;
    background: $color-surface-raised;
    color: $color-text-muted;
    font-size: 0.75rem;
    font-weight: 500;
    text-decoration: none;

    &:hover {
      color: $color-text;
    }
  }

  &__pill-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: $color-primary;
  }

  &__actions {
    display: flex;
    align-items: center;
    gap: $spacing-3;
    margin-left: auto;
  }
}

.app-main {
  display: flex;
  flex-direction: column;
  gap: $spacing-4;
  padding: $spacing-5;
  min-width: 0;
  max-width: 100%;
  overflow-x: hidden;
}
</style>
