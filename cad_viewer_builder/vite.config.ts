import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'
import { copyFileSync, mkdirSync } from 'fs'

// Plugin to copy pre-built worker files that Vite/Rolldown won't bundle automatically
function copyWorkerPlugin() {
  return {
    name: 'copy-libredwg-worker',
    closeBundle() {
      const src = resolve(
        __dirname,
        'node_modules/@mlightcad/libredwg-converter/dist/libredwg-parser-worker.js'
      )
      const destDir = resolve(__dirname, '../assets/viewer/assets')
      mkdirSync(destDir, { recursive: true })
      copyFileSync(src, resolve(destDir, 'libredwg-parser-worker.js'))
      console.log('✓ Copied libredwg-parser-worker.js')
    },
  }
}

export default defineConfig({
  plugins: [vue(), copyWorkerPlugin()],
  resolve: {
    alias: {
      // Bypass package exports restriction for CSS files
      'cad-viewer-styles': resolve(
        __dirname,
        'node_modules/@mlightcad/cad-viewer/dist/index.css'
      ),
    },
  },
  build: {
    outDir: resolve(__dirname, '../assets/viewer'),
    emptyOutDir: true,
    // Keep worker JS files as separate chunks (needed for Web Worker instantiation)
    // Don't try to inline large WASM / worker files
    assetsInlineLimit: 4096, // 4KB threshold, workers stay as files
    rollupOptions: {
      output: {
        // Stable filenames so Flutter asset declarations don't need to list hashes
        entryFileNames: 'assets/[name].js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name].[ext]',
      },
    },
  },
  // Use relative base so assets resolve correctly when served from any URL path
  base: './',
  optimizeDeps: {
    include: [
      'vue',
      'element-plus',
      '@element-plus/icons-vue',
      'vue-i18n',
    ],
  },
})
