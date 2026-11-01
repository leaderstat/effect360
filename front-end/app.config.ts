// services/web-demo/app.config.ts
//
// Цветовая и визуальная конфигурация Nuxt UI.
//
// Маппинг идёт на те же токены, что определены в Lustre (см.
// services/frontend/styles/_tokens.sass):
//   * --color-primary        #2dd4bf (teal-400) — основной акцент
//   * --color-bg             #0b0f14 (тёмный фон)
//   * --color-surface        #141b23
//   * --color-text           #e6edf3
//
// Nuxt UI v3 принимает цвета в формате HSL-каналов для Tailwind-токенов,
// поэтому значения нужно перевести. Ниже использованы значения,
// согласованные с палитрой Lustre.

export default defineAppConfig({
  ui: {
    colors: {
      primary: 'teal',
      neutral: 'slate'
    },
    button: {
      defaultVariants: {
        size: 'md',
        color: 'primary'
      }
    },
    card: {
      defaultVariants: {
        variant: 'subtle'
      }
    },
    badge: {
      defaultVariants: {
        size: 'sm'
      }
    }
  }
})
