import { createApp } from 'vue'
import ElementPlus from 'element-plus'
import 'element-plus/dist/index.css'
import 'cad-viewer-styles'
import * as ElementPlusIconsVue from '@element-plus/icons-vue'
import { i18n } from '@mlightcad/cad-viewer'
import App from './App.vue'

const app = createApp(App)

// Register Element Plus icons
for (const [key, component] of Object.entries(ElementPlusIconsVue)) {
  app.component(key, component as any)
}

app.use(ElementPlus)
app.use(i18n)
app.mount('#app')
