<script setup lang="ts">
// services/web-demo/components/PageHeader.vue
//
// Единый заголовок страницы: хлебные крошки, заголовок, подзаголовок,
// слот для действий справа. Используется на всех страницах, чтобы
// визуальная логика была согласованной.

interface Crumb {
  label: string
  to?: string
}

defineProps<{
  title: string
  lead?: string
  crumbs?: Crumb[]
}>()
</script>

<template>
  <div class="page-header">
    <div class="page-title">
      <nav v-if="crumbs?.length" class="breadcrumb">
        <template v-for="(c, i) in crumbs" :key="c.label">
          <NuxtLink v-if="c.to" :to="c.to" class="breadcrumb-link">{{ c.label }}</NuxtLink>
          <span v-else class="current">{{ c.label }}</span>
          <span v-if="i < crumbs.length - 1" class="sep">/</span>
        </template>
      </nav>
      <h1>{{ title }}</h1>
      <p v-if="lead">{{ lead }}</p>
    </div>
    <div class="page-actions">
      <slot name="actions" />
    </div>
  </div>
</template>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;

.page-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: $spacing-4;
  flex-wrap: wrap;
  margin-bottom: $spacing-2;
}

.page-title {
  display: flex;
  flex-direction: column;
  gap: $spacing-1;
  min-width: 0;
}

.breadcrumb {
  display: flex;
  align-items: center;
  gap: $spacing-2;
  font-size: 0.75rem;
  color: $color-text-subtle;
  margin-bottom: $spacing-1;
}

.breadcrumb-link {
  color: $color-text-subtle;

  &:hover {
    color: $color-text;
  }
}

.current {
  color: $color-text-muted;
}

.sep {
  opacity: 0.5;
}

h1 {
  margin: 0;
  font-size: 1.75rem;
  font-weight: 700;
  line-height: 1.25;
  letter-spacing: -0.01em;
}

p {
  margin: 0;
  color: $color-text-muted;
  font-size: 0.8125rem;
  line-height: 1.55;
  max-width: 70ch;
}

.page-actions {
  display: flex;
  align-items: center;
  gap: $spacing-2;
  flex-wrap: wrap;
}
</style>
