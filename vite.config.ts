import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri v2: fixed dev port; target the WebView engine (Safari-class) like Clatch's GUI.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { target: "safari15" },
});
