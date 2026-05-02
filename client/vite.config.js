import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { readFileSync } from 'fs'
import { resolve } from 'path'

const { version } = JSON.parse(
  readFileSync(resolve(import.meta.dirname, 'package.json'), 'utf-8')
)

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  define: {
    __APP_VERSION__: JSON.stringify(version),
  },
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: true,
      }
    }
  }
})
