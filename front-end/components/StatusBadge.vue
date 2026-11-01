<script setup lang="ts">
// services/web-demo/components/StatusBadge.vue
//
// Бейдж статуса заявки. Цвет берётся из палитры Lustre и согласован
// с оригинальными .chip-* классами из _pages.sass.

import type { RequestStatus } from '~/types/domain'

const props = defineProps<{
  status: RequestStatus | string
}>()

const palette: Record<string, { bg: string, border: string, text: string }> = {
  draft:         { bg: 'rgba(154, 169, 184, 0.10)', border: 'rgba(154, 169, 184, 0.30)', text: '#9aa9b8' },
  clarification: { bg: 'rgba(45, 212, 191, 0.12)',   border: 'rgba(45, 212, 191, 0.35)',   text: '#2dd4bf' },
  submitted:     { bg: 'rgba(96, 165, 250, 0.12)',   border: 'rgba(96, 165, 250, 0.35)',   text: '#60a5fa' },
  in_review:     { bg: 'rgba(96, 165, 250, 0.12)',   border: 'rgba(96, 165, 250, 0.35)',   text: '#60a5fa' },
  returned:      { bg: 'rgba(251, 191, 36, 0.12)',   border: 'rgba(251, 191, 36, 0.35)',   text: '#fbbf24' },
  approved:      { bg: 'rgba(74, 222, 128, 0.12)',   border: 'rgba(74, 222, 128, 0.35)',   text: '#4ade80' },
  rejected:      { bg: 'rgba(248, 113, 113, 0.12)',  border: 'rgba(248, 113, 113, 0.35)',  text: '#f87171' },
  completed:     { bg: 'rgba(74, 222, 128, 0.12)',   border: 'rgba(74, 222, 128, 0.35)',   text: '#4ade80' },
  overdue:       { bg: 'rgba(248, 113, 113, 0.12)',  border: 'rgba(248, 113, 113, 0.35)',  text: '#f87171' }
}

const { statusLabel } = useMockData()
const colors = computed(() => palette[props.status] ?? palette.draft)
const label = computed(() => statusLabel(props.status))
</script>

<template>
  <span class="status-badge" :style="{
    backgroundColor: colors!.bg,
    borderColor: colors!.border,
    color: colors!.text
  }">
    <span class="dot" :style="{ backgroundColor: colors!.text }" />
    {{ label }}
  </span>
</template>

<style lang="scss" scoped>
.status-badge {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 2px 8px;
  border-radius: 999px;
  border: 1px solid;
  font-size: 11px;
  font-weight: 500;
  white-space: nowrap;
  line-height: 1.5;
}

.dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
}
</style>
