import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
// The shared front-end half of clappkit: plain .ts resolved by this alias, so nothing
// is added to package.json and `@tauri-apps/api` / `react` still come from OUR
// node_modules. `server.fs.allow` is what lets the dev server read it from outside root.
const clappkit = path.resolve(here, "clappkit/web");
// …and because that file sits OUTSIDE this project, Node's own resolution would look for
// `react` / `@tauri-apps/api` in `clapps/node_modules` and find nothing. Pin both to OUR
// copies, which is also what guarantees one React instance (two would break hooks).
const dep = (name: string) => path.resolve(here, "node_modules", name);

// Tauri v2: fixed dev port; target the WebView engine (Safari-class) like Clatch's GUI.
//
// `dist/` is Vite's, and ONLY Vite's. It used to be the assembled Clatch depot too —
// `scripts/package.sh` rm -rf'd the same path — so `npm run build` and `npm run package`
// deleted each other's output and `clatch validate dist` could not pass. The depot now
// lives in `pkg/`; nothing but Vite writes here.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  resolve: {
    alias: {
      "@clappkit": clappkit,
      react: dep("react"),
      "react-dom": dep("react-dom"),
      "@tauri-apps/api": dep("@tauri-apps/api"),
    },
  },
  server: { port: 1420, strictPort: true, fs: { allow: [".", clappkit] } },
  build: { target: "safari15" },
});
