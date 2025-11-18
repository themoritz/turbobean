import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, 'src/d3-custom.js'),
      name: 'd3',
      fileName: 'd3-custom',
      formats: ['iife']
    },
    minify: 'terser',
    terserOptions: {
      compress: {
        drop_console: false,
        passes: 2
      },
      mangle: true,
      format: {
        comments: false
      }
    },
    outDir: 'dist',
    emptyOutDir: true
  }
});
