import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import { statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = dirname(fileURLToPath(import.meta.url));

const pageSourcePath = (pathname) => {
  const slug = pathname.replace(/^\/|\/$/g, "");
  return join(siteDir, "src/pages", slug ? `${slug}.astro` : "index.astro");
};

const lastModifiedForPage = (url) => {
  try {
    return statSync(pageSourcePath(new URL(url).pathname)).mtime.toISOString();
  } catch {
    return new Date().toISOString();
  }
};

export default defineConfig({
  site: "https://useblink.dev",
  integrations: [
    sitemap({
      serialize(item) {
        item.lastmod = lastModifiedForPage(item.url);
        return item;
      },
    }),
  ],
  vite: {
    envDir: "..",
  },
});
