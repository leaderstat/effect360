<script setup lang="ts">
// services/web-demo/pages/requests/new.vue
//
// Экран создания новой заявки. Соответствует экрану S1 (Описание)
// и частично S2 (Уточнения) из Lustre.
//
// Демо: сервис «извлекает» поля по свободному тексту и подсвечивает
// недостающие, не подключаясь к LLM-провайдеру.

const { typeLabel } = useMockData()

const freeText = ref('Нужно оформить командировку в Казань на конференцию по финтеху с 12 по 14 ноября. Финансирование — грант РНФ.')
const detectedType = ref<'business_trip' | 'reference' | 'access' | 'equipment' | 'training' | null>(null)
const detectedFields = ref<Array<{ key: string, value: string }>>([])
const missingFields = ref<string[]>([])
const citations = ref<Array<{ label: string, snippet: string }>>([])

function analyze(): void {
  const text = freeText.value.toLowerCase()
  if (text.includes('командировк') || text.includes('конференц')) {
    detectedType.value = 'business_trip'
  } else if (text.includes('справк')) {
    detectedType.value = 'reference'
  } else if (text.includes('доступ') || text.includes('bi') || text.includes('crm')) {
    detectedType.value = 'access'
  } else if (text.includes('ноутбук') || text.includes('оборудован')) {
    detectedType.value = 'equipment'
  } else if (text.includes('обучен') || text.includes('курс')) {
    detectedType.value = 'training'
  } else {
    detectedType.value = null
  }

  // Извлечённые поля — синтетика, согласованная с Lustre-моками.
  detectedFields.value = []
  if (detectedType.value === 'business_trip') {
    detectedFields.value = [
      { key: 'Город', value: extract(text, ['казань', 'москва', 'самар', 'петерб']) || 'не определён' },
      { key: 'Цель', value: 'Конференция' },
      { key: 'Источник финансирования', value: text.includes('грант') ? 'Грант' : 'не указан' }
    ]
    missingFields.value = ['Номер гранта', 'Программа конференции', 'Приглашение']
    citations.value = [
      { label: 'п. 11 Положения о командировках', snippet: 'При грантовом финансировании указывается номер гранта.' },
      { label: 'п. 18 Положения о командировках', snippet: 'К заявке прикладывается программа мероприятия или приглашение.' }
    ]
  } else if (detectedType.value === 'access') {
    detectedFields.value = [
      { key: 'Система', value: text.includes('bi') ? 'BI' : 'CRM' },
      { key: 'Роль', value: 'viewer' }
    ]
    missingFields.value = ['Обоснование руководителя']
    citations.value = [
      { label: 'п. 5 Регламента доступа', snippet: 'Доступ к BI-отчётам предоставляется по согласованию с руководителем.' }
    ]
  } else {
    missingFields.value = []
    citations.value = []
  }
}

function extract(text: string, words: string[]): string | null {
  for (const w of words) if (text.includes(w)) return w
  return null
}

const canSubmit = computed(() => detectedType.value !== null && missingFields.value.length === 0)
</script>

<template>
  <div class="new-request">
    <PageHeader
      title="Новая заявка"
      lead="Опишите запрос свободным текстом. Сервис определит тип, извлечёт поля и подскажет, что нужно добавить."
      :crumbs="[{ label: 'Главная', to: '/' }, { label: 'Новая заявка' }]"
    >
      <template #actions>
        <UButton variant="ghost" icon="i-lucide-x" to="/">Отмена</UButton>
      </template>
    </PageHeader>

    <div class="layout">
      <div class="stepper">
        <span class="step done">1. Описание</span>
        <span class="step" :class="{ current: detectedType, done: detectedType && missingFields.length === 0 }">2. Уточнения</span>
        <span class="step" :class="{ done: false }">3. Отправка</span>
      </div>

      <div class="grid">
        <section class="form-panel">
          <h2>Описание</h2>
          <UTextarea
            v-model="freeText"
            placeholder="Например: «Прошу согласовать командировку в Казань 12–14 ноября на конференцию по финтеху, финансирование — грант РНФ №24-18-00345»."
            :rows="8"
            autoresize
          />
          <div class="form-actions">
            <UButton color="primary" icon="i-lucide-sparkles" @click="analyze">Извлечь поля</UButton>
            <UButton variant="ghost" icon="i-lucide-rotate-ccw" @click="freeText = ''">Очистить</UButton>
          </div>
        </section>

        <section class="preview-panel">
          <h2>Что увидел сервис</h2>
          <div v-if="!detectedType" class="empty">
            <UIcon name="i-lucide-info" class="size-5" />
            <p>Нажмите «Извлечь поля», чтобы сервис определил тип заявки и подсказал требования.</p>
          </div>
          <template v-else>
            <div class="kv">
              <span class="kv-key">Тип заявки</span>
              <span class="kv-value">{{ typeLabel(detectedType) }}</span>
            </div>
            <div class="fields">
              <p class="section-label">Извлечённые поля</p>
              <div v-for="f in detectedFields" :key="f.key" class="kv">
                <span class="kv-key">{{ f.key }}</span>
                <span class="kv-value">{{ f.value }}</span>
              </div>
            </div>
            <div v-if="missingFields.length" class="missing">
              <p class="section-label">Нужно добавить</p>
              <ul>
                <li v-for="m in missingFields" :key="m">
                  <UIcon name="i-lucide-alert-triangle" class="size-4" />
                  {{ m }}
                </li>
              </ul>
            </div>
            <div v-if="citations.length" class="citations">
              <p class="section-label">Основания требований</p>
              <div v-for="c in citations" :key="c.label" class="citation">
                <p class="citation-label">{{ c.label }}</p>
                <p class="citation-snippet">«{{ c.snippet }}»</p>
              </div>
            </div>
            <div class="submit">
              <UButton color="primary" icon="i-lucide-send" :disabled="!canSubmit">
                {{ canSubmit ? 'Отправить заявку' : 'Сначала заполните обязательные поля' }}
              </UButton>
            </div>
          </template>
        </section>
      </div>
    </div>
  </div>
</template>

<style lang="scss" scoped>
@use '~/assets/scss/tokens' as *;

.new-request {
  display: flex;
  flex-direction: column;
  gap: $spacing-5;
}

.layout {
  display: flex;
  flex-direction: column;
  gap: $spacing-4;
}

.stepper {
  display: flex;
  flex-wrap: wrap;
  gap: $spacing-2;
}

.step {
  display: inline-flex;
  align-items: center;
  gap: $spacing-2;
  padding: $spacing-2 $spacing-3;
  border-radius: 999px;
  border: 1px solid $color-border;
  background: $color-surface;
  color: $color-text-subtle;
  font-size: 0.75rem;
  font-weight: 500;

  &.current {
    border-color: rgba(45, 212, 191, 0.35);
    background: rgba(45, 212, 191, 0.12);
    color: $color-primary;
  }

  &.done {
    border-color: rgba(74, 222, 128, 0.35);
    background: rgba(74, 222, 128, 0.12);
    color: $color-success;
  }
}

.grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: $spacing-4;

  @media (max-width: #{$breakpoint-lg - 1px}) {
    grid-template-columns: 1fr;
  }
}

.form-panel,
.preview-panel {
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

.form-actions {
  display: flex;
  gap: $spacing-2;
  flex-wrap: wrap;
}

.empty {
  padding: $spacing-6;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: $spacing-2;
  color: $color-text-muted;
  font-size: 0.8125rem;
  text-align: center;

  p {
    margin: 0;
    max-width: 36ch;
  }
}

.section-label {
  margin: $spacing-2 0;
  color: $color-text-subtle;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.kv {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: $spacing-3;
  padding: $spacing-2 0;
  border-bottom: 1px solid $color-border-subtle;

  &:last-child {
    border-bottom: none;
  }
}

.kv-key {
  color: $color-text-muted;
  font-size: 0.8125rem;
}

.kv-value {
  font-weight: 500;
  text-align: right;
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

.citations {
  display: flex;
  flex-direction: column;
  gap: $spacing-2;
}

.citation {
  background: $color-bg-subtle;
  border: 1px solid $color-border-subtle;
  border-radius: $radius-sm;
  padding: $spacing-3;
}

.citation-label {
  margin: 0 0 $spacing-1;
  color: $color-primary;
  font-size: 0.75rem;
  font-weight: 600;
}

.citation-snippet {
  margin: 0;
  color: $color-text-muted;
  font-size: 0.8125rem;
  font-style: italic;
  line-height: 1.55;
}

.submit {
  padding-top: $spacing-3;
  border-top: 1px solid $color-border-subtle;
}
</style>
