import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  resolve: {
    // The plugin is linked from '../..', which has its own node_modules: keep one copy of Capacitor's core, this app's.
    dedupe: ['@capacitor/core'],
  },
});
