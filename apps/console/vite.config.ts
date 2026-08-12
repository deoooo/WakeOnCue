import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  root: new URL(".", import.meta.url).pathname,
  build: {
    outDir: "../../dist/console",
    emptyOutDir: true,
  },
  server: { host: "127.0.0.1", port: 4173 },
});
