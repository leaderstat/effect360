// services/web-demo/nuxt.config.ts
//
// Конфигурация Nuxt 4 для демонстрационного контура «Эффективность 360».
//
// Цели:
//   * поднять Nuxt UI поверх дизайн-токенов Lustre;
//   * не зависеть от локального backend или БД;
//   * собирать production-build, годный к деплою на Vercel;
//   * показывать демо-режим явно: ни одна страница не делает реальных
//     сетевых вызовов, кроме моков в `composables/useMockData.ts`.
//
// Здесь не подключаются Nuxt Content, модули авторизации и БД.
// Это сознательное сужение scope: демо должно работать офлайн.

export default defineNuxtConfig({
  compatibilityDate: '2025-11-01',
  devtools: { enabled: true },
  modules: ['@nuxt/ui'],
  css: ['~/assets/scss/main.scss'],
  typescript: {
    strict: true,
    typeCheck: false
  },
  app: {
    head: {
      title: 'Эффективность 360 — демонстрационный контур',
      meta: [
        { name: 'viewport', content: 'width=device-width, initial-scale=1' },
        { name: 'description', content: 'Демонстрационный Nuxt UI контур продукта «Эффективность 360». Мок-данные, без подключения к реальному backend.' },
        { name: 'robots', content: 'noindex,nofollow' }
      ]
    }
  },
  ui: {
    fonts: false
  },
  nitro: {
    preset: process.env.NITRO_PRESET || undefined
  },
  runtimeConfig: {
    public: {
      demoMode: true,
      version: '0.1.0'
    }
  },
  vite: {
    css: {
      preprocessorOptions: {
        scss: {
          api: 'modern-compiler',
          silenceDeprecations: ['legacy-js-api', 'mixed-decls', 'global-builtin', 'import']
        }
      }
    }
  }
})
