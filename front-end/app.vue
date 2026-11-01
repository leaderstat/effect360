<script setup lang="ts">
// services/web-demo/app.vue
//
// Корневой компонент Nuxt. Здесь подключается только UApp — обёртка
// Nuxt UI, которая активирует портал для tooltip'ов и модалок.
</script>

<template>
  <UApp>
    <NuxtLayout>
      <NuxtPage />
    </NuxtLayout>
  </UApp>
</template>
