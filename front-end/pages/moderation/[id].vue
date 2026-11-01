<script setup lang="ts">
// services/web-demo/pages/moderation/[id].vue
//
// Карточка обработки заявки исполнителем. Соответствует P7.6 (Подготовка
// официального ответа) и части P7.3 (Карточка заявки) из Lustre.

const route = useRoute()
const { findRequest, typeLabel } = useMockData()

const id = computed(() => String(route.params.id))
const request = computed(() => findRequest(id.value))

const decision = ref<'approve' | 'return' | null>(null)
const reason = ref('')
const responseText = ref(
  'Уважаемый(ая) {заявитель},\n\nВаша заявка «{title}» рассмотрена.\n\n{result}\n\nС уважением,\n{роль}'
)
</script>

<template>
  <div v-if="!request" class="empty">Заявка «{{ id }}» не найдена в демо-наборе.</div>
  <div v-else class="request-card">
    <PageHeader
      :title="request.title"
      :lead="`${typeLabel(request.type)} · ${request.applicant} · обновлено ${formatRelative(request.updatedAt)}`"
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Очередь модерации', to: '/moderation' }, { label: request.id }]"
    >
      <template #actions>
        <StatusBadge :status="request.status" />
      </template>
    </PageHeader>

    <div class="grid">
      <section class="panel">
        <h2>Параметры заявки</h2>
        <dl class="kv-list">
          <div v-for="(value, key) in request.fields" :key="key" class="kv-row">
            <dt>{{ key }}</dt>
            <dd>{{ value }}</dd>
          </div>
        </dl>
        <div v-if="request.missingFields.length" class="missing">
          <p class="section-label">Не заполнено</p>
          <ul>
            <li v-for="m in request.missingFields" :key="m">
              <UIcon name="i-lucide-alert-triangle" class="size-4" />
              {{ m }}
            </li>
          </ul>
        </div>
      </section>

      <section class="panel">
        <h2>Решение</h2>
        <div class="actions">
          <UButton :color="decision === 'approve' ? 'success' : 'neutral'" icon="i-lucide-check" @click="decision = 'approve'">Согласовать</UButton>
          <UButton :color="decision === 'return' ? 'error' : 'neutral'" icon="i-lucide-corner-up-left" @click="decision = 'return'">Вернуть на доработку</UButton>
        </div>
        <div v-if="decision === 'return'" class="reason">
          <label class="reason-label">Причина возврата <span class="required">*</span></label>
          <UTextarea v-model="reason" :rows="3" placeholder="Например: не указан номер гранта (п. 11 Положения)." />
        </div>
        <h2>Официальный ответ</h2>
        <UTextarea v-model="responseText" :rows="8" />
        <div class="footer">
          <UButton variant="ghost" to="/moderation">Отмена</UButton>
          <UButton color="primary" :disabled="decision === 'return' && !reason">Отправить ответ</UButton>
        </div>
      </section>
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

.request-card {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.empty {
  padding: $spacing-6;
  text-align: center;
  color: $color-text-muted;
  background: $color-surface-overlay;
  border: 1px dashed $color-border-strong;
  border-radius: $radius-md;
}

.grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: $spacing-4;

  @media (max-width: #{$breakpoint-lg - 1px}) {
    grid-template-columns: 1fr;
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

.actions {
  display: flex;
  gap: $spacing-2;
  flex-wrap: wrap;
}

.reason {
  display: flex;
  flex-direction: column;
  gap: $spacing-2;
}

.reason-label {
  font-size: 0.8125rem;
  color: $color-text-muted;
  font-weight: 500;
}

.required {
  color: $color-danger;
}

.section-label {
  margin: $spacing-3 0 $spacing-2;
  color: $color-text-subtle;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.kv-list {
  margin: 0;
  display: grid;
  gap: $spacing-2;
}

.kv-row {
  display: grid;
  grid-template-columns: minmax(160px, auto) minmax(0, 1fr);
  gap: $spacing-3;
  padding: $spacing-2 0;
  border-bottom: 1px solid $color-border-subtle;

  &:last-child {
    border-bottom: none;
  }

  dt {
    color: $color-text-muted;
    font-size: 0.8125rem;
  }

  dd {
    margin: 0;
    color: $color-text;
    word-break: break-word;
  }
}

.missing ul {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: $spacing-2;
}

.missing li {
  display: flex;
  align-items: center;
  gap: $spacing-2;
  color: $color-warning;
  font-size: 0.8125rem;
}

.footer {
  display: flex;
  justify-content: flex-end;
  gap: $spacing-2;
  padding-top: $spacing-3;
  border-top: 1px solid $color-border-subtle;
}
</style>
