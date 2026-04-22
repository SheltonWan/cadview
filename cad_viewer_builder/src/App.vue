<template>
  <div class="viewer-root">
    <MlCadViewer
      :url="fileUrl"
      :locale="'zh'"
      :theme="'dark'"
      style="width:100%;height:100%"
    />
    <div v-if="loadError" class="error-overlay">
      <p>{{ loadError }}</p>
      <button @click="loadError = ''">关闭</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { MlCadViewer } from '@mlightcad/cad-viewer'

const fileUrl = ref<string | undefined>(undefined)
const loadError = ref('')

onMounted(() => {
  // Expose API for Flutter to call via runJavaScript()
  ;(window as any).cadViewer = {
    /**
     * Load a CAD file from the given URL.
     * Flutter calls: window.cadViewer.loadFile('/dwg?path=...')
     */
    loadFile(url: string) {
      fileUrl.value = url
    },
    /**
     * Clear the current file.
     */
    closeFile() {
      fileUrl.value = undefined
    }
  }

  // Notify Flutter that the viewer is ready to receive commands
  notifyFlutter({ type: 'ready' })
})

function notifyFlutter(payload: object) {
  try {
    const msg = JSON.stringify(payload)
    // webview_flutter JavascriptChannel named 'FlutterBridge'
    if ((window as any).FlutterBridge) {
      ;(window as any).FlutterBridge.postMessage(msg)
    }
  } catch (_) {
    // Running outside Flutter (e.g., browser dev), ignore
  }
}
</script>

<style>
html, body {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100%;
  overflow: hidden;
  background: #1e1e1e;
}

.viewer-root {
  width: 100%;
  height: 100vh;
  position: relative;
}

.error-overlay {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  background: rgba(200, 50, 50, 0.9);
  color: white;
  padding: 20px 30px;
  border-radius: 8px;
  text-align: center;
  z-index: 9999;
}

.error-overlay button {
  margin-top: 12px;
  padding: 6px 20px;
  background: white;
  color: #c83232;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}
</style>
